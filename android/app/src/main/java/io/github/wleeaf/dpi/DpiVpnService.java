package io.github.wleeaf.dpi;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.VpnService;
import android.os.ParcelFileDescriptor;
import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.net.DatagramSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import hev.htproxy.TProxyService;

public final class DpiVpnService extends VpnService {
    public static final String START = "io.github.wleeaf.dpi.START";
    public static final String STOP = "io.github.wleeaf.dpi.STOP";
    private static final String CHANNEL = "dpi-vpn";
    public static volatile boolean connected;
    public static volatile boolean connecting;
    private final ScheduledExecutorService lifecycle = Executors.newSingleThreadScheduledExecutor();
    private ParcelFileDescriptor tunnel;
    private LocalProxy proxy;
    private boolean nativeStarted;
    private volatile boolean destroyed;
    private boolean failed;
    private SharedPreferences preferences;

    @Override public void onCreate() {
        super.onCreate();
        preferences = getSharedPreferences("dpi", MODE_PRIVATE);
        ((NotificationManager) getSystemService(NOTIFICATION_SERVICE)).createNotificationChannel(
            new NotificationChannel(CHANNEL, "DPI connection", NotificationManager.IMPORTANCE_LOW));
        lifecycle.scheduleWithFixedDelay(() -> {
            if (nativeStarted && !TProxyService.TProxyIsRunning()) {
                disconnect(); failed = true;
                setState("The local tunnel stopped. Tap Connect to retry.", false);
                stopSelf();
            } else if (nativeStarted) {
                long[] traffic = TProxyService.TProxyGetStats();
                preferences.edit().putLong("txPackets", traffic[0]).putLong("rxPackets", traffic[2]).apply();
            }
        }, 1, 1, TimeUnit.SECONDS);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && STOP.equals(intent.getAction())) {
            lifecycle.execute(() -> { disconnect(); stopSelf(startId); });
            return START_NOT_STICKY;
        }
        // Required promptly after startForegroundService; setup runs off the UI thread.
        if (connected) return START_NOT_STICKY;
        connecting = true;
        startForeground(1, notification("Connecting…"));
        lifecycle.execute(() -> {
            if (destroyed || tunnel != null) { connecting = false; return; }
            try { connect(); }
            catch (Exception | LinkageError exception) {
                disconnect();
                failed = true;
                setState("Connection failed: " + safeMessage(exception), false);
                stopSelf(startId);
            }
        });
        return START_NOT_STICKY;
    }

    private void connect() throws Exception {
        failed = false;
        setState("Connecting…", false);
        boolean all = preferences.getBoolean("all", false);
        boolean records = preferences.getBoolean("records", true);
        boolean encryptedDns = preferences.getBoolean("encryptedDns", true);
        Set<String> domains = new HashSet<>();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(getAssets().open("discord.txt"), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                line = line.split("#", 2)[0].trim();
                if (!line.isEmpty()) domains.add(line);
            }
        }
        Builder builder = new Builder().setSession("DPI").setMtu(1280)
            .addAddress("198.18.0.1", 32).addAddress("fd00:198:18::1", 128)
            .addRoute("0.0.0.0", 0).addRoute("::", 0).addDnsServer("1.1.1.1");
        if (all) {
            builder.addDisallowedApplication(getPackageName());
        } else {
            getPackageManager().getApplicationInfo("com.discord", 0);
            builder.addAllowedApplication("com.discord");
        }
        String token = UUID.randomUUID().toString();
        proxy = new LocalProxy(new LocalProxy.Protector() {
            @Override public boolean protect(Socket socket) { return DpiVpnService.this.protect(socket); }
            @Override public boolean protect(DatagramSocket socket) { return DpiVpnService.this.protect(socket); }
        }, encryptedDns ? new HttpsDns() : null, all, records, domains, token);
        File config = new File(getFilesDir(), "tunnel.yml");
        String yaml = "tunnel:\n  mtu: 1280\n  ipv4: 198.18.0.1\n  ipv6: 'fd00:198:18::1'\n"
            + "socks5:\n  address: 127.0.0.1\n  port: " + proxy.port() + "\n  udp: 'udp'\n"
            + "  username: 'dpi'\n  password: '" + token + "'\n"
            + "misc:\n  connect-timeout: 10000\n  tcp-read-write-timeout: 300000\n"
            + "  udp-read-write-timeout: 60000\n  max-session-count: 48\n  log-level: error\n";
        Files.write(config.toPath(), yaml.getBytes(StandardCharsets.UTF_8));
        tunnel = builder.establish();
        if (tunnel == null) throw new IllegalStateException("VPN permission was revoked. Tap Connect again.");
        if (!TProxyService.TProxyStartService(config.getAbsolutePath(), tunnel.getFd())) {
            throw new IllegalStateException("The local tunnel could not start.");
        }
        nativeStarted = true;
        if (!TProxyService.TProxyIsRunning()) throw new IllegalStateException("The local tunnel stopped during startup.");
        setState(all ? "Connected · all apps" : "Connected · Discord", true);
        ((NotificationManager) getSystemService(NOTIFICATION_SERVICE)).notify(1, notification("Connected"));
    }

    private void disconnect() {
        if (nativeStarted) { TProxyService.TProxyStopService(); nativeStarted = false; }
        if (tunnel != null) {
            try { tunnel.close(); } catch (java.io.IOException ignored) { }
            tunnel = null;
        }
        if (proxy != null) { proxy.close(); proxy = null; }
        connecting = false; connected = false;
        if (!failed) setState("Disconnected", false);
        stopForeground(STOP_FOREGROUND_REMOVE);
    }

    private Notification notification(String text) {
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), PendingIntent.FLAG_IMMUTABLE);
        PendingIntent stop = PendingIntent.getService(this, 1, new Intent(this, DpiVpnService.class).setAction(STOP), PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this, CHANNEL).setContentTitle("DPI").setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download_done).setOngoing(true).setContentIntent(open)
            .addAction(new Notification.Action.Builder(null, "Disconnect", stop).build()).build();
    }

    private void setState(String state, boolean connected) {
        DpiVpnService.connected = connected;
        if (connected) connecting = false;
        preferences.edit().putString("state", state).putBoolean("connected", connected).apply();
    }
    private static String safeMessage(Throwable exception) {
        if (exception instanceof android.content.pm.PackageManager.NameNotFoundException) return "Install Discord, or select All apps.";
        String message = exception.getMessage();
        return message == null ? exception.getClass().getSimpleName() : message;
    }

    @Override public void onRevoke() {
        lifecycle.execute(() -> { disconnect(); stopSelf(); });
        super.onRevoke();
    }
    @Override public void onDestroy() {
        destroyed = true;
        lifecycle.execute(this::disconnect);
        lifecycle.shutdown();
        super.onDestroy();
    }
}
