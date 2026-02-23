package com.experiment.bindertest;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.location.LocationManager;
import android.media.AudioManager;
import android.net.ConnectivityManager;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Bundle;
import android.os.DeadObjectException;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.RemoteException;
import android.telephony.TelephonyManager;
import android.util.Log;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.ScrollView;
import android.widget.TextView;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

/**
 * 测试 Activity - 用于验证 Binder 句柄在容器快照恢复后是否失效
 */
public class MainActivity extends Activity {

    private static final String TAG = "BinderTest";
    private static final int TEST_INTERVAL_MS = 5000; // 5 秒测试一次

    private TextView statusTextView;
    private TextView logTextView;
    private ScrollView logScrollView;
    private Button startTestButton;
    private Button stopTestButton;
    private Button singleTestButton;

    private Handler handler;
    private boolean isTestRunning = false;
    private int testCount = 0;

    // 持有的系统服务引用（Binder 代理）
    private Map<String, Object> serviceCache = new HashMap<>();

    // 在启动时获取的 Binder 引用
    private ActivityManager activityManager;
    private PackageManager packageManager;
    private WindowManager windowManager;
    private ConnectivityManager connectivityManager;
    private AudioManager audioManager;

    private StringBuilder logBuilder = new StringBuilder();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        initViews();
        initServices();
        
        handler = new Handler(Looper.getMainLooper());

        log("应用启动");
        log("Android 版本: " + Build.VERSION.RELEASE + " (SDK " + Build.VERSION.SDK_INT + ")");
        log("设备: " + Build.MANUFACTURER + " " + Build.MODEL);
        log("================================");
        log("此应用用于测试 Binder 句柄失效问题");
        log("在容器快照恢复后，持有的 Binder 引用可能失效");
        log("================================");
        
