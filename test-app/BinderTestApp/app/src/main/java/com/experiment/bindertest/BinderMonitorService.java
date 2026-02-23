package com.experiment.bindertest;

import android.app.ActivityManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.DeadObjectException;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.RemoteException;
import android.util.Log;

/**
 * 后台服务 - 持续监控 Binder 连接状态
 * 即使 Activity 被销毁，服务仍然运行
 */
public class BinderMonitorService extends Service {

    private static final String TAG = "BinderMonitorService";
    private static final String CHANNEL_ID = "binder_monitor_channel";
    private static final int NOTIFICATION_ID = 1;
    private static final int MONITOR_INTERVAL_MS = 10000; // 10 秒

    private Handler handler;
    private boolean isMonitoring = false;

    // 在服务启动时获取的 Binder 引用
    private ActivityManager activityManager;
    private PackageManager packageManager;

    // 统计
    private int totalChecks = 0;
    private int failedChecks = 0;
    private long serviceStartTime;

    @Override
    public void onCreate() {
        super.onCreate();
        Log.i(TAG, "服务创建");
        
        handler = new Handler(Looper.getMainLooper());
        serviceStartTime = System.currentTimeMillis();
        
        // 获取系统服务引用
        initServices();
        
        // 创建通知渠道
        createNotificationChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Log.i(TAG, "服务启动");
        
        // 启动前台服务
        startForeground(NOTIFICATION_ID, createNotification("监控中..."));
        
        // 开始监控
        startMonitoring();
        
        return START_STICKY;
    }

    private void initServices() {
        Log.i(TAG, "初始化服务引用...");
        
        try {
            activityManager = (ActivityManager) getSystemService(Context.ACTIVITY_SERVICE);
            Log.i(TAG, "ActivityManager 已获取");
        } catch (Exception e) {
            Log.e(TAG, "ActivityManager 获取失败", e);
        }

        try {
            packageManager = getPackageManager();
            Log.i(TAG, "PackageManager 已获取");
        } catch (Exception e) {
            Log.e(TAG, "PackageManager 获取失败", e);
        }
    }

    private void startMonitoring() {
        if (isMonitoring) return;
        
        isMonitoring = true;
        Log.i(TAG, "开始 Binder 监控");
        
        runMonitor();
    }

    private void stopMonitoring() {
        isMonitoring = false;
        Log.i(TAG, "停止 Binder 监控");
    }

    private void runMonitor() {
        if (!isMonitoring) return;

        performBinderCheck();

        handler.postDelayed(this::runMonitor, MONITOR_INTERVAL_MS);
    }

    private void performBinderCheck() {
        totalChecks++;
        boolean hasFailed = false;

        Log.d(TAG, "执行 Binder 检查 #" + totalChecks);

        // 检查 ActivityManager
        try {
            if (activityManager != null) {
                activityManager.getMemoryClass();
                Log.d(TAG, "ActivityManager: OK");
            }
        } catch (Exception e) {
            hasFailed = true;
            handleBinderFailure("ActivityManager", e);
        }

        // 检查 PackageManager
        try {
            if (packageManager != null) {
                packageManager.getPackageInfo(getPackageName(), 0);
                Log.d(TAG, "PackageManager: OK");
            }
        } catch (Exception e) {
            hasFailed = true;
            handleBinderFailure("PackageManager", e);
        }

        // 检查 ServiceManager（通过反射）
        try {
            checkServiceManagerBinder();
            Log.d(TAG, "ServiceManager: OK");
        } catch (Exception e) {
            hasFailed = true;
            handleBinderFailure("ServiceManager", e);
        }

        if (hasFailed) {
            failedChecks++;
            updateNotification("⚠️ Binder 故障! 失败: " + failedChecks + "/" + totalChecks);
        } else {
            updateNotification("✓ 监控中 (" + totalChecks + " 次检查)");
        }
    }

    private void checkServiceManagerBinder() throws Exception {
        Class<?> serviceManager = Class.forName("android.os.ServiceManager");
        java.lang.reflect.Method getService = serviceManager.getMethod("getService", String.class);
        
        IBinder activityBinder = (IBinder) getService.invoke(null, "activity");
        if (activityBinder == null || !activityBinder.isBinderAlive()) {
            throw new DeadObjectException("activity service Binder is dead");
        }
    }

    private void handleBinderFailure(String serviceName, Exception e) {
        if (e instanceof DeadObjectException || 
            (e.getCause() != null && e.getCause() instanceof DeadObjectException)) {
            Log.e(TAG, "CRITICAL: " + serviceName + " Binder 句柄失效!", e);
            
            // 发送广播通知
            Intent intent = new Intent("com.experiment.bindertest.BINDER_DEAD");
            intent.putExtra("service_name", serviceName);
            intent.putExtra("timestamp", System.currentTimeMillis());
            intent.putExtra("uptime_ms", System.currentTimeMillis() - serviceStartTime);
            sendBroadcast(intent);
            
        } else if (e instanceof RemoteException) {
            Log.e(TAG, serviceName + " RemoteException", e);
        } else {
            Log.e(TAG, serviceName + " 异常: " + e.getClass().getSimpleName(), e);
        }
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                "Binder 监控",
                NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("监控 Binder 连接状态");
            
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) {
                manager.createNotificationChannel(channel);
            }
        }
    }

    private Notification createNotification(String text) {
        Intent notificationIntent = new Intent(this, MainActivity.class);
        PendingIntent pendingIntent = PendingIntent.getActivity(
            this, 0, notificationIntent,
            PendingIntent.FLAG_IMMUTABLE
        );

        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder = new Notification.Builder(this, CHANNEL_ID);
        } else {
            builder = new Notification.Builder(this);
        }

        return builder
            .setContentTitle("Binder 监控服务")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build();
    }

    private void updateNotification(String text) {
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager != null) {
            manager.notify(NOTIFICATION_ID, createNotification(text));
        }
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        stopMonitoring();
        Log.i(TAG, "服务销毁. 总检查: " + totalChecks + ", 失败: " + failedChecks);
    }
}
