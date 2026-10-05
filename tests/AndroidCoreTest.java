package io.github.wleeaf.dpi;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import javax.net.ssl.*;

public final class AndroidCoreTest {
    private static final LocalProxy.Protector PROTECT = new LocalProxy.Protector() {
        public boolean protect(Socket socket) {
            check(socket.isBound() && !socket.isConnected(), "TCP protection must follow binding and precede connecting");
            return true;
        }
        public boolean protect(DatagramSocket socket) {
            check(socket.isBound() && !socket.isConnected(), "UDP protection must follow binding and precede connecting");
            return true;
        }
    };
    private static final AtomicInteger checks = new AtomicInteger();
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message); checks.incrementAndGet();
    }
    public static void main(String[] args) throws Exception {
        flightTests();
        tcpTest();
        udpAndDnsTest();
        ipv6Test();
        authenticationTest();
        tlsTest(args[0], true);
        tlsTest(args[0], false);
        System.out.println("Android relay checks passed: " + checks.get() + " assertions, including real TCP/TLS/UDP/DNS connections.");
    }
    private static void flightTests() throws Exception {
        byte[] hello = clientHello("gateway.discord.gg");
        check("gateway.discord.gg".equals(FirstFlight.hostname(hello)), "SNI parsing failed");
        Set<String> domains = new HashSet<>(Arrays.asList("discord.gg", "discord.com"));
        check(FirstFlight.matches("Gateway.Discord.GG.", domains), "Subdomain matching failed");
        check(!FirstFlight.matches("notdiscord.gg", domains), "Missing domain boundary");
        check(!FirstFlight.matches("discord.gg.evil.test", domains), "Domain suffix spoof matched");
        for (int count = 0; count < hello.length; count++) {
            String host = FirstFlight.hostname(Arrays.copyOf(hello, count));
            check(host == null, "Truncated ClientHello parsed as complete");
        }
        byte[] fragmented = FirstFlight.splitTlsRecord(hello);
        int firstLength = FirstFlight.u16(fragmented, 3);
        int secondStart = firstLength + 5;
        ByteArrayOutputStream payload = new ByteArrayOutputStream();
        payload.write(fragmented, 5, firstLength);
        payload.write(fragmented, secondStart + 5, FirstFlight.u16(fragmented, secondStart + 3));
        check(Arrays.equals(payload.toByteArray(), Arrays.copyOfRange(hello, 5, hello.length)), "Record splitting changed handshake bytes");
        InputStream chunked = new ByteArrayInputStream(hello) {
            public synchronized int read(byte[] bytes, int offset, int length) { return super.read(bytes, offset, Math.min(1, length)); }
        };
        check(Arrays.equals(FirstFlight.read(chunked), hello), "Short socket reads broke ClientHello assembly");
        byte[] http = "GET / HTTP/1.1\r\nHost: DISCORD.COM:443\r\n\r\n".getBytes(StandardCharsets.US_ASCII);
        check("discord.com".equals(FirstFlight.hostname(http)), "HTTP host parsing failed");
        InputStream httpChunks = new ByteArrayInputStream(http) {
            public synchronized int read(byte[] bytes, int offset, int length) { return super.read(bytes, offset, Math.min(1, length)); }
        };
        check(Arrays.equals(FirstFlight.read(httpChunks), http), "Short reads broke HTTP header assembly");
    }
    private static byte[] clientHello(String host) throws Exception {
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        body.write(new byte[] {3, 3}); body.write(new byte[32]);
        body.write(new byte[] {0, 0, 2, 0x13, 1, 1, 0});
        byte[] name = host.getBytes(StandardCharsets.US_ASCII);
        int extensions = name.length + 9;
        u16(body, extensions); u16(body, 0); u16(body, name.length + 5);
        u16(body, name.length + 3); body.write(0); u16(body, name.length); body.write(name);
        ByteArrayOutputStream handshake = new ByteArrayOutputStream();
        handshake.write(1); handshake.write(0); u16(handshake, body.size()); handshake.write(body.toByteArray());
        ByteArrayOutputStream record = new ByteArrayOutputStream();
        record.write(new byte[] {22, 3, 1}); u16(record, handshake.size()); record.write(handshake.toByteArray());
        return record.toByteArray();
    }
    private static void tcpTest() throws Exception {
        try (ServerSocket echo = new ServerSocket(0, 1, InetAddress.getLoopbackAddress());
             LocalProxy proxy = new LocalProxy(PROTECT, null, true, false, Collections.emptySet())) {
            FutureTask<Void> server = start(() -> {
                try (Socket socket = echo.accept()) {
                    byte[] payload = exact(socket.getInputStream(), 5);
                    socket.getOutputStream().write(payload);
                } return null;
            });
            try (Socket client = request(proxy.port(), 1, "127.0.0.1", echo.getLocalPort())) {
                client.getOutputStream().write("hello".getBytes(StandardCharsets.US_ASCII));
                check("hello".equals(new String(exact(client.getInputStream(), 5), StandardCharsets.US_ASCII)), "TCP relay lost bytes");
                client.shutdownOutput();
                check(client.getInputStream().read() == -1, "TCP final EOF not forwarded");
            }
            server.get(5, TimeUnit.SECONDS);
        }
    }
    private static void udpAndDnsTest() throws Exception {
        AtomicInteger dnsQueries = new AtomicInteger();
        LocalProxy.DnsResolver resolver = query -> { dnsQueries.incrementAndGet(); byte[] response = query.clone(); response[2] |= (byte) 0x80; return response; };
        try (DatagramSocket echo = new DatagramSocket(new InetSocketAddress("127.0.0.1", 0));
             LocalProxy proxy = new LocalProxy(PROTECT, resolver, false, true, Collections.singleton("discord.com"));
             Socket control = handshake(proxy.port());
             DatagramSocket sender = new DatagramSocket(new InetSocketAddress("127.0.0.1", 0))) {
            FutureTask<Void> server = start(() -> {
                byte[] buffer = new byte[100]; DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
                echo.receive(packet); echo.send(packet); return null;
            });
            sendRequest(control, 3, "0.0.0.0", 0);
            InetSocketAddress relay = readReply(control);
            sender.setSoTimeout(5000);
            byte[] payload = new byte[] {1, 2, 3, 4};
            byte[] message = udpMessage("127.0.0.1", echo.getLocalPort(), payload);
            sender.send(new DatagramPacket(message, message.length, relay));
            DatagramPacket response = new DatagramPacket(new byte[100], 100); sender.receive(response);
            check(Arrays.equals(Arrays.copyOf(response.getData(), response.getLength()), message), "UDP relay changed destination or payload");
            server.get(5, TimeUnit.SECONDS);
            byte[] query = new byte[12]; query[0] = 42; query[1] = 7;
            message = udpMessage("1.1.1.1", 53, query);
            sender.send(new DatagramPacket(message, message.length, relay)); sender.receive(response);
            check(response.getData()[10] == 42 && (response.getData()[12] & 0x80) != 0, "DNS-over-HTTPS routing failed");
            try (Socket tcpDns = request(proxy.port(), 1, "1.1.1.1", 53)) {
                u16(tcpDns.getOutputStream(), query.length); tcpDns.getOutputStream().write(query);
                check(FirstFlight.u16(exact(tcpDns.getInputStream(), 2), 0) == 12, "TCP DNS framing failed");
                check((exact(tcpDns.getInputStream(), 12)[2] & 0x80) != 0, "TCP DNS did not use encrypted resolver");
            }
            check(dnsQueries.get() == 2, "DNS query escaped the configured resolver");
            message = udpMessage("127.0.0.1", echo.getLocalPort(), payload); message[2] = 1;
            sender.send(new DatagramPacket(message, message.length, relay)); sender.setSoTimeout(200);
            boolean rejected = false;
            try { sender.receive(response); } catch (SocketTimeoutException expected) { rejected = true; }
            check(rejected, "Unsupported fragmented UDP packet was accepted");
        }
    }
    private static void ipv6Test() throws Exception {
        try (ServerSocket echo = new ServerSocket(0, 1, InetAddress.getByName("::1"));
             LocalProxy proxy = new LocalProxy(PROTECT, null, true, false, Collections.emptySet())) {
            FutureTask<Void> server = start(() -> {
                try (Socket socket = echo.accept()) { socket.getOutputStream().write(99); } return null;
            });
            try (Socket client = request(proxy.port(), 1, "::1", echo.getLocalPort())) {
                check(client.getInputStream().read() == 99, "IPv6/server-first connection failed");
            }
            server.get(5, TimeUnit.SECONDS);
        }
    }
    private static void authenticationTest() throws Exception {
        try (LocalProxy proxy = new LocalProxy(PROTECT, null, false, true, Collections.emptySet());
             Socket socket = new Socket("127.0.0.1", proxy.port())) {
            socket.setSoTimeout(5000);
            socket.getOutputStream().write(new byte[] {5, 1, 2});
            check(Arrays.equals(exact(socket.getInputStream(), 2), new byte[] {5, (byte) 255}), "Unsupported SOCKS authentication accepted");
        }
        try (LocalProxy proxy = new LocalProxy(PROTECT, null, false, true, Collections.emptySet(), "private-token")) {
            try (Socket socket = new Socket("127.0.0.1", proxy.port())) {
                socket.setSoTimeout(5000);
                socket.getOutputStream().write(new byte[] {5, 1, 0});
                check(Arrays.equals(exact(socket.getInputStream(), 2), new byte[] {5, (byte) 255}), "Production proxy allowed unauthenticated access");
            }
            for (String password : new String[] {"private-token", "incorrect-token"}) {
                try (Socket socket = new Socket("127.0.0.1", proxy.port())) {
                    socket.setSoTimeout(5000);
                    socket.getOutputStream().write(new byte[] {5, 1, 2});
                    check(Arrays.equals(exact(socket.getInputStream(), 2), new byte[] {5, 2}), "Authenticated SOCKS method was not negotiated");
                    byte[] secret = password.getBytes(StandardCharsets.US_ASCII);
                    socket.getOutputStream().write(new byte[] {1, 3, 'd', 'p', 'i', (byte) secret.length});
                    socket.getOutputStream().write(secret);
                    check(Arrays.equals(exact(socket.getInputStream(), 2), new byte[] {1, (byte) (password.equals("private-token") ? 0 : 1)}), "Incorrect credential verification");
                }
            }
        }
    }
    private static void tlsTest(String keystore, boolean records) throws Exception {
        char[] password = "test-password".toCharArray();
        KeyStore keys = KeyStore.getInstance("PKCS12");
        try (InputStream input = new FileInputStream(keystore)) { keys.load(input, password); }
        KeyManagerFactory manager = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()); manager.init(keys, password);
        SSLContext serverContext = SSLContext.getInstance("TLS"); serverContext.init(manager.getKeyManagers(), null, null);
        // This trust manager is confined to a localhost test fixture, never the application.
        TrustManager[] trustFixture = {new X509TrustManager() {
            public java.security.cert.X509Certificate[] getAcceptedIssuers() { return new java.security.cert.X509Certificate[0]; }
            public void checkClientTrusted(java.security.cert.X509Certificate[] chain, String auth) { }
            public void checkServerTrusted(java.security.cert.X509Certificate[] chain, String auth) { }
        }};
        SSLContext clientContext = SSLContext.getInstance("TLS"); clientContext.init(null, trustFixture, null);
        try (SSLServerSocket server = (SSLServerSocket) serverContext.getServerSocketFactory().createServerSocket(0, 1, InetAddress.getLoopbackAddress());
             LocalProxy proxy = new LocalProxy(PROTECT, null, true, records, Collections.emptySet())) {
            FutureTask<Void> result = start(() -> {
                try (SSLSocket socket = (SSLSocket) server.accept()) {
                    socket.setSoTimeout(5000); socket.startHandshake();
                    check(socket.getInputStream().read() == 42, "TLS request changed");
                    socket.getOutputStream().write(43);
                } return null;
            });
            try (Socket socket = request(proxy.port(), 1, "127.0.0.1", server.getLocalPort());
                 SSLSocket tls = (SSLSocket) clientContext.getSocketFactory().createSocket(socket, "localhost", server.getLocalPort(), true)) {
                tls.setSoTimeout(5000); tls.startHandshake(); tls.getOutputStream().write(42);
                check(tls.getInputStream().read() == 43, "TLS handshake/data failed with records=" + records);
            }
            result.get(5, TimeUnit.SECONDS);
        }
    }
    private static Socket handshake(int port) throws Exception {
        Socket socket = new Socket("127.0.0.1", port); socket.setSoTimeout(5000);
        socket.getOutputStream().write(new byte[] {5, 1, 0});
        check(Arrays.equals(exact(socket.getInputStream(), 2), new byte[] {5, 0}), "SOCKS handshake failed");
        return socket;
    }
    private static Socket request(int proxy, int command, String host, int port) throws Exception {
        Socket socket = handshake(proxy); sendRequest(socket, command, host, port); readReply(socket); return socket;
    }
    private static void sendRequest(Socket socket, int command, String host, int port) throws Exception {
        socket.getOutputStream().write(new byte[] {5, (byte) command, 0}); address(socket.getOutputStream(), host, port);
    }
    private static InetSocketAddress readReply(Socket socket) throws Exception {
        byte[] header = exact(socket.getInputStream(), 4);
        check(header[0] == 5 && header[1] == 0, "SOCKS request failed");
        byte[] address = exact(socket.getInputStream(), header[3] == 1 ? 4 : 16);
        int port = FirstFlight.u16(exact(socket.getInputStream(), 2), 0);
        return new InetSocketAddress(InetAddress.getByAddress(address), port);
    }
    private static byte[] udpMessage(String host, int port, byte[] payload) throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream(); bytes.write(new byte[] {0, 0, 0}); address(bytes, host, port); bytes.write(payload); return bytes.toByteArray();
    }
    private static void address(OutputStream output, String host, int port) throws Exception {
        byte[] bytes = InetAddress.getByName(host).getAddress(); output.write(bytes.length == 4 ? 1 : 4); output.write(bytes); u16(output, port);
    }
    private static void u16(OutputStream output, int value) throws IOException { output.write(value >> 8); output.write(value & 255); }
    private static byte[] exact(InputStream input, int length) throws IOException {
        byte[] bytes = new byte[length]; int count = 0;
        while (count < length) { int read = input.read(bytes, count, length - count); if (read < 0) throw new EOFException(); count += read; }
        return bytes;
    }
    private static FutureTask<Void> start(Callable<Void> action) {
        FutureTask<Void> task = new FutureTask<>(action); Thread thread = new Thread(task); thread.setDaemon(true); thread.start(); return task;
    }
}
