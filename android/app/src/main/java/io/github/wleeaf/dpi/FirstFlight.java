package io.github.wleeaf.dpi;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Locale;
import java.util.Set;

/** Stream-level strategies. Never decrypt TLS or change handshake payload bytes. */
public final class FirstFlight {
    private FirstFlight() { }

    public static byte[] read(InputStream input) throws IOException {
        byte[] buffer = new byte[18437];
        int count = input.read(buffer, 0, 8192);
        if (count < 0) return new byte[0];
        if (buffer[0] == 22) {
            count = complete(input, buffer, count, 5);
            if (count >= 5) {
                int length = u16(buffer, 3);
                if (length <= 18432) count = complete(input, buffer, count, length + 5);
            }
        } else {
            while (count < 8 && couldBeHttp(buffer, count)) {
                int next = input.read();
                if (next < 0) break;
                buffer[count++] = (byte) next;
            }
        }
        if (isHttp(buffer, count)) {
            while (count < buffer.length && headerEnd(buffer, count) < 0) {
                int next = input.read(buffer, count, buffer.length - count);
                if (next < 0) break;
                count += next;
            }
        }
        return Arrays.copyOf(buffer, count);
    }

    private static int complete(InputStream input, byte[] bytes, int count, int target) throws IOException {
        while (count < target) {
            int next = input.read(bytes, count, target - count);
            if (next < 0) break;
            count += next;
        }
        return count;
    }

    private static boolean isHttp(byte[] bytes, int count) {
        String prefix = new String(bytes, 0, Math.min(count, 8), StandardCharsets.US_ASCII);
        return prefix.startsWith("GET ") || prefix.startsWith("POST ") || prefix.startsWith("HEAD ")
            || prefix.startsWith("PUT ") || prefix.startsWith("OPTIONS ") || prefix.startsWith("CONNECT ")
            || prefix.startsWith("DELETE ") || prefix.startsWith("PATCH ");
    }

    private static boolean couldBeHttp(byte[] bytes, int count) {
        String prefix = new String(bytes, 0, count, StandardCharsets.US_ASCII);
        for (String method : new String[] {"GET ", "POST ", "HEAD ", "PUT ", "OPTIONS ", "CONNECT ", "DELETE ", "PATCH "}) {
            if (method.startsWith(prefix)) return true;
        }
        return false;
    }

    private static int headerEnd(byte[] bytes, int count) {
        for (int i = 3; i < count; i++) {
            if (bytes[i - 3] == 13 && bytes[i - 2] == 10 && bytes[i - 1] == 13 && bytes[i] == 10) return i + 1;
        }
        return -1;
    }

    public static String hostname(byte[] bytes) {
        int[] range = sniRange(bytes);
        if (range != null) return normalize(new String(bytes, range[0], range[1], StandardCharsets.US_ASCII));
        if (isHttp(bytes, bytes.length)) {
            String header = new String(bytes, StandardCharsets.ISO_8859_1);
            for (String line : header.split("\r\n")) {
                if (line.toLowerCase(Locale.ROOT).startsWith("host:")) {
                    String host = line.substring(5).trim();
                    int colon = host.indexOf(':');
                    return normalize(colon < 0 ? host : host.substring(0, colon));
                }
            }
        }
        return null;
    }

    private static String normalize(String host) {
        String result = host.toLowerCase(Locale.ROOT);
        return result.endsWith(".") ? result.substring(0, result.length() - 1) : result;
    }

    public static boolean matches(String host, Set<String> domains) {
        if (host == null) return false;
        host = normalize(host);
        for (String domain : domains) {
            if (host.equals(domain) || host.endsWith("." + domain)) return true;
        }
        return false;
    }

    static int[] sniRange(byte[] bytes) {
        try {
            if (bytes.length < 44 || bytes[0] != 22 || bytes[5] != 1) return null;
            int recordEnd = Math.min(bytes.length, 5 + u16(bytes, 3));
            int offset = 43;
            offset += 1 + (bytes[offset] & 255); // session ID
            int cipherLength = u16(bytes, offset);
            offset += 2 + cipherLength;
            offset += 1 + (bytes[offset] & 255); // compression methods
            int extensionLength = u16(bytes, offset);
            offset += 2;
            int end = Math.min(recordEnd, offset + extensionLength);
            while (offset + 4 <= end) {
                int type = u16(bytes, offset), length = u16(bytes, offset + 2);
                offset += 4;
                if (offset + length > end) return null;
                if (type == 0 && length >= 5) {
                    int namesEnd = Math.min(offset + length, offset + 2 + u16(bytes, offset));
                    int nameOffset = offset + 2;
                    while (nameOffset + 3 <= namesEnd) {
                        int nameType = bytes[nameOffset] & 255, nameLength = u16(bytes, nameOffset + 1);
                        nameOffset += 3;
                        if (nameOffset + nameLength > namesEnd) return null;
                        if (nameType == 0 && nameLength > 0) return new int[] { nameOffset, nameLength };
                        nameOffset += nameLength;
                    }
                }
                offset += length;
            }
        } catch (IndexOutOfBoundsException ignored) { /* malformed/truncated ClientHello */ }
        return null;
    }

    public static byte[] splitTlsRecord(byte[] bytes) {
        if (bytes.length < 7 || bytes[0] != 22) return bytes;
        int length = u16(bytes, 3);
        if (length < 2 || length + 5 > bytes.length) return bytes;
        int[] sni = sniRange(bytes);
        int position = sni == null ? 1 : sni[0] + Math.max(1, sni[1] / 2) - 5;
        position = Math.min(length - 1, Math.max(1, position));
        ByteArrayOutputStream output = new ByteArrayOutputStream(bytes.length + 5);
        output.write(bytes, 0, 3);
        output.write(position >> 8); output.write(position & 255);
        output.write(bytes, 5, position);
        output.write(bytes, 0, 3);
        output.write((length - position) >> 8); output.write((length - position) & 255);
        output.write(bytes, 5 + position, length - position);
        output.write(bytes, length + 5, bytes.length - length - 5);
        return output.toByteArray();
    }

    public static void write(OutputStream output, byte[] bytes, boolean records) throws IOException {
        byte[] result = records ? splitTlsRecord(bytes) : bytes;
        if (result.length == 0) return;
        int[] range = sniRange(result);
        int middle = range == null ? -1 : range[0] + Math.max(1, range[1] / 2);
        output.write(result, 0, 1); output.flush(); pause();
        if (middle > 1 && middle < result.length) {
            output.write(result, 1, middle - 1); output.flush(); pause();
            output.write(result, middle, result.length - middle);
        } else {
            output.write(result, 1, result.length - 1);
        }
        output.flush();
    }

    private static void pause() throws IOException {
        try { Thread.sleep(10); }
        catch (InterruptedException exception) { Thread.currentThread().interrupt(); throw new IOException("Stopped", exception); }
    }

    static int u16(byte[] bytes, int offset) { return ((bytes[offset] & 255) << 8) | (bytes[offset + 1] & 255); }
}
