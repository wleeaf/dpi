package io.github.wleeaf.dpi;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URL;
import javax.net.ssl.HttpsURLConnection;

/** DNS wire messages over HTTPS, with normal platform certificate validation. */
public final class HttpsDns implements LocalProxy.DnsResolver {
    @Override public byte[] resolve(byte[] query) throws IOException {
        if (query.length < 12 || query.length > 4096) throw new IOException("Invalid DNS query length");
        HttpsURLConnection connection = (HttpsURLConnection) new URL("https://cloudflare-dns.com/dns-query").openConnection();
        connection.setConnectTimeout(5000); connection.setReadTimeout(5000);
        connection.setRequestMethod("POST"); connection.setDoOutput(true);
        connection.setInstanceFollowRedirects(false);
        connection.setRequestProperty("Content-Type", "application/dns-message");
        connection.setRequestProperty("Accept", "application/dns-message");
        connection.setFixedLengthStreamingMode(query.length);
        try {
            try (java.io.OutputStream output = connection.getOutputStream()) { output.write(query); }
            if (connection.getResponseCode() != 200) throw new IOException("DNS HTTPS request failed");
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            try (InputStream input = connection.getInputStream()) {
                byte[] buffer = new byte[1024]; int count;
                while ((count = input.read(buffer)) != -1) {
                    if (bytes.size() + count > 65535) throw new IOException("DNS response too large");
                    bytes.write(buffer, 0, count);
                }
            }
            byte[] response = bytes.toByteArray();
            if (response.length < 12 || response[0] != query[0] || response[1] != query[1] || (response[2] & 0x80) == 0) {
                throw new IOException("Invalid DNS response");
            }
            return response;
        } finally { connection.disconnect(); }
    }
}
