package io.github.wleeaf.dpi.probe;

import android.app.Instrumentation;
import android.os.Bundle;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.DatagramSocket;
import java.net.DatagramPacket;
import java.net.InetSocketAddress;
import java.io.InputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

/** Runs under a separate app UID, so its sockets genuinely traverse the VPN. */
public final class SmokeRunner extends Instrumentation {
    private Bundle arguments;
    @Override public void onCreate(Bundle args) { super.onCreate(args); arguments = args; start(); }
    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            int tcpPort = Integer.parseInt(arguments.getString("tcpPort"));
            int udpPort = Integer.parseInt(arguments.getString("udpPort"));
            HttpURLConnection http = (HttpURLConnection) new URL("http://10.0.2.2:" + tcpPort + "/dpi-smoke").openConnection();
            http.setConnectTimeout(10000); http.setReadTimeout(10000);
            try {
                if (http.getResponseCode() != 200) throw new AssertionError("HTTP did not reach the local fixture");
                ByteArrayOutputStream body = new ByteArrayOutputStream();
                try (InputStream input = http.getInputStream()) {
                    byte[] buffer = new byte[128]; int count;
                    while ((count = input.read(buffer)) != -1) body.write(buffer, 0, count);
                }
                if (!"dpi-smoke-ok".equals(new String(body.toByteArray(), StandardCharsets.UTF_8))) throw new AssertionError("HTTP bytes changed");
            } finally { http.disconnect(); }
            try (DatagramSocket socket = new DatagramSocket()) {
                socket.setSoTimeout(10000);
                byte[] bytes = "voice-probe".getBytes(StandardCharsets.UTF_8);
                socket.send(new DatagramPacket(bytes, bytes.length, new InetSocketAddress("10.0.2.2", udpPort)));
                DatagramPacket response = new DatagramPacket(new byte[128], 128); socket.receive(response);
                if (!"voice-probe".equals(new String(response.getData(), 0, response.getLength(), StandardCharsets.UTF_8))) throw new AssertionError("UDP bytes changed");
            }
            result.putString("stream", "DPI_SMOKE_PASSED: real VPN TCP and UDP traffic");
            finish(0, result);
        } catch (Throwable exception) {
            result.putString("stream", "DPI_SMOKE_FAILED: " + exception.toString());
            finish(1, result);
        }
    }
}