        // 初始测试
        performBinderTest();
    }

    private void initViews() {
        statusTextView = findViewById(R.id.statusTextView);
        logTextView = findViewById(R.id.logTextView);
        logScrollView = findViewById(R.id.logScrollView);
        startTestButton = findViewById(R.id.startTestButton);
        stopTestButton = findViewById(R.id.stopTestButton);
        singleTestButton = findViewById(R.id.singleTestButton);

        startTestButton.setOnClickListener(v -> startPeriodicTest());
        stopTestButton.setOnClickListener(v -> stopPeriodicTest());
        singleTestButton.setOnClickListener(v -> performBinderTest());

        updateStatus("就绪");
    }

    private void initServices() {
        log("初始化系统服务引用...");
        
        try {
            activityManager = (ActivityManager) getSystemService(Context.ACTIVITY_SERVICE);
            log("  ✓ ActivityManager 已获取");
        } catch (Exception e) {
            log("  ✗ ActivityManager 获取失败: " + e.getMessage());
        }

        try {
            packageManager = getPackageManager();
            log("  ✓ PackageManager 已获取");
        } catch (Exception e) {
            log("  ✗ PackageManager 获取失败: " + e.getMessage());
        }

        try {
            windowManager = (WindowManager) getSystemService(Context.WINDOW_SERVICE);
            log("  ✓ WindowManager 已获取");
        } catch (Exception e) {
            log("  ✗ WindowManager 获取失败: " + e.getMessage());
        }

        try {
            connectivityManager = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
            log("  ✓ ConnectivityManager 已获取");
        } catch (Exception e) {
            log("  ✗ ConnectivityManager 获取失败: " + e.getMessage());
        }

        try {
            audioManager = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
            log("  ✓ AudioManager 已获取");
        } catch (Exception e) {
            log("  ✗ AudioManager 获取失败: " + e.getMessage());
        }

        log("服务初始化完成");
    }

    private void startPeriodicTest() {
        if (isTestRunning) {
            log("周期测试已在运行");
            return;
        }

        isTestRunning = true;
        testCount = 0;
        updateStatus("周期测试运行中...");
        log("开始周期测试 (间隔: " + TEST_INTERVAL_MS + "ms)");

        startTestButton.setEnabled(false);
        stopTestButton.setEnabled(true);

        runPeriodicTest();

        // 同时启动前台服务
        Intent serviceIntent = new Intent(this, BinderMonitorService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent);
        } else {
            startService(serviceIntent);
        }
    }

    private void stopPeriodicTest() {
        isTestRunning = false;
        updateStatus("已停止");
        log("停止周期测试");

        startTestButton.setEnabled(true);
        stopTestButton.setEnabled(false);

        // 停止前台服务
        stopService(new Intent(this, BinderMonitorService.class));
    }

    private void runPeriodicTest() {
        if (!isTestRunning) return;

        performBinderTest();

        handler.postDelayed(this::runPeriodicTest, TEST_INTERVAL_MS);
    }

    private void performBinderTest() {
        testCount++;
        log("");
        log("========== 测试 #" + testCount + " ==========");

        int successCount = 0;
        int failCount = 0;

        // 测试 ActivityManager
        try {
            testActivityManager();
            successCount++;
        } catch (Exception e) {
            failCount++;
            handleBinderException("ActivityManager", e);
        }

        // 测试 PackageManager
        try {
            testPackageManager();
            successCount++;
        } catch (Exception e) {
            failCount++;
            handleBinderException("PackageManager", e);
        }

        // 测试 WindowManager
        try {
            testWindowManager();
            successCount++;
        } catch (Exception e) {
            failCount++;
            handleBinderException("WindowManager", e);
        }

        // 测试 ConnectivityManager
        try {
            testConnectivityManager();
            successCount++;
        } catch (Exception e) {
            failCount++;
            handleBinderException("ConnectivityManager", e);
        }

        // 测试 AudioManager
        try {
            testAudioManager();
            successCount++;
        } catch (Exception e) {
            failCount++;
            handleBinderException("AudioManager", e);
        }

        // 测试直接 Service 调用
        try {
            testServiceManager();
            successCount++;
        } catch (Exception e) {
            failCount++;
            handleBinderException("ServiceManager", e);
        }

        log("测试结果: 成功=" + successCount + ", 失败=" + failCount);

        if (failCount > 0) {
            updateStatus("⚠️ 检测到 Binder 故障! 失败: " + failCount);
        } else {
            updateStatus("✓ 所有测试通过 (#" + testCount + ")");
        }
    }

    private void testActivityManager() throws Exception {
        if (activityManager == null) {
            throw new Exception("ActivityManager 为 null");
        }
        
        // 尝试调用 Binder 方法
        int memoryClass = activityManager.getMemoryClass();
        log("  ✓ ActivityManager.getMemoryClass() = " + memoryClass);
        
        // 获取运行中的应用
        activityManager.getRunningAppProcesses();
        log("  ✓ ActivityManager.getRunningAppProcesses()");
    }

    private void testPackageManager() throws Exception {
        if (packageManager == null) {
            throw new Exception("PackageManager 为 null");
        }
        
        // 尝试获取包信息
        String packageName = getPackageName();
        packageManager.getPackageInfo(packageName, 0);
        log("  ✓ PackageManager.getPackageInfo()");
        
        // 获取已安装应用列表
        packageManager.getInstalledPackages(0);
        log("  ✓ PackageManager.getInstalledPackages()");
    }

    private void testWindowManager() throws Exception {
        if (windowManager == null) {
            throw new Exception("WindowManager 为 null");
        }
        
        // 获取默认显示
        windowManager.getDefaultDisplay();
        log("  ✓ WindowManager.getDefaultDisplay()");
    }

    private void testConnectivityManager() throws Exception {
        if (connectivityManager == null) {
            throw new Exception("ConnectivityManager 为 null");
        }
        
        // 获取网络信息
        connectivityManager.getActiveNetworkInfo();
        log("  ✓ ConnectivityManager.getActiveNetworkInfo()");
    }

    private void testAudioManager() throws Exception {
        if (audioManager == null) {
            throw new Exception("AudioManager 为 null");
        }
        
        // 获取音量
        int volume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC);
        log("  ✓ AudioManager.getStreamVolume() = " + volume);
    }

    private void testServiceManager() throws Exception {
        // 通过反射测试 ServiceManager（如果可访问）
        try {
            Class<?> serviceManager = Class.forName("android.os.ServiceManager");
            java.lang.reflect.Method getService = serviceManager.getMethod("getService", String.class);
            
            // 测试 activity 服务
            IBinder activityBinder = (IBinder) getService.invoke(null, "activity");
            if (activityBinder != null && activityBinder.isBinderAlive()) {
                log("  ✓ ServiceManager.getService('activity') - Binder 存活");
            } else {
                throw new Exception("activity Binder 已死亡或为 null");
            }
            
            // 测试 package 服务
            IBinder packageBinder = (IBinder) getService.invoke(null, "package");
            if (packageBinder != null && packageBinder.isBinderAlive()) {
                log("  ✓ ServiceManager.getService('package') - Binder 存活");
            } else {
                throw new Exception("package Binder 已死亡或为 null");
            }
            
        } catch (ClassNotFoundException e) {
            log("  - ServiceManager 不可访问（正常）");
        }
    }

    private void handleBinderException(String serviceName, Exception e) {
        String errorType = e.getClass().getSimpleName();
        String message = e.getMessage();
        
        if (e instanceof DeadObjectException) {
            log("  ✗✗✗ " + serviceName + ": DeadObjectException - BINDER 句柄失效!");
            Log.e(TAG, "CRITICAL: Binder dead for " + serviceName, e);
        } else if (e.getCause() instanceof DeadObjectException) {
            log("  ✗✗✗ " + serviceName + ": 底层 DeadObjectException - BINDER 句柄失效!");
            Log.e(TAG, "CRITICAL: Underlying Binder dead for " + serviceName, e);
        } else if (e instanceof RemoteException) {
            log("  ✗ " + serviceName + ": RemoteException - " + message);
            Log.e(TAG, "RemoteException for " + serviceName, e);
        } else {
            log("  ✗ " + serviceName + ": " + errorType + " - " + message);
            Log.e(TAG, "Exception for " + serviceName, e);
        }
    }

    private void updateStatus(String status) {
        runOnUiThread(() -> {
            statusTextView.setText(status);
        });
    }

    private void log(String message) {
        String timestamp = new SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(new Date());
        String logLine = "[" + timestamp + "] " + message;
        
        Log.d(TAG, message);
        
        runOnUiThread(() -> {
            logBuilder.append(logLine).append("\n");
            logTextView.setText(logBuilder.toString());
            
            // 自动滚动到底部
            logScrollView.post(() -> logScrollView.fullScroll(ScrollView.FOCUS_DOWN));
        });
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        stopPeriodicTest();
    }
}
