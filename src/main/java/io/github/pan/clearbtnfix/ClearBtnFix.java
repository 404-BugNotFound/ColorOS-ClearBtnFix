package io.github.pan.clearbtnfix;

import android.util.Log;
import android.view.View;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Map;
import java.util.WeakHashMap;

import io.github.libxposed.api.XposedModule;

/**
 * ColorOS 15 系统桌面（15.4.28）在第三方桌面作为默认桌面时，多任务走 FallbackRecentsView。
 * RecentsLayoutManager.layoutClearButton() 开头会在
 *   clearAllButton.alpha == 1 && measuredHeight != 0 && 动画开启 && TARGET_STATE != OVERVIEW
 * 时直接 return。Fallback 流程从不把 TARGET_STATE 设为 OVERVIEW，导致从横屏回来后
 * 旋转到竖屏时清除按钮仍保留横屏的宽度和 translationX。
 * 这里在 RecentsView 尺寸变化（横竖屏切换）时临时把 TARGET_STATE 设为 OVERVIEW，让布局完整执行一次。
 */
public class ClearBtnFix extends XposedModule {
    private static final String TAG = "ClearBtnFix";

    private final Map<Object, Long> lastSize = new WeakHashMap<>();

    @Override
    public void onModuleLoaded(ModuleLoadedParam param) {
        Log.i(TAG, "module loaded in " + param.getProcessName() + ", framework " + getFrameworkName() + " API " + getApiVersion());
    }

    @Override
    public void onPackageReady(PackageReadyParam param) {
        Log.i(TAG, "onPackageReady " + param.getPackageName() + " first=" + param.isFirstPackage());
        if (!param.isFirstPackage()) return;
        String pkg = param.getPackageName();
        if (!"com.android.launcher".equals(pkg) && !"com.oppo.launcher".equals(pkg)) return;

        try {
            ClassLoader cl = param.getClassLoader();
            Class<?> layoutManager = cl.loadClass("com.oplus.quickstep.utils.RecentsLayoutManager");
            Class<?> recentsViewImpl = cl.loadClass("com.android.quickstep.views.OplusRecentsViewImpl");
            Class<?> fallbackView = cl.loadClass("com.android.quickstep.fallback.FallbackRecentsView");
            Class<?> baseState = cl.loadClass("com.android.launcher3.states.OPlusBaseState");
            Class<?> launcherState = cl.loadClass("com.android.launcher3.LauncherState");

            Method layoutClearButton = layoutManager.getDeclaredMethod("layoutClearButton", recentsViewImpl);
            Field targetState = baseState.getDeclaredField("TARGET_STATE");
            targetState.setAccessible(true);
            Object overview = launcherState.getField("OVERVIEW").get(null);

            hook(layoutClearButton).intercept(chain -> {
                Object rv = chain.getArg(0);
                if (!fallbackView.isInstance(rv)) return chain.proceed();

                // Fallback 多任务是 Activity 真实旋转，OrientationHandler 的 rotation 恒为 0，
                // 所以用 RecentsView 的实际尺寸判断是否发生了横竖屏切换。
                View view = (View) rv;
                int w = view.getWidth();
                int h = view.getHeight();
                if (w == 0 || h == 0) return chain.proceed();
                long size = ((long) w << 32) | (h & 0xffffffffL);

                Long last;
                synchronized (lastSize) {
                    last = lastSize.get(rv);
                }
                if (last != null && last == size) return chain.proceed();

                Object old = targetState.get(null);
                boolean forced = old != overview;
                if (forced) targetState.set(null, overview);
                try {
                    chain.proceed();
                } finally {
                    if (forced) targetState.set(null, old);
                }
                synchronized (lastSize) {
                    lastSize.put(rv, size);
                }
                String from = last == null ? "null" : (last >>> 32) + "x" + (int) (long) last;
                Log.i(TAG, "relayout clear button: size " + from + " -> " + w + "x" + h + (forced ? " (forced)" : ""));
                return null;
            });
            log(Log.INFO, TAG, "hooked layoutClearButton in " + pkg);
            Log.i(TAG, "hooked layoutClearButton in " + pkg);
        } catch (Throwable t) {
            log(Log.ERROR, TAG, "hook failed, launcher version may be unsupported", t);
            Log.e(TAG, "hook failed", t);
        }
    }
}
