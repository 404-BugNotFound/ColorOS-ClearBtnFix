# ColorOS-ClearBtnFix

修复 **ColorOS 15** 在使用**第三方桌面**（Square Home、Nova、Lawnchair、Niagara 等）时，从**横屏应用返回桌面后，第一次打开多任务界面「全部清除」按钮错位**的问题。

这是一个 LSPosed 模块，基于 [libxposed API](https://github.com/libxposed/api)（API 101 / 102）。

---

## 问题现象

1. 默认桌面设置为第三方桌面；
2. 打开一个横屏应用（游戏、视频全屏等）；
3. 返回桌面，打开多任务界面；
4. 底部「全部清除」按钮宽度和位置不对（偏到一侧 / 尺寸异常）；
5. 再回一次桌面重新打开多任务，又恢复正常。

使用 ColorOS 自带桌面时不会出现。

## 原因分析

> 基于对系统桌面 `com.android.launcher`（OplusLauncher，版本 **15.4.28**）的反编译分析。

### 1. 第三方桌面下多任务由系统桌面的 Fallback 界面提供

Android 10 起，多任务（Recents）由系统桌面内置的 Quickstep 提供。默认桌面不是系统桌面时，系统桌面会改用 `com.android.quickstep.RecentsActivity` + `com.android.quickstep.fallback.FallbackRecentsView` 来显示多任务。

和系统桌面自己的多任务不同，这个 Fallback 界面**是跟随屏幕真实旋转的**：从横屏应用返回时，它先按横屏布局，然后再旋转回竖屏重新布局。

### 2. ColorOS 的清除按钮布局函数里有一个提前返回

ColorOS 的「全部清除」面板是自定义控件 `com.oplus.quickstep.views.OplusClearAllPanelView`，它的位置由 `com.oplus.quickstep.utils.RecentsLayoutManager.layoutClearButton(OplusRecentsViewImpl)` 计算，`FallbackRecentsView.onLayout()` 每次布局都会调用它。

这个函数开头有一段判断（反编译后的代码）：

```java
if (clearAllButton.getAlpha() == 1.0f
        && measuredHeight != 0
        && ValueAnimator.areAnimatorsEnabled()
        && !Intrinsics.areEqual(OPlusBaseState.getTargetLauncherState(), LauncherState.OVERVIEW)) {
    LogUtils.i(TAG, "clearView layout return");
    return;   // 不再重新计算按钮位置
}
```

它的本意是：按钮已经完全显示、且桌面不是正在进入多任务状态时，不要在动画过程中挪动按钮。

问题在于 `OPlusBaseState.TARGET_STATE` 只会在**系统桌面自己的状态机**切换时被设置。Fallback 多任务流程从来不会把它设为 `OVERVIEW`，所以在第三方桌面下，只要按钮已经显示（alpha == 1），这个判断就始终成立。

### 3. 于是横屏时算出的布局残留到了竖屏

`layoutClearButton` 会按方向分别处理：

| 方向 | 处理 |
| --- | --- |
| 竖屏（rotation 0 / 2） | `layoutParams.width = MATCH_PARENT`，`setTranslationX(0)` |
| 横屏（rotation 1 / 3） | `layoutParams.width = 屏幕高度`，`setTranslationX(...)` 偏移到一侧 |

从横屏应用返回时：

1. Fallback 多任务先以横屏尺寸布局，按钮按横屏规则设置了宽度和 `translationX`；
2. 进场动画结束，按钮 alpha 变为 1；
3. 界面旋转回竖屏，再次调用 `layoutClearButton`，命中上面的提前返回，**竖屏的宽度和偏移没有被恢复**，按钮因此错位；
4. 下次再打开多任务时，进场动画从 alpha 0 开始，不满足提前返回条件，按钮又被正确布局——这就是"第二次打开就正常"的原因。

## 修复方式

模块 Hook `RecentsLayoutManager.layoutClearButton()`：

- 只处理 `FallbackRecentsView`（即第三方桌面的多任务），系统桌面自己的多任务完全不受影响；
- 记录每次布局时多任务视图的宽高；
- **当宽高变化（发生了横竖屏切换）时**，在调用原方法前临时把 `OPlusBaseState.TARGET_STATE` 设为 `LauncherState.OVERVIEW`，绕过提前返回，让原有的布局逻辑完整执行一次；调用结束后立即恢复原值；
- 宽高没有变化时直接调用原方法，不改变任何行为，不影响进出场动画。

> 为什么用宽高而不是 rotation：Fallback 多任务是 Activity 真实旋转，`getPagedOrientationHandler().getRotation()` 始终为 0，无法反映横竖屏变化。

模块不修改任何布局计算本身，只是让 ColorOS 自己的竖屏布局逻辑在该执行的时候执行。

## 适用环境

| 项目 | 要求 |
| --- | --- |
| 系统 | ColorOS 15（Android 15）。已测试：系统桌面 15.4.28 |
| Root | Magisk / KernelSU / APatch 任一 |
| 框架 | LSPosed，需支持 libxposed **API 101 及以上** |
| 作用域 | 系统桌面 `com.android.launcher` |

其他 ColorOS / realme UI / OxygenOS 版本未测试。模块依赖系统桌面的私有类和字段，桌面更新后可能失效（失效时只会记录日志，不会导致桌面崩溃）。

## 安装

1. 从 [Releases](../../releases) 下载 `ClearBtnFix.apk` 并安装；
2. 在 LSPosed 中启用「多任务清除按钮修复」，确认作用域勾选了**系统桌面**（模块已声明静态作用域，一般会自动勾选）；
3. 重启手机（或执行 `adb shell am force-stop com.android.launcher` 重启系统桌面）。

## 验证 / 排查

模块会输出 `ClearBtnFix` 标签的日志：

```bat
adb logcat -c
:: 复现：横屏应用 → 返回桌面 → 打开多任务
adb logcat -d | findstr /i "ClearBtnFix"
```

| 日志 | 含义 |
| --- | --- |
| `module loaded in com.android.launcher ...` | 模块已注入系统桌面 |
| `hooked layoutClearButton in com.android.launcher` | Hook 成功 |
| `relayout clear button: size 2412x1080 -> 1080x2412 (forced)` | 检测到横竖屏切换并已强制重新布局（修复生效） |
| `hook failed ...` | 当前系统桌面版本的类名 / 字段已变化，需要重新适配 |

如果出现 `hook failed`，或 Hook 成功但问题仍在，欢迎提 Issue，并附上：

- 系统桌面版本（设置 → 应用管理 → 显示系统应用 → 系统桌面）；
- 上面的日志输出；
- 如方便，导出系统桌面 APK：
  ```bat
  adb shell pm path com.android.launcher
  adb pull /system_ext/priv-app/OplusLauncher/OplusLauncher.apk
  ```

## 从源码编译

项目不使用 Gradle，直接用 Android SDK 命令行工具编译，依赖：

- JDK 17+（已用 Temurin 21 测试）
- Android SDK：`platforms;android-35`、`build-tools;35.0.0`

编译脚本 `build.ps1` 中的路径（`$sdk`、`$jdk`）按需修改，然后运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
```

脚本会：

1. 从 Maven Central 下载 `io.github.libxposed:api:102.0.0` 并校验 SHA-256（仅编译期依赖，不打包进 APK）；
2. `javac` → `d8` → `aapt2` 打包，加入 `META-INF/xposed/*`；
3. `zipalign` 后用 `debug.keystore` 签名（不存在时自动生成）。

产物位于 `build/ClearBtnFix.apk`。

> 注意：自己编译的 APK 签名与 Release 中的不同，覆盖安装前需要先卸载旧版。

## 项目结构

```
├── build.ps1                                   # 编译脚本
└── src/main
    ├── AndroidManifest.xml
    ├── java/io/github/pan/clearbtnfix
    │   └── ClearBtnFix.java                    # 模块入口与 Hook 逻辑
    ├── res/values/strings.xml                  # 模块名称与描述
    └── resources/META-INF/xposed
        ├── java_init.list                      # 入口类
        ├── module.prop                         # minApiVersion=101, targetApiVersion=102
        └── scope.list                          # 作用域：com.android.launcher
```

## 免责声明

本模块修改系统桌面的运行时行为，使用前请确保有可用的救砖手段（如 LSPosed 安全模式、Magisk 模块禁用）。作者不对使用本模块造成的任何问题负责。

## License

[Apache License 2.0](LICENSE)
