package io.github.wleeaf.dpi;

import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketException;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Collections;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/** Loopback SOCKS5 relay used by the app's TUN adapter. No remote proxy server. */
public final class LocalProxy implements Closeable {
    public interface Protector {
        boolean protect(Socket socket);
        boolean protect(DatagramSocket socket);
    }
    public interface DnsResolver { byte[] resolve(byte[] query) throws IOException; }

    private final Protector protector;
    private final DnsResolver dns;
    private final boolean allDomains;
    private final boolean records;
    private final Set<String> domains;
    private final byte[] token;
    private final Set<Closeable> resources = ConcurrentHashMap.newKeySet();
    private final ThreadPoolExecutor workers;
    private final ServerSocket listener;
    private volatile boolean running = true;

    public LocalProxy(Protector protector, DnsResolver dns, boolean allDomains, boolean records,
                      Set<String> domains) throws IOException {
        this(protector, dns, allDomains, records, domains, null);
    }

    public LocalProxy(Protector protector, DnsResolver dns, boolean allDomains, boolean records,
                      Set<String> domains, String token) throws IOException {
        this.protector = protector; this.dns = dns; this.allDomains = allDomains;
        this.records = records; this.domains = Collections.unmodifiableSet(domains);
        this.token = token == null ? null : token.getBytes(StandardCharsets.US_ASCII);
        workers = new ThreadPoolExecutor(0, 128, 30, TimeUnit.SECONDS, new SynchronousQueue<>(), task -> {
            Thread thread = new Thread(task, "dpi-relay"); thread.setDaemon(true); return thread;
        });
        listener = new ServerSocket();
        listener.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 64);
        own(listener);
        Thread acceptor = new Thread(this::accept, "dpi-accept");
        acceptor.setDaemon(true); acceptor.start();
    }

    public int port() { return listener.getLocalPort(); }

    private void accept() {
        while (running) {
            Socket client = null;
            try {
                client = own(listener.accept());
                final Socket accepted = client;
                workers.execute(() -> handle(accepted));
            } catch (IOException | RejectedExecutionException exception) {
                release(client);
                if (!running) return;
            }
        }
    }

    private void handle(Socket client) {
        try {
            client.setSoTimeout(10000);
            client.setTcpNoDelay(true);
            InputStream input = client.getInputStream();
            OutputStream output = client.getOutputStream();
            if (readByte(input) != 5) throw new IOException("Unsupported SOCKS version");
            int count = readByte(input);
            if (count == 0) throw new IOException("Missing authentication methods");
            int method = token == null ? 0 : 2;
            boolean supported = false;
            for (int i = 0; i < count; i++) if (readByte(input) == method) supported = true;
            output.write(new byte[] {5, (byte) (supported ? method : 255)}); output.flush();
            if (!supported) return;
            if (token != null) {
                if (readByte(input) != 1) throw new IOException("Unsupported authentication version");
                byte[] username = new byte[readByte(input)]; readFully(input, username);
                byte[] password = new byte[readByte(input)]; readFully(input, password);
                boolean valid = Arrays.equals(username, new byte[] {'d', 'p', 'i'}) && MessageDigest.isEqual(password, token);
                output.write(new byte[] {1, (byte) (valid ? 0 : 1)}); output.flush();
                if (!valid) return;
            }
            if (readByte(input) != 5) throw new IOException("Unsupported request version");
            int command = readByte(input);
            if (readByte(input) != 0) throw new IOException("Invalid reserved byte");
            Address destination = readAddress(input);
            if (command == 1) {
                if (destination.port == 53 && dns != null) connectDns(client);
                else connect(client, destination);
            } else if (command == 3) {
                associate(client);
            } else {
                reply(output, 7, InetAddress.getByName("127.0.0.1"), 0);
            }
        } catch (IOException | RejectedExecutionException ignored) {
            // Network failures end only this connection. Never log user traffic.
        } finally {
            release(client);
        }
    }

    private void connectDns(Socket client) throws IOException {
        reply(client.getOutputStream(), 0, InetAddress.getByName("127.0.0.1"), 0);
        InputStream input = client.getInputStream();
        OutputStream output = client.getOutputStream();
        while (running) {
            int high = input.read();
            if (high < 0) break;
            int length = (high << 8) | readByte(input);
            if (length < 12 || length > 4096) throw new IOException("Invalid DNS query length");
            byte[] query = new byte[length]; readFully(input, query);
            byte[] response = dns.resolve(query);
            output.write(response.length >> 8); output.write(response.length & 255);
            output.write(response); output.flush();
        }
    }

    private void connect(Socket client, Address destination) throws IOException {
        Socket remote = own(new Socket());
        boolean replied = false;
        try {
            // Binding creates Android's underlying file descriptor. protect()
            // must run after this and before connecting into the VPN route.
            remote.bind(new InetSocketAddress(0));
            if (!protector.protect(remote)) throw new IOException("Could not exclude upstream socket from VPN");
            remote.setTcpNoDelay(true);
            remote.connect(new InetSocketAddress(destination.host, destination.port), 10000);
            remote.setSoTimeout(300000); client.setSoTimeout(300000);
            reply(client.getOutputStream(), 0, remote.getLocalAddress(), remote.getLocalPort());
            replied = true;
            CountDownLatch responseDone = new CountDownLatch(1);
            workers.execute(() -> {
                try { copy(remote.getInputStream(), client.getOutputStream()); client.shutdownOutput(); }
                catch (IOException ignored) { release(client); release(remote); }
                finally { responseDone.countDown(); }
            });
            byte[] first = FirstFlight.read(client.getInputStream());
            String hostname = FirstFlight.hostname(first);
            boolean target = allDomains || FirstFlight.matches(hostname, domains) || FirstFlight.matches(destination.host, domains);
            if (target && (first.length > 0 && first[0] == 22 || destination.port == 80)) {
                FirstFlight.write(remote.getOutputStream(), first, records);
            } else {
                remote.getOutputStream().write(first);
            }
            copy(client.getInputStream(), remote.getOutputStream());
            remote.shutdownOutput();
            // Preserve the server's final response after the client half-closes.
            // The response worker owns closing the pair after its EOF.
            try { responseDone.await(30, TimeUnit.SECONDS); }
            catch (InterruptedException exception) { Thread.currentThread().interrupt(); }
        } catch (IOException exception) {
            if (!replied) reply(client.getOutputStream(), 5, InetAddress.getByName("127.0.0.1"), 0);
            throw exception;
        } finally {
            release(remote);
        }
    }

    private void associate(Socket control) throws IOException {
        DatagramSocket relay = own(new DatagramSocket(new InetSocketAddress("127.0.0.1", 0)));
        Map<InetSocketAddress, DatagramSocket> flows = new ConcurrentHashMap<>();
        reply(control.getOutputStream(), 0, relay.getLocalAddress(), relay.getLocalPort());
        control.setSoTimeout(0);
        try {
        workers.execute(() -> {
            InetSocketAddress clientAddress = null;
            byte[] buffer = new byte[65535];
            while (running && !relay.isClosed()) {
                try {
                    DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
                    relay.receive(packet);
                    if (!packet.getAddress().isLoopbackAddress()) continue;
                    InetSocketAddress sender = (InetSocketAddress) packet.getSocketAddress();
                    if (clientAddress == null) clientAddress = sender;
                    if (!clientAddress.equals(sender)) continue;
                    byte[] bytes = Arrays.copyOf(packet.getData(), packet.getLength());
                    if (bytes.length < 7 || bytes[0] != 0 || bytes[1] != 0 || bytes[2] != 0) continue;
                    PacketReader reader = new PacketReader(bytes, 3);
                    Address address = readAddress(reader);
                    InetSocketAddress target = new InetSocketAddress(address.host, address.port);
                    byte[] payload = Arrays.copyOfRange(bytes, reader.position, bytes.length);
                    final InetSocketAddress peer = clientAddress;
                    if (target.getPort() == 53 && dns != null) {
                        workers.execute(() -> {
                            try { sendReply(relay, peer, target, dns.resolve(payload)); }
                            catch (IOException ignored) { }
                        });
                    } else {
                        DatagramSocket upstream = flows.get(target);
                        if (upstream == null) {
                            if (flows.size() >= 32) continue;
                            upstream = own(new DatagramSocket(null));
                            try {
                                upstream.bind(new InetSocketAddress(0));
                                if (!protector.protect(upstream)) { release(upstream); continue; }
                                upstream.connect(target); upstream.setSoTimeout(60000);
                            } catch (IOException | IllegalArgumentException exception) {
                                release(upstream); continue;
                            }
                            flows.put(target, upstream);
                            final DatagramSocket receiver = upstream;
                            try {
                                workers.execute(() -> {
                                    try {
                                        byte[] response = new byte[65535];
                                        while (running && !receiver.isClosed()) {
                                            DatagramPacket incoming = new DatagramPacket(response, response.length);
                                            receiver.receive(incoming);
                                            sendReply(relay, peer, target, Arrays.copyOf(incoming.getData(), incoming.getLength()));
                                        }
                                    } catch (IOException ignored) { }
                                    finally { flows.remove(target, receiver); release(receiver); }
                                });
                            } catch (RejectedExecutionException exception) {
                                flows.remove(target, receiver); release(receiver); continue;
                            }
                        }
                        upstream.send(new DatagramPacket(payload, payload.length));
                    }
                } catch (SocketException exception) {
                    if (relay.isClosed()) break;
                } catch (IOException | RejectedExecutionException ignored) { /* malformed datagram or transient upstream failure */ }
            }
        });
        while (control.getInputStream().read() != -1) { /* lifetime follows SOCKS control connection */ }
        }
        finally { release(relay); for (DatagramSocket flow : flows.values()) release(flow); }
    }

    private static void sendReply(DatagramSocket relay, InetSocketAddress peer, InetSocketAddress source, byte[] payload) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream(payload.length + 22);
        bytes.write(new byte[] {0, 0, 0});
        writeAddress(bytes, source.getAddress(), source.getPort()); bytes.write(payload);
        byte[] message = bytes.toByteArray();
        relay.send(new DatagramPacket(message, message.length, peer));
    }

    private static void reply(OutputStream output, int code, InetAddress address, int port) throws IOException {
        output.write(new byte[] {5, (byte) code, 0}); writeAddress(output, address, port); output.flush();
    }

    private static void writeAddress(OutputStream output, InetAddress address, int port) throws IOException {
        byte[] bytes = address.getAddress(); output.write(bytes.length == 4 ? 1 : 4);
        output.write(bytes); output.write(port >> 8); output.write(port & 255);
    }

    private static Address readAddress(InputStream input) throws IOException {
        int type = readByte(input);
        String host;
        if (type == 1 || type == 4) {
            byte[] bytes = new byte[type == 1 ? 4 : 16]; readFully(input, bytes);
            host = InetAddress.getByAddress(bytes).getHostAddress();
        } else if (type == 3) {
            int length = readByte(input);
            if (length == 0) throw new IOException("Empty host");
            byte[] bytes = new byte[length]; readFully(input, bytes);
            host = new String(bytes, StandardCharsets.US_ASCII);
        } else { throw new IOException("Unsupported address type"); }
        int port = (readByte(input) << 8) | readByte(input);
        return new Address(host, port);
    }

    private static void readFully(InputStream input, byte[] bytes) throws IOException {
        int position = 0;
        while (position < bytes.length) {
            int count = input.read(bytes, position, bytes.length - position);
            if (count < 0) throw new EOFException();
            position += count;
        }
    }
    private static int readByte(InputStream input) throws IOException {
        int value = input.read(); if (value < 0) throw new EOFException(); return value;
    }
    private static void copy(InputStream input, OutputStream output) throws IOException {
        byte[] buffer = new byte[16384]; int count;
        while ((count = input.read(buffer)) != -1) { output.write(buffer, 0, count); }
        output.flush();
    }
    private synchronized <T extends Closeable> T own(T resource) throws IOException {
        if (!running) { resource.close(); throw new IOException("Proxy stopped"); }
        resources.add(resource); return resource;
    }
    private void release(Closeable resource) {
        if (resource == null) return;
        resources.remove(resource);
        try { resource.close(); } catch (IOException ignored) { }
    }
    @Override public synchronized void close() {
        running = false;
        for (Closeable resource : resources) release(resource);
        workers.shutdownNow();
    }
    private static final class Address {
        final String host; final int port;
        Address(String host, int port) { this.host = host; this.port = port; }
    }
    private static final class PacketReader extends InputStream {
        final byte[] bytes; int position;
        PacketReader(byte[] bytes, int position) { this.bytes = bytes; this.position = position; }
        @Override public int read() { return position < bytes.length ? bytes[position++] & 255 : -1; }
    }
}
