package io.github.wleeaf.dpi;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.VpnService;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.WindowInsets;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

public final class MainActivity extends Activity {
    private final Handler handler = new Handler(Looper.getMainLooper());
    private SharedPreferences preferences;
    private TextView status;
    private Button connect;
    private CheckBox all, records, encryptedDns;
    private final Runnable refresh = new Runnable() {
        @Override public void run() {
            status.setText(preferences.getString("state", "Disconnected"));
            boolean active = DpiVpnService.connected;
            connect.setText(active ? "Disconnect" : "Connect");
            connect.setEnabled(!DpiVpnService.connecting);
            all.setEnabled(!active && !DpiVpnService.connecting); records.setEnabled(!active && !DpiVpnService.connecting); encryptedDns.setEnabled(!active && !DpiVpnService.connecting);
            handler.postDelayed(this, 750);
        }
    };

    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        preferences = getSharedPreferences("dpi", MODE_PRIVATE);
        if (preferences.getBoolean("connected", false) && !DpiVpnService.connected && !DpiVpnService.connecting) {
            preferences.edit().putBoolean("connected", false).putString("state", "Disconnected").apply();
        }
        ScrollView scroll = new ScrollView(this);
        LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL);
        int space = dp(24); layout.setPadding(space, space, space, space);
        scroll.addView(layout); setContentView(scroll);
        scroll.setOnApplyWindowInsetsListener((view, insets) -> {
            int top, bottom;
            if (Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars());
                top = bars.top; bottom = bars.bottom;
            } else { top = insets.getSystemWindowInsetTop(); bottom = insets.getSystemWindowInsetBottom(); }
            layout.setPadding(space, space + top, space, space + bottom); return insets;
        });
        TextView title = text("DPI", 34); title.setTextColor(Color.rgb(15, 23, 42)); layout.addView(title);
        layout.addView(text("Open Discord with a local bypass.", 18));
        status = text(preferences.getString("state", "Disconnected"), 18); status.setPadding(0, dp(32), 0, dp(24)); layout.addView(status);
        connect = new Button(this); connect.setText("Connect"); connect.setMinHeight(dp(56)); layout.addView(connect);
        all = option("All apps (default: Discord only)", "all", false); layout.addView(all);
        records = option("TLS record splitting", "records", true); layout.addView(records);
        encryptedDns = option("Encrypted DNS (Cloudflare)", "encryptedDns", true); layout.addView(encryptedDns);
        TextView note = text("No account, remote tunnel server, or root required. Android asks for VPN permission.\n\nThis app splits TCP/TLS traffic. Voice and other UDP traffic are forwarded unchanged; voice bypass depends on your network. Another VPN cannot run alongside it.", 14);
        note.setPadding(0, dp(24), 0, dp(16)); layout.addView(note);
        connect.setOnClickListener(view -> {
            if (DpiVpnService.connected) {
                startService(new Intent(this, DpiVpnService.class).setAction(DpiVpnService.STOP));
                return;
            }
            preferences.edit().putBoolean("all", all.isChecked()).putBoolean("records", records.isChecked()).putBoolean("encryptedDns", encryptedDns.isChecked()).apply();
            Intent permission = VpnService.prepare(this);
            if (permission != null) startActivityForResult(permission, 1);
            else startConnection();
        });
    }
    private void startConnection() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, 2);
        }
        DpiVpnService.connecting = true;
        connect.setEnabled(false);
        status.setText("Connecting…");
        startForegroundService(new Intent(this, DpiVpnService.class).setAction(DpiVpnService.START));
    }
    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == 1) {
            if (resultCode == RESULT_OK) startConnection();
            else preferences.edit().putString("state", "VPN permission was declined.").putBoolean("connected", false).apply();
        }
    }
    @Override protected void onResume() { super.onResume(); handler.post(refresh); }
    @Override protected void onPause() { handler.removeCallbacks(refresh); super.onPause(); }
    private CheckBox option(String label, String key, boolean fallback) {
        CheckBox checkbox = new CheckBox(this); checkbox.setText(label); checkbox.setChecked(preferences.getBoolean(key, fallback)); checkbox.setPadding(0, dp(12), 0, 0); return checkbox;
    }
    private TextView text(String value, int size) { TextView view = new TextView(this); view.setText(value); view.setTextSize(size); view.setTextColor(Color.rgb(71, 85, 105)); return view; }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
}
