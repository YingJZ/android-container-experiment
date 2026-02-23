package com.experiment.bindertest;

import android.app.ActivityManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.DeadObjectException;
import android.os.IBinder;
import android.os.RemoteException;
import android.util.Log;

/**
 * 广播接收器 - 用于外部触发 Binder 测试
 * 
 * 通过 ADB 触发测试:
 * adb shell am broadcast -a com.experiment.bindertest.TEST_BINDER \
 *     -n com.experiment.bindertest/.BinderTestReceiver
 */
public class BinderTestReceiver extends BroadcastReceiver {

    private static final String TAG = "BinderTestReceiver";
    private static final String ACTION_TEST_BINDER = "com.experiment.bindertest.TEST_BINDER";

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent.getAction();
        
        Log.i(TAG, "收到广播: " + action);
        
        if (ACTION_TEST_BINDER.equals(action)) {
            performBinderTest(context);
        } else if (Intent.ACTION_BOOT_COMPLETED.equals(action)) {
            Log.i(TAG, "系统启动完成，执行 Binder 测试");
            performBinderTest(context);
        }
    }

    private void performBinderTest(Context context) {
        Log.i(TAG, "========== 开始 Binder 测试 ==========");
        
        int successCount = 0;
        int failCount = 0;

        // 测试 1: ActivityManager
        try {
            ActivityManager am = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
            if (am != null) {
                am.getMemoryClass();
                am.getRunningAppProcesses();
                Log.i(TAG, "✓ ActivityManager 测试通过");
                successCount++;
            } else {
                throw new Exception("ActivityManager 为 null");
            }
        } catch (Exception e) {
            failCount++;
            logBinderError("ActivityManager", e);
        }

        // 测试 2: PackageManager
        try {
            PackageManager pm = context.getPackageManager();
            if (pm != null) {
                pm.getPackageInfo(context.getPackageName(), 0);
                pm.getInstalledPackages(0);
                Log.i(TAG, "✓ PackageManager 测试通过");
                successCount++;
            } else {
                throw new Exception("PackageManager 为 null");
            }
        } catch (Exception e) {
            failCount++;
            logBinderError("PackageManager", e);
        }

        // 测试 3: ServiceManager (反射)
        try {
            testServiceManager();
            Log.i(TAG, "✓ ServiceManager 测试通过");
            successCount++;
        } catch (Exception e) {
            failCount++;
            logBinderError("ServiceManager", e);
        }

        // 测试 4: 内容提供者
        try {
            context.getContentResolver().getType(
                android.provider.Settings.System.CONTENT_URI
            );
            Log.i(TAG, "✓ ContentResolver 测试通过");
            successCount++;
        } catch (Exception e) {
            failCount++;
            logBinderError("ContentResolver", e);
        }

        Log.i(TAG, "========== 测试完成 ==========");
        Log.i(TAG, "结果: 成功=" + successCount + ", 失败=" + failCount);
        
        if (failCount > 0) {
            Log.e(TAG, "!!! 检测到 Binder 故障 !!!");
        }
    }

    private void testServiceManager() throws Exception {
        Class<?> serviceManager = Class.forName("android.os.ServiceManager");
        java.lang.reflect.Method getService = serviceManager.getMethod("getService", String.class);
        
        // 测试 activity 服务
        IBinder activityBinder = (IBinder) getService.invoke(null, "activity");
        if (activityBinder == null) {
            throw new Exception("activity service Binder is null");
        }
        if (!activityBinder.isBinderAlive()) {
            throw new DeadObjectException("activity service Binder is dead");
        }
        
        // 测试 package 服务
        IBinder packageBinder = (IBinder) getService.invoke(null, "package");
        if (packageBinder == null) {
            throw new Exception("package service Binder is null");
        }
        if (!packageBinder.isBinderAlive()) {
            throw new DeadObjectException("package service Binder is dead");
        }
        
        // 测试 window 服务
        IBinder windowBinder = (IBinder) getService.invoke(null, "window");
        if (windowBinder == null) {
            throw new Exception("window service Binder is null");
        }
        if (!windowBinder.isBinderAlive()) {
            throw new DeadObjectException("window service Binder is dead");
        }
    }

    private void logBinderError(String serviceName, Exception e) {
        if (e instanceof DeadObjectException) {
            Log.e(TAG, "✗✗✗ " + serviceName + ": DeadObjectException - BINDER 句柄失效!");
        } else if (e.getCause() instanceof DeadObjectException) {
            Log.e(TAG, "✗✗✗ " + serviceName + ": 底层 DeadObjectException - BINDER 句柄失效!");
        } else if (e instanceof RemoteException) {
            Log.e(TAG, "✗ " + serviceName + ": RemoteException - " + e.getMessage());
        } else {
            Log.e(TAG, "✗ " + serviceName + ": " + e.getClass().getSimpleName() + " - " + e.getMessage());
        }
    }
}
