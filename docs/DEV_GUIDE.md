# 滴定仪项目开发指南（Flutter App + ESP-IDF 固件）

适用环境：Ubuntu 24.04 · bash · 由 `tools/env_config.sh` 部署的 Flutter 3.47.7 / Android SDK / JDK 17 · ESP-IDF v5.5.5
整理日期：2026-10-17

## 0. 先看这个：命令的验证程度

文档里每条命令都按下面的标记区分验证程度，没有标记的是纯说明文字。

| 标记 | 含义 |
|---|---|
| ✅ | 在你这台机器上实际运行通过 |
| 🧪 | 在临时环境里实际运行通过：ESP-IDF 装在一个独立的临时目录（不碰你的 `~/.espressif`），工程也建在临时目录 |
| 📖 | 确认命令和选项确实存在（Flutter / adb / sdkmanager 用本机的 `--help`，ESP-IDF 用 v5.3 源码和官方文档），但没有真正运行（需要开发板、手机或交互终端，或会改动你的环境） |
| ⚠️ | 没有验证，使用前请自己确认 |

标了“🧪 无板子”的命令，是指没接开发板时参数能被正确解析，并在访问串口那一步按预期报错；真正烧录没有验证。

**版本说明**：本文的验证是 2026-10-16 做的，当时 ESP-IDF 用的是 v5.3。项目现在用 v5.5.5，所以 5.4、5.5 两节的 `idf.py` 命令表里的 🧪 / 📖 都是 v5.3 上的结果，没有在 v5.5.5 上逐条重跑。第 5 节里因为改成 v5.5.5 而变动的命令一律标 📖。

验证细节和没验证到的地方见文末的附录 A。

## 1. 需要的工具和版本

| 项目 | 要求 | 验证 |
|---|---|---|
| 系统 | Ubuntu 24.04（`tools/env_config.sh` 也支持 Ubuntu 22.04 和 Arch 系，见根目录 `README.md`） | ✅ 本机是 Ubuntu 24.04 |
| Flutter | 3.47.7，装在 `~/development/flutter` | ✅ `flutter --version` 显示 3.47.7 |
| Android SDK | 装在 `~/Android/Sdk`：platform 36 和 37.0、build-tools 36.0.0、platform-tools；App 的 `compileSdk` 是 37；NDK 由 Gradle 首次编译时自动下载。SDK 37 的目录叫 `platforms/android-37.0`，还要有一个符号链接 `platforms/android-37`。原因见 4.4 | ✅ 这些目录都在 |
| JDK | 17 | ✅ `java -version` 显示 17 |
| ESP-IDF | v5.5.5，装在 `~/esp/esp-idf-v5.5.5`，工具链在 `~/.espressif`。`firmware/README.md`、`firmware/DESIGN.md` 和主机测试的 `firmware/test/host/CMakeLists.txt` 都用这个路径 | ✅ `~/esp/esp-idf-v5.5.5/export.sh` 存在 |
| 串口权限 | 用户必须在串口组里（Ubuntu 是 `dialout`，Arch 系是 `uucp`），否则烧录报 `Permission denied`，见 3.1 | 用 `id -nG` 自己检查 |
| `brltty` | 如果板子用 CH340 / CP210x 串口芯片，它会抢占 `/dev/ttyUSB0`，要卸掉，见 3.2 | ⚠️ 没有用 CH340 / CP210x 的板子验证过 |

`tools/env_config.sh` 可以一次装好 Flutter、Android SDK、JDK（ESP-IDF 要自己装，见第 5 节），用法见第 7 节。`flutter doctor` 里 channel、Chrome、`eglinfo` 三类告警无害，见第 8 节。

## 2. 新同事上手顺序

1. 做 [第 3 节](#3-一次性系统准备)：系统准备。加入串口组（Ubuntu 是 `dialout`，Arch 系是 `uucp`）是必做的，手机的 udev 权限和 `brltty` 按需处理。
2. 做 [第 4 节](#4-flutter-工程)：装好 Flutter 环境（`tools/env_config.sh` 或手动，见第 1、7 节），在 `app/` 下拉依赖、`flutter analyze`、`flutter test`，再用 `flutter run -t lib/main_sim.dart` 在手机上跑无硬件的模拟器版本（4.3 讲真机连接）。
3. 做 [第 5 节](#5-esp-idf)：安装 ESP-IDF v5.5.5，编译 `firmware/`，跑主机测试；有开发板再烧录。
4. 读 `docs/protocol.md`（App 和固件之间的 BLE 协议）和根目录的 `README.md`（目录结构、该看哪份文档、协作约定），再开始改代码。

## 3. 一次性系统准备

### 3.1 串口权限（必做）

串口设备归哪个组管，各发行版不一样：

| 发行版 | 串口组 |
|---|---|
| Ubuntu / Debian | `dialout` |
| Arch / CachyOS / Manjaro | `uucp`（没有 `dialout` 组，照 Ubuntu 的命令加会报组不存在） |

拿不准时，插上板子看设备文件属于哪个组，第四列就是：

```bash
ls -l /dev/ttyACM0 /dev/ttyUSB0    # 例如 crw-rw---- 1 root uucp ...
```

把自己加进对应的组：

```bash
sudo usermod -aG dialout $USER     # Ubuntu / Debian
sudo usermod -aG uucp $USER        # Arch / CachyOS / Manjaro
```

要注销再登录才对所有终端生效。想在当前这一个终端马上生效，可以用 `newgrp dialout` 或 `newgrp uucp`。

用 `id -nG` 检查输出里有没有这个组。

### 3.2 brltty（只有用 CH340 / CP210x 串口芯片时才需要）

```bash
sudo apt remove brltty             # Ubuntu / Debian
sudo pacman -Rns brltty            # Arch / CachyOS / Manjaro（装了才需要）
```

现象：板子插上后 `/dev/ttyUSB0` 出现一下又消失。ESP32-S3 的原生 USB 口（`/dev/ttyACM0`）不受它影响。

### 3.3 手机的 udev 权限（`adb devices` 显示 `no permissions` 时）

`tools/env_config.sh` 只写了 Google（`18d1`）和树莓派（`2e8a`）两个厂商 ID。别的手机要补一行：

```bash
lsusb                      # 找到手机那一行，ID 后面冒号前的 4 位就是 idVendor
```

把下面的 `XXXX` 换成你查到的值：

```bash
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="XXXX", MODE="0666", GROUP="plugdev"' | sudo tee -a /etc/udev/rules.d/51-android.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
```

然后拔插手机。`tools/env_config.sh` 写 udev 规则时会把你加进 `plugdev` 组（要注销再登录才生效）。

## 4. Flutter 工程

### 4.1 拉取依赖

Flutter 工程已经在仓库的 `app/` 里，不需要再 `flutter create`。第一次使用或 `pubspec.yaml` 变了之后：

```bash
cd app
flutter pub get           # ✅ 同时生成 lib/l10n/app_localizations*.dart（git 忽略的生成文件）
```

依赖都写在 `app/pubspec.yaml` 里。App 只用 BLE 通信，不用 Wi-Fi、HTTP、MQTT。

国内镜像 `pub.flutter-io.cn` 在 2026-10-16 验证时对 `win32` 和 `ffi_leak_tracker` 的压缩包返回 HTTP 525（镜像自身的问题，重试 5 次都一样，同一时间 `pub.dev` 正常）。遇到 `525 trying to find package …` 时，临时改用官方源：

```bash
PUB_HOSTED_URL=https://pub.dev flutter pub get
```

✅ 这个故障是当时实际遇到的；镜像是否一直如此我不知道，你那边可能是好的。

### 4.2 运行和检查

```bash
flutter analyze                    # 静态检查 ✅
flutter test                       # 跑 test/ 下的测试 ✅
flutter run -t lib/main_sim.dart   # 在连着的手机上跑无硬件的模拟器版本 📖
```

`app/` 里只有 `android/` 平台目录，没有 Linux 桌面端；而且 `flutter_reactive_ble` 的 README 只有 Android 和 iOS 的说明，Linux 桌面上没有 BLE。界面和逻辑靠 `flutter test` 和手机上的模拟器版本调试，BLE 联调必须上 Android 真机。模拟器版本的说明见 `app/README.md`。

编 Android 要满足 4.4 的三个条件（SDK 37、`compileSdk`、`android-37` 符号链接），否则 `flutter run` / `flutter build apk` 会失败。本仓库的 `app/` 已经带了其中两项，装 SDK 的机器上要有第三项，见 4.4。

`flutter run` 运行后，终端里按键：`r` 热重载，`R` 热重启，`q` 退出，`h` 看全部按键。📖

### 4.3 Android 真机

1. 手机：设置 → 关于手机，连点“版本号” 7 次打开开发者选项；在开发者选项里打开“USB 调试”。部分小米、OPPO、vivo 手机还要打开“USB 安装”。
2. USB 连接模式选“文件传输”，不要选“仅充电”。
3. 用数据线连电脑。如果开发环境在 VMware 虚拟机里，还要把手机接到虚拟机：VMware 菜单“虚拟机 → 可移动设备 → 找到你的手机 → 连接（断开与主机的连接）”，也可以在 VMware 底部状态栏的 USB 图标上右键，选“连接”。⚠️ 这一步没有验证，菜单名称随 VMware 版本可能不同。
4. 手机上弹出“允许 USB 调试吗？”，点允许（建议勾选“始终允许”）。
5. 检查：

```bash
adb devices -l             # ✅ 应该看到设备状态是 device
flutter devices            # ✅
```

`adb devices` 的状态含义：`device` 正常；`unauthorized` 要在手机上点允许；`no permissions` 是手机厂商不在 udev 规则里，按 3.3 补一行规则并拔插手机；列表为空多半是线只能充电、USB 模式不对，或（虚拟机里）手机还没连到虚拟机。

连好之后，在 `app/` 目录下运行或安装：

```bash
cd app
flutter run -d <设备id>                                          # 📖 调试运行，支持热重载（r）
adb install -r build/app/outputs/flutter-apk/app-release.apk    # 📖 安装已编好的 release 包（先 flutter build apk --release --obfuscate --split-debug-info=build/symbols）
```

装到手机上用 release 包：debug 包约 200 MB，release 包约 8 MB（原生库压缩存放，装机后占用比 APK 大几 MB；混淆符号的用法见 `app/README.md`）。

BLE 需要的权限已经声明在 `app/android/app/src/main/AndroidManifest.xml` 里：Android 12 及以上的 `BLUETOOTH_SCAN`（`neverForLocation`）和 `BLUETOOTH_CONNECT`，Android 11 及以下的 `BLUETOOTH`、`BLUETOOTH_ADMIN` 和定位权限，以及通知和前台服务权限。BLE 权限的写法参照 `flutter_reactive_ble` 的 README；运行时由 `permission_handler` 请求。这个 App 不走 Wi-Fi，所以 manifest 里没有网络相关的权限。

### 4.4 首次编译 Android：为什么用 SDK 37，以及要改什么

**必须装 37 吗？** 对 `app/pubspec.yaml` 现在这组依赖，是的：`pubspec.lock` 里的 `permission_handler_android 14.1.0` 和 `reactive_ble_mobile 5.6.0`（`flutter_reactive_ble 5.6.0` 的 Android 实现）自己的 `compileSdk` 就是 37，Android Gradle 插件要求依赖它们的 App 也用 37 编译，否则 `:app:checkDebugAarMetadata` 报错。这不是 Android 通用要求，而是这两个包当前版本的要求；如果把它们固定在更老的版本，可能用 36 也行，但我没有试过。⚠️

**36 还需要吗？** 对 `app/` 现在这组依赖，需要。📖 `pubspec.lock` 里的 `flutter_local_notifications 22.3.2` 的 `android/build.gradle` 写的是 `compileSdk 36`（在本机 pub 缓存里读到的源码），而 App 本身改成了 37，所以 Gradle 要同时有 36 和 37。⚠️ 我没有卸载 36 之后重编 `app/`，缺 36 时 Gradle 会怎样，是按下面的旧记录推断的。下面是 2026-10-16 在临时工程里的验证记录，当时的依赖和现在的 `app/` 不同：只用 BLE / MQTT 那 4 个包时不需要 36，我卸载 `platforms/android-36` 后重新编过，成功，也没有被装回来。🧪 但加了 `connectivity_plus`、`network_info_plus`、`nsd` 之后需要：这三个包的 `compileSdk` 写的是 `flutter.compileSdkVersion`（Flutter 3.47.7 里是 36），而 App 本身改成了 37，所以 Gradle 要同时有 36 和 37。（这三个包来自最初的脚手架，本 App 不使用它们；这一段是 2026-10-16 在临时工程里的验证记录。）我在临时工程里编带这三个包的那组 9 个业务包时，Gradle 发现缺 36，在构建中途自己下载安装了 `platforms/android-36`（这也是那次构建慢的原因之一）。🧪 因此新版 `tools/env_config.sh` 默认两个都装，避免第一次构建时临时去下载。 但 **`build-tools 36.0.0` 不能卸**：它是另一个东西（构建工具，不是平台），AGP 9.1.0 的默认 build-tools 版本就是 `36.0.0`（我从 AGP 的 jar 里看到的），`flutter doctor` 显示的 “Android SDK version 36.0.0” 也是它。卸了只会让 Gradle 下次再下载一遍。

`tools/env_config.sh` 已经改成默认装 `android-36` 和 `android-37.0`（见第 7 节）。在这之前，我在临时工程里直接编 `flutter build apk --debug` 会失败，做完下面三处改动才成功，产物 `build/app/outputs/flutter-apk/app-debug.apk`（约 151 MB）。🧪

先说明是怎么回事：Flutter 3.47.7 模板默认 `compileSdk` 是 36，但上面两个包要求 **Android SDK 37**。下面三处改动里，本仓库的 `app/` 已经做了改动 1 和 2，改动 3 是装 SDK 的机器上的事。

**改动 1：Gradle 发行包换国内镜像。** Gradle 官方地址（`services.gradle.org`）会 307 跳转到 `github.com/gradle/gradle-distributions/…`，GitHub 慢或不通时会下载超时。如果你那里下载正常，可以跳过这一步。本仓库的 `app/android/gradle/wrapper/gradle-wrapper.properties` 已经指向腾讯云镜像，不用再做；下面的命令用于新建的 Flutter 工程。

```bash
cd app          # 换成你的工程目录
sed -i 's#https\\://services.gradle.org/distributions/#https\\://mirrors.cloud.tencent.com/gradle/#' \
    android/gradle/wrapper/gradle-wrapper.properties
grep distributionUrl android/gradle/wrapper/gradle-wrapper.properties
```

这条 `sed` 只换域名，版本号（现在是 `gradle-9.3.1-all.zip`）保持文件里原来的。腾讯云镜像上有这个文件，下载并解压成功。

**改动 2：让 App 用 SDK 37 编译。** 本仓库的 `app/` 已经做过了（`android/app/build.gradle.kts` 里是 `compileSdk = 37`，`android/gradle.properties` 里有 `android.suppressUnsupportedCompileSdk=37`）。以后新建别的 Flutter 工程才需要再做（`tools/env_config.sh --create-project` 建的工程脚本会替你做）。在工程目录里：

```bash
sed -i 's/compileSdk = flutter.compileSdkVersion/compileSdk = 37/' android/app/build.gradle.kts
echo 'android.suppressUnsupportedCompileSdk=37' >> android/gradle.properties
```

第二行是因为 Flutter 模板里的 Android Gradle 插件（9.1.0）报错信息里写着“最高推荐的 compile SDK 是 36”，这行用来告诉它 37 是有意为之。我没有单独测过去掉这一行是否也能编过。

**改动 3：SDK 37 的目录名。** Gradle 首次编译时会自动下载 SDK 37 和 NDK，但新版 SDK 37 被装到了 `platforms/android-37.0`，而 Gradle 要找的是 `android-37`，报 `Failed to find target with hash string 'android-37'`。加一个符号链接：

```bash
ln -s android-37.0 ~/Android/Sdk/platforms/android-37
```

**这台机器上这一步已经做过了**（SDK 37、NDK `28.2.13676358` 和符号链接都已经在 `~/Android/Sdk` 里）。换一台机器时，新版 `tools/env_config.sh` 在装完 `android-37.0` 后会自动建这个链接（`sdkmanager` 里 37 只有 `platforms;android-37.0` 这一个包名，没有 `android-37`）。

补充说明：

- 首次编译要下载并解压 Gradle、NDK、SDK 37 和 Maven 依赖，比较慢，是正常的。我这次磁盘上多出约 6 GB（`~/Android/Sdk` 增加约 2.3 GB，`~/.gradle` 约 4 GB）。
- 我的验证环境连不上 GitHub，且 Gradle 不走系统代理，所以我给 JVM 单独设了代理才下载成功；这和你的网络无关。Maven 依赖（`dl.google.com`、Maven Central）在我这里能正常下载；如果在你的网络下卡住，需要配 Maven 镜像，**这一步我没有验证出可用的配置**，遇到时把报错贴出来再处理。⚠️
- 以后插件升级后可能继续抬高 `compileSdk`，再遇到 `checkDebugAarMetadata` 报错时，同样是把 `compileSdk` 改到报错里要求的版本。
- `release` 包（`flutter build apk --release`）在 2026-10-16 的临时工程里我没有编。本仓库的 `app/` 已经用 `flutter build apk --release --obfuscate --split-debug-info=build/symbols` 编出过 release APK（约 8 MB，`app/build/app/outputs/flutter-apk/app-release.apk`，✅ 本机编成，文件在本机存在），安装用它，见 `app/README.md`。

### 4.5 Flutter 常用命令

| 命令 | 作用 | 验证 |
|---|---|---|
| `flutter doctor` / `flutter doctor -v` | 环境检查（`-v` 看详情） | ✅ |
| `flutter doctor --android-licenses` | 接受 Android SDK 协议 | 📖 |
| `flutter devices` | 列出可运行的设备 | ✅ |
| `flutter emulators` | 列出模拟器（没装的话是空） | 📖 |
| `flutter create --org com.lab --project-name x --platforms=android,linux 目录` | 新建工程（本仓库已有工程，用不到） | ✅ |
| `flutter pub get` | 按 `pubspec.yaml` 拉依赖 | ✅ |
| `flutter pub add 包名…` / `flutter pub add --dev 包名` | 加依赖 / 加开发依赖 | ✅ |
| `flutter pub remove 包名` | 删依赖 | 📖 |
| `flutter pub upgrade` | 在版本约束内升级依赖 | 📖 |
| `flutter pub outdated`（在工程目录里） | 看哪些依赖有新版 | ✅ |
| `flutter analyze` | 静态分析 | ✅ |
| `flutter test` | 跑测试 | ✅ |
| `flutter run -d <设备id>` | 运行；`--release` / `--profile` 切换模式 | 📖 |
| `flutter run -t lib/main_sim.dart` | 运行无硬件的模拟器版本（见 `app/README.md`） | 📖 |
| `flutter build apk --debug` | 打 debug APK（先满足 4.4 的条件） | 🧪 |
| `flutter build apk --release --obfuscate --split-debug-info=build/symbols` | 打 release APK（混淆，符号文件存到 `build/symbols`），装到手机用这个 | ✅ 本仓库的 `app/` 编出过，见 4.4 |
| `flutter build apk --release --split-per-abi` | 按 CPU 架构拆成多个更小的 APK | 📖 |
| `flutter build linux` | 打 Linux 桌面包（本仓库的 `app/` 没有 linux 平台，用不到） | ✅（之前在临时工程冒烟测试通过） |
| `flutter install -d <设备id>` | 把已构建的 App 装到设备 | 📖 |
| `flutter logs` | 看已连接设备的日志 | 📖 |
| `flutter clean` | 清构建缓存（构建出怪问题时先试它） | 📖 |

**不要用 `flutter upgrade`**：你的 SDK 是固定到 `3.47.7` 标签的浅克隆，`flutter doctor` 显示它不在标准分支上。升级 Flutter 请用脚本：

```bash
FLUTTER_VERSION=<新版本号> FORCE_VERSION=1 ./tools/env_config.sh
```

⚠️ 这条的版本切换逻辑我在沙箱假目录里测过，没有在你真实的 SDK 上运行过。

### 4.6 Android 辅助工具

| 命令 | 作用 | 验证 |
|---|---|---|
| `adb devices -l` | 列设备（现在没接手机，列表为空） | ✅ |
| `adb install -r app-debug.apk` | 安装 / 覆盖安装 APK | 📖 |
| `adb uninstall 包名` | 卸载 App | 📖 |
| `adb logcat` | 看手机系统日志（可以接 `\| grep flutter` 过滤） | 📖 |
| `adb shell` | 进手机 shell | 📖 |
| `adb kill-server && adb start-server` | adb 抽风时重启服务 | ✅ |
| `sdkmanager --list_installed` | 看已装的 SDK 包 | ✅ |
| `sdkmanager --list` | 看所有可装的包（需要联网） | 📖 |
| `sdkmanager --install "platforms;android-37.0"` | 装某个 SDK 包（37 的包名带 `.0`） | 📖 包名在 `sdkmanager --list` 里确认存在；`--uninstall "platforms;android-36"` 在你机器上实际运行过 |
| `sdkmanager --update` | 更新全部已装包 | 📖 |
| `sdkmanager --licenses` | 接受协议 | 📖 |

`sdkmanager` 每次会打印一行 “sdkmanager is deprecated” 的警告，不影响使用。

## 5. ESP-IDF

本项目用 ESP-IDF **v5.5.5**，装在 `~/esp/esp-idf-v5.5.5`（`firmware/README.md`、`firmware/DESIGN.md` 和主机测试都用这个路径）。✅ 这台机器上 `~/esp/esp-idf-v5.5.5/export.sh` 存在，`~/.espressif` 里有对应的工具链和 Python 环境。固件在 v5.5.5 上的构建结果见 `firmware/README.md` 的 Status。

下面 5.1 的安装命令是按 v5.5.5 改的，没有重新运行，一律标 📖。2026-10-16 的验证是在 v5.3 上做的（见附录 A）：官方要求 Python 3.8 或更新，当时用 Python 3.12.3 完整跑通了 v5.3 的安装（`install.sh esp32s3`）和 `hello_world` 编译。🧪

磁盘占用（v5.3 的测试值）：源码含子模块约 600 MB，`~/.espressif`（工具链、Python 环境和下载缓存）约 2.2 GB。

### 5.1 安装

**1. 前置依赖。** 下面是官方文档里的完整清单（主机测试还需要 `cmake` 和 `ninja`）：

```bash
sudo apt-get install git wget flex bison gperf python3 python3-pip python3-venv cmake ninja-build ccache libffi-dev libssl-dev dfu-util libusb-1.0-0
```

**2. 下载源码。** 官方地址在 GitHub（命令来自乐鑫文档，我的环境连不上 GitHub，没有实际运行 📖）。目标目录名带版本号，和仓库文档里的路径一致：

```bash
mkdir -p ~/esp && cd ~/esp
git clone -b v5.5.5 --recursive --depth 1 --shallow-submodules https://github.com/espressif/esp-idf.git esp-idf-v5.5.5
```

GitHub 慢或连不上时，改用极狐 GitLab 上乐鑫的镜像。v5.3 时 ESP-IDF 的 29 个子模块写的是相对地址，在这个镜像上能正确解析；但**其中 `components/cmock/CMock` 自己的嵌套子模块写死了 `github.com`**（只用于单元测试，编译你的工程用不到），所以不能直接用 `--recursive`，要分步做：

```bash
git clone -b v5.5.5 --depth 1 https://jihulab.com/esp-mirror/espressif/esp-idf.git esp-idf-v5.5.5   # 📖
cd esp-idf-v5.5.5
git submodule update --init --depth 1                                       # 走镜像 📖
git submodule update --init --depth 1 --recursive -- components/mbedtls/mbedtls   # 这个子模块自带嵌套子模块，也走镜像 📖
```

这个分步序列是在 v5.3 上验证的（🧪），**v5.5.5 上没有重跑**：v5.5.5 的 `.gitmodules` 里有 23 个子模块，URL 都是相对地址（在本机已装的那份里看过），但 CMock 的嵌套子模块是否还写死 `github.com`、`mbedtls` 是否仍需单独 `--recursive`，没有重新核对。⚠️ 如果你的 GitHub 能直连，直接用上一条官方命令即可。

**不要用 Gitee 镜像（`gitee.com/EspressifSystems/esp-idf`）**：它的主仓库能克隆，但子模块（例如 `esp32-wifi-lib`）在 Gitee 上无法匿名访问，子模块拉不下来。（v5.3 时的结论，v5.5.5 上没有重新试。）

**3. 安装工具链。** 国内先设下载镜像：

```bash
export IDF_GITHUB_ASSETS="dl.espressif.cn/github_assets"
cd ~/esp/esp-idf-v5.5.5
./install.sh esp32s3                     # 📖
```

工具链和 Python 虚拟环境会装到 `~/.espressif`。`IDF_GITHUB_ASSETS` 的作用见乐鑫文档：把安装时本来要从 `github.com` 下载的文件改走这个服务器。我的测试环境里 `github.com` 完全连不上，设了它之后 v5.3 的 `install.sh esp32s3` 约 2 分钟装完、退出码 0。🧪

**4. 加一个别名。** ESP-IDF 官方的用法是每次要用时在当前终端里 `source export.sh`，所以给它起个短别名：

```bash
cat >> ~/.bashrc <<'EOF'
alias get_idf='. $HOME/esp/esp-idf-v5.5.5/export.sh'
EOF
source ~/.bashrc
```

📖 这行在 `tools/env_config.sh` 的标记块**外面**，所以以后 `./tools/env_config.sh --uninstall` 不会帮你删它，需要的话自己删。

> 为什么仍然建议手动装，而不是 `./tools/env_config.sh --with-esp-idf`：脚本现在默认装 v5.5.5，目录是 `~/esp/esp-idf-v5.5.5`，和本项目一致（📖 只跑过 `--dry-run`，预览里是 `git clone -b v5.5.5 … ~/esp/esp-idf-v5.5.5`，没有真正安装）。但它只从 GitHub 克隆，没有上面极狐镜像那一套，GitHub 慢或连不上时就会失败；它把 `install.sh` 的输出全部丢掉，失败时你只能看到一句笼统的警告；它还会装 direnv、往 rc 文件里加 hook，并在 ESP-IDF 目录里写一个 `.envrc`，这套 direnv 配置只在 ESP-IDF 目录里自动生效，在你自己的固件目录里不生效。你这台机器上的 `~/esp/esp-idf-v5.5.5` 是手动装的，不在脚本的 manifest 里，卸载时它和 `~/.espressif` 都只会作为 ASK 项出现，要你逐项确认，想保留就不要确认。

### 5.2 编译固件

固件工程已经在仓库的 `firmware/` 里，不需要再新建。每个新终端，用 ESP-IDF 之前先运行一次 `get_idf`：

```bash
get_idf
echo $IDF_PATH             # 应该显示 /home/<你的用户名>/esp/esp-idf-v5.5.5
idf.py --version           # 应该显示 v5.5.5
```

✅ 编译（目标芯片和选项来自 `firmware/sdkconfig.defaults`，不需要 `set-target`；本机 v5.5.5 上编译通过、无警告）：

```bash
cd firmware
idf.py build
```

改了 `sdkconfig.defaults` 之后，先删掉生成的 `firmware/sdkconfig` 再编译，否则新的默认值不会生效。

不需要开发板的主机测试（用 gcc 编译 `core`，在模拟烧杯上跑完整的滴定环）✅，在仓库根目录运行：

```bash
cmake -S firmware/test/host -B firmware/test/host/build -G Ninja
cmake --build firmware/test/host/build
ctest --test-dir firmware/test/host/build --output-on-failure
```

主机测试只需要 ESP-IDF 的源码（用它里面的 cJSON 和 Unity）：`IDF_PATH` 已设置（运行过 `get_idf`）就用它，没设置则默认 `~/esp/esp-idf-v5.5.5`。烧录和编辑器配置（`.clangd`）见 `firmware/README.md`。

### 5.3 烧录和看串口

先插上板子，确认串口名：

```bash
ls /dev/ttyACM* /dev/ttyUSB*
```

| 口 | 芯片（`lsusb` 里的 ID） | 设备名 |
|---|---|---|
| 板上 **UART** 口 | CH343（`1a86:55d3`），我们这块板就是 | `/dev/ttyACM*` |
| 板上 **UART** 口 | CP2102N（`10c4:ea60`）或 CH340（`1a86:7523`） | `/dev/ttyUSB*` |
| 板上 **USB** 口（ESP32-S3 原生 USB） | 乐鑫（`303a:xxxx`） | `/dev/ttyACM*` |

同一型号的开发板，不同批次用的串口芯片可能不一样，以 `lsusb` 为准。UART 口和原生 USB 口都可能是 `/dev/ttyACM*`，两个口同时插着时编号取决于插入顺序，这时用 `/dev/serial/by-id/` 下的名字区分：

```bash
ls -l /dev/serial/by-id/    # 例如 usb-1a86_USB_Single_Serial_5CF9073060-if00 -> ../../ttyACM0
```

推荐用 UART 口烧录：它能自动进下载模式，不用按 BOOT 键。原生 USB 口在板上的程序没开 USB-Serial-JTAG 时（例如出厂固件，`lsusb` 显示 `303a:4001`），要先手动进下载模式：按住 BOOT，按一下 RST，再松开 BOOT。仓库文档里的示例都用 `/dev/ttyACM0`（CH343 的 UART 口）；以你的板子实际出现的设备名为准。

```bash
idf.py -p /dev/ttyACM0 flash monitor
```

退出 monitor 按 `Ctrl+]`。5.5 节的快捷键只在交互终端里有效。

连不上（`Failed to connect`）时：按住板子上的 BOOT 键，按一下 RESET，再松开 BOOT，进入下载模式后重试。

### 5.4 idf.py 常用命令

| 命令 | 作用 | 验证 |
|---|---|---|
| `idf.py --version` | 看 ESP-IDF 版本 | 🧪 |
| `idf.py --help` / `idf.py <命令> --help` | 全部命令 / 某命令的选项 | 🧪 |
| `idf.py --list-targets` | 当前版本支持的芯片 | 🧪 |
| `idf.py set-target esp32s3` | 设定芯片。**会清空 build 目录并重新生成 sdkconfig**，旧的存为 `sdkconfig.old` | 🧪 |
| `idf.py menuconfig` | 图形化配置（蓝牙、分区、日志级别等） | 📖 |
| `idf.py build` | 编译（增量）。它在 `idf.py --help` 里是 `all` 的别名，所以不单独列出 | 🧪 |
| `idf.py -p /dev/ttyACM0 flash` | 编译（如需要）并烧录 | 🧪 无板子 |
| `idf.py -p /dev/ttyACM0 monitor` | 看串口输出（`Ctrl+]` 退出） | 🧪 无板子 |
| `idf.py -p /dev/ttyACM0 flash monitor` | 烧录后直接看串口，最常用 | 📖 |
| `idf.py -p /dev/ttyACM0 -b 460800 flash` | 指定烧录波特率 | 📖（`-b` 在 `app-flash` 上试过） |
| `idf.py -p /dev/ttyACM0 app-flash` | 只烧应用，不烧 bootloader 和分区表（更快） | 🧪 无板子 |
| `idf.py bootloader` / `idf.py partition-table` | 只编译 bootloader / 分区表 | 🧪 |
| `idf.py -p /dev/ttyACM0 partition-table-flash` | 只烧分区表（改了 `partitions.csv` 时用） | 📖 |
| `idf.py -p /dev/ttyACM0 erase-flash` | 擦除整块 flash | 🧪 无板子 |
| `idf.py clean` | 清编译产物（保留 CMake 配置） | 🧪 |
| `idf.py fullclean` | 清空整个 build 目录（`sdkconfig` 配置不丢） | 🧪 |
| `idf.py reconfigure` | 强制重跑 CMake（增删源文件后或改了 CMake 变量后） | 🧪 |
| `idf.py size` | 看固件占用的 RAM 和 Flash（hello_world 的应用约 207 KB，占 1 MB 分区的 20%） | 🧪 |
| `idf.py size-components` / `idf.py size-files` | 按组件 / 按源文件看占用 | 🧪 |
| `idf.py save-defconfig` | 把和默认值不同的配置存成精简的 `sdkconfig.defaults` | 🧪 |
| `idf.py merge-bin -o all.bin -f raw` | 把 bootloader、分区表、应用合成一个文件，方便给别人烧（要先 `build`） | 🧪 |
| `idf.py create-component -C components 名字` | 在 `components/` 下新建组件 | 🧪 |
| `idf.py add-dependency "espressif/led_strip^2.0.0"` | 给工程加组件管理器里的依赖（写入 `main/idf_component.yml`） | 🧪 |
| `idf.py update-dependencies` | 更新组件管理器依赖 | 📖 |
| `idf.py docs` | 在浏览器打开对应芯片和版本的文档 | 📖 |
| `idf.py -C <目录> build` | 不进入工程目录也能编译 | 📖 |
| `idf.py -B <目录> build` | 指定 build 目录 | 📖 |
| `idf.py -v build` | 详细编译输出，排查编译问题 | 📖 |
| `idf.py clean flash monitor` | 多个命令可以连着写，顺序由工具自动排好 | 📖 |

环境变量：

| 变量 | 作用 |
|---|---|
| `ESPPORT` / `ESPBAUD` | 分别是 `-p` 和 `-b` 的默认值，设了就不用每次写 `-p /dev/ttyACM0` |
| `IDF_TARGET` | 默认芯片，设成 `esp32s3` 也行 |
| `IDF_TOOLS_PATH` | 工具链安装位置，默认 `~/.espressif` |
| `IDF_GITHUB_ASSETS` | 国内加速，见 5.1 |

### 5.5 monitor 快捷键

先按 `Ctrl+T`，再按下面的键（`Ctrl+]` 例外，可单独按）：

| 按键 | 作用 |
|---|---|
| `Ctrl+]` | 退出 monitor |
| `Ctrl+T` 然后 `Ctrl+R` | 通过 RTS 复位板子 |
| `Ctrl+T` 然后 `Ctrl+F` | 重新编译并烧录整个工程，然后继续监视 |
| `Ctrl+T` 然后 `A` | 只重新编译并烧录应用 |
| `Ctrl+T` 然后 `Ctrl+Y` | 暂停 / 恢复屏幕输出 |
| `Ctrl+T` 然后 `H` | 显示全部快捷键 |
| `Ctrl+T` 然后 `X` | 退出 monitor |

## 6. 目录结构与通信协议

仓库的目录结构、各份文档分别看什么，见根目录的 [README.md](../README.md)。

App 和固件之间的通信约定只有一份：[protocol.md](protocol.md)（BLE：GATT 服务、命令和事件的 JSON 格式、错误码、行为约定）。改协议先改这份文档，再改两端的代码。滴定常量和 `sim_titrator.dart` 的同步规则见根目录 `README.md` 的“协作约定”。

## 7. `tools/env_config.sh` 速查

脚本在仓库的 `tools/` 下，在仓库根目录运行。它的功能、全部选项和卸载策略见根目录 `README.md`；这里只列常用命令。

| 命令 | 作用 |
|---|---|
| `./tools/env_config.sh --dry-run` | 只预览，不执行 |
| `./tools/env_config.sh` | 标准安装（幂等，可重跑） |
| `./tools/env_config.sh --with-esp-idf` | 顺便装 ESP-IDF v5.5.5 到 `~/esp/esp-idf-v5.5.5`（只从 GitHub 克隆，不显示 `install.sh` 输出，所以仍建议手动装，见 5.1；📖 只跑过 `--dry-run`） |
| `ANDROID_PLATFORMS="android-36 android-37.0" ./tools/env_config.sh` | 改要装的 SDK 平台。默认值就是这个；`COMPILE_SDK=37` 同理，要和平台里的最高版本对应 |
| `./tools/env_config.sh --uninstall --dry-run` | 预览卸载会删什么（**卸载前务必先跑这条**） |
| `./tools/env_config.sh --uninstall` | 交互式卸载 |
| `./tools/env_config.sh --help` | 全部选项 |

`--create-project` 会另建一个独立的 `~/projects/titrator_app` 工程，只含 Android 平台，依赖是 `app/` 现在用的那组（`FLUTTER_PACKAGES`、`FLUTTER_DEV_PACKAGES`、`FLUTTER_SDK_PACKAGES` 可以覆盖）；本仓库的 `app/` 已经存在，不需要这个选项。📖 只跑过 `--dry-run`，预览里有 `flutter create … --platforms=android` 和三条 `flutter pub add`（普通依赖、`--dev`、`--sdk=flutter`），没有真正建过工程。脚本里早期 Wi-Fi / MQTT 方案的那串包还留着，但已经注释掉，本项目没有采用。ESP-IDF 的版本和目录可以用 `ESP_IDF_VERSION`、`IDF_HOME` 覆盖，默认是 `v5.5.5` 和 `~/esp/esp-idf-$ESP_IDF_VERSION`。

**脚本里和 SDK 37 有关的改动**（相对旧版）：默认装 `android-36` 和 `android-37.0`（37 给 `permission_handler`、`reactive_ble`，36 给 `flutter_local_notifications`，见 4.4）；装完后给 `android-37.0` 建 `platforms/android-37` 符号链接（已存在则跳过，目录没装成功则不建）；`--create-project` 建好工程后改 `android/app/build.gradle.kts` 的 `compileSdk` 并在 `android/gradle.properties` 加 `android.suppressUnsupportedCompileSdk=37`。`build-tools` 默认只装 `36.0.0`（AGP 9.1.0 的默认值，见 4.4）；`android-35` 和 `build-tools 35.0.0` 已从默认值里去掉。脚本**没有**自动换 Gradle 镜像，那一步（4.4 改动 1）需要手动；本仓库的 `app/` 已经改好了。

`android-35` 和 `build-tools 35.0.0` 是旧版脚本默认值留下的，没有任何依赖要求它们，所以新版脚本不再安装。2026-10-16 我检查时它们已经不在 `~/Android/Sdk` 里了（不是我卸的）。我后来在临时工程里用 9 个业务包编 debug APK 时，SDK 里只有 `android-36`（Gradle 自动装的）、`android-37` / `android-37.0` 和 `build-tools 36.0.0`，编成功了，所以“没有 35 也能编”这一点验证过。🧪

## 8. 常见问题

| 现象 | 原因和处理 |
|---|---|
| 新终端里 `flutter: command not found` | 先 `source ~/.bashrc`；再检查 `~/.bashrc` 里有没有 `# >>> flutter-titrator-env >>>` 这一块。非交互的 shell（cron、`ssh host 'cmd'`）不会读到它 |
| `idf.py: command not found` | 这个终端还没运行 `get_idf` |
| 烧录时 `Permission denied: '/dev/ttyACM0'` | 没加入串口组（Ubuntu 是 `dialout`，Arch 系是 `uucp`），或加了但没重新登录，见 3.1 |
| `/dev/ttyUSB0` 一插就消失 | `brltty` 抢占，见 3.2 |
| `Failed to connect to ESP32-S3` | 串口名不对，或没进下载模式，见 5.3 |
| `adb devices` 显示 `unauthorized` | 手机上点“允许 USB 调试” |
| `adb devices` 显示 `no permissions` | 手机厂商不在 udev 规则里，见 3.3 |
| `flutter doctor` 报 channel 是 `[user-branch]`、remote 非标准 | 无害。想消除这条告警，在 `~/.bashrc` 里加 `export FLUTTER_GIT_URL=https://mirrors.tuna.tsinghua.edu.cn/git/flutter-sdk.git`（这是 `flutter doctor` 自己给出的提示） |
| `flutter doctor` 报 Chrome 找不到、`eglinfo` 不可用 | 无害（不做 Web 开发；`eglinfo` 需要 `sudo apt install mesa-utils`） |
| Android 编译卡在 Gradle 下载 | 见 4.4 改动 1 |
| `Failed to find target with hash string 'android-37'` | 见 4.4 改动 3（符号链接） |
| `checkDebugAarMetadata` 报某个依赖 `requires … compile against version 37` | 见 4.4 改动 2（`compileSdk`） |
| `sdkmanager` 打印 deprecated 警告 | 无害，照常使用 |
| `flutter pub get` / `pub add` 报 `525 trying to find package …` | 国内镜像 `pub.flutter-io.cn` 对该包的下载出错（镜像自身问题）。临时改用官方源：`PUB_HOSTED_URL=https://pub.dev flutter pub get`；过一阵再试镜像也行 |
| 首次 `flutter build apk` 中途打印 `Installing Android SDK Platform 36` | Gradle 在自动补装缺的平台。用新版 `tools/env_config.sh` 的话 36 已经装好，不会再出现 |

---

## 附录 A：验证记录

> 本附录记录的是 2026-10-16 的环境验证：当时 ESP-IDF 用的是 v5.3，Flutter 部分在一个临时工程里做（带 Wi-Fi / MQTT 等包，不是现在的 `app/`），脚本当时叫 `my_env.sh`（现在是 `tools/env_config.sh`，下文已改成现名）。保留作参考，命令、版本和结果没有随项目更新。

### A.1 怎么验证的

**Flutter / adb / sdkmanager**：在你这台机器上，用你已装好的工具链。

- `flutter create`、`pub add`（4 个业务包 + `flutter_lints`）、`pub get`、`pub outdated`、`analyze`、`test`、`devices` 在一个临时工程里实际运行，全部成功。
- `flutter build apk --debug` 在同一个临时工程里：先失败两次（Gradle 下载超时；SDK 37 目录名），按 4.4 的三处改动处理后成功，产出 151 MB 的 `app-debug.apk`。
- 卸载 platform 36 之后（此时依赖只有 4 个业务包）：新建一个临时工程，用从 `tools/env_config.sh` 里原样抽出来的 `patch_compile_sdk` 函数改 `compileSdk`，再编 debug APK，成功（151 MB）。此时 `~/Android/Sdk/platforms` 里只有 `android-35`、`android-37`、`android-37.0`，编完后也没有 36 被装回来；`flutter doctor` 的 Android toolchain 一项仍是 ✓（`Platform android-37, build-tools 36.0.0`）。
- 加 WiFi 相关库之后（9 个业务包 + `flutter_lints`）：新建临时工程，包列表直接从 `tools/env_config.sh` 里抽出来用，`compileSdk` 用 `patch_compile_sdk` 改成 37。结果：
  - 第一次 `pub add` 失败，原因是镜像对个别包返回 525；改 `PUB_HOSTED_URL=https://pub.dev` 后 `pub get` 成功（73 个依赖有变化）。
  - `flutter build apk --debug` 成功，产物 `app-debug.apk` 约 157 MB，耗时约 9 分半。构建中途 Gradle 自动装回了 `platforms/android-36`，原因是三个新包的 `compileSdk` 是 36，见 4.4。
  - 这次构建**把 `platforms/android-36` 装回了你的 `~/Android/Sdk`**（约 147 MB），不是我手动装的，是 Gradle 做的。
  - 这次构建时 SDK 里已经没有 `android-35` 和 `build-tools 35.0.0`，所以顺带验证了没有它们也能编。
  - 没有测的：release 包、真机安装运行、和 ESP32 的实际通信。
- `tools/env_config.sh` 的改动：`bash -n` 通过；在假 `HOME` 里 `--dry-run --create-project --skip-system-upgrade` 退出码 0，预览里有 `sdkmanager --install platforms;android-37.0`、`ln -s android-37.0 …/platforms/android-37` 和 `compileSdk = 37`；`patch_compile_sdk` 在真实的 `flutter create` 模板上测了 5 种情况（首次、重复执行、`gradle.properties` 末尾无换行、无法识别的 build 文件、工程目录不存在），符号链接循环测了 5 种情况（新建、重复、目录缺失、dry-run、非 `.0` 平台），全部符合预期。**没有**在真机/真实 `HOME` 里完整跑一遍部署（sdkmanager 真装 37 没跑）。`pub add` 的 pub.dev 兜底用假的 `flutter` 命令测了 4 种情况（镜像成功、镜像失败 pub.dev 成功、两者都失败、本来就用 pub.dev 且失败时不重试），全部符合预期；真实的镜像故障是我在构建时遇到的。
- 其余 Flutter 命令用 `flutter <命令> --help` 确认命令和选项存在（`create`、`pub add/get/remove/upgrade/outdated`、`run`、`build apk`、`analyze`、`test`、`install`、`logs`、`clean`、`devices`、`emulators`、`precache`、`config`；`run` 的 `--release/--debug/--profile`；`build apk` 的 `--split-per-abi`；`doctor` 的 `--android-licenses`）。
- `adb kill-server`、`adb start-server`、`adb devices -l`、`sdkmanager --list_installed` 实际运行；`adb install/uninstall/logcat/shell` 和 `sdkmanager --list/--install/--update/--licenses` 用 `--help` 确认存在。

**ESP-IDF**：你的机器上没装，所以在临时目录里装了一份 v5.3 做验证（验证完已删除，没碰你的 `~/.espressif`、`~/esp` 和 `~/.bashrc`）。

- 源码：从极狐镜像克隆 v5.3；`--recursive` 一次性克隆因为 CMock 的嵌套子模块指向 GitHub 而失败（原因见 5.1）。之后补跑 `git submodule update --init --depth 1`（29 个子模块全部成功）和对 `components/mbedtls/mbedtls` 的 `--recursive`（成功）。5.1 里的三步序列是照这个结果整理的，我没有从一个全新的目录再完整重跑一遍。
- `install.sh esp32s3`（设了 `IDF_GITHUB_ASSETS`）退出码 0，用时约 2 分钟。
- `source export.sh` 后：`idf.py --version`（显示 `ESP-IDF v5.3-dirty`，`dirty` 是因为验证时补拉过子模块）、`--help`、`--list-targets`（`esp32 esp32s2 esp32c3 esp32s3 esp32c2 esp32c6 esp32h2 esp32p4`）。
- 把 `hello_world` 复制成工程后：`set-target esp32s3`、`build`、`size`、`size-components`、`size-files`、`reconfigure`、`app`、`bootloader`、`partition-table`、`merge-bin`、`save-defconfig`、`-v clean`、`fullclean`、再 `build`，退出码全是 0。
- 没接板子的情况下，`-p /dev/ttyACM0 flash`、`app-flash`、`erase-flash`、`monitor` 都能被正确解析，并在打开串口那一步报错（`monitor` 报 `could not open port /dev/ttyACM0: No such file or directory`）。
- 另建临时工程：`create-project`、`create-component -C components`、`add-dependency` 退出码 0，生成的文件见 5.2 和 5.4。
- `idf.py --help` 里确认存在：`set-target menuconfig flash monitor app-flash bootloader partition-table partition-table-flash erase-flash clean fullclean reconfigure size size-components size-files save-defconfig merge-bin create-project create-component add-dependency update-dependencies docs app uf2 openocd gdb`，以及全局选项 `-C -B -v -p -b --ccache -G --no-hints`。

**参考的官方文档**（v5.3，ESP32-S3）：`api-guides/tools/idf-py.html`、`api-guides/tools/idf-monitor.html`、`api-guides/tools/idf-tools.html`、`get-started/linux-macos-setup.html`；组件管理器命令对照 `idf-component-manager` 3.1.2 的源码。

### A.2 没有验证到的

| 项目 | 原因 |
|---|---|
| 真正往开发板烧录、`monitor` 看到输出、BOOT/RESET 进下载模式 | 没有开发板 |
| `adb install`、`flutter run` 到真机、手机 USB 调试和 udev 规则 | 没有手机 |
| `flutter run -d linux` 的窗口和热重载按键 | 没有图形界面可看 |
| `flutter build apk --release`、`--split-per-abi` | 没编，只确认了选项存在 |
| `idf.py menuconfig`、`docs`、`openocd`、`gdb`、`update-dependencies`、`partition-table-flash` | 交互式、需要浏览器或调试器，只确认了命令存在 |
| 从 GitHub 克隆 ESP-IDF 的官方命令 | 我的环境连不上 GitHub |
| Maven 镜像配置 | 我的环境能直连，没遇到问题，所以没有可验证的配置 |
| `FLUTTER_VERSION=… FORCE_VERSION=1 ./tools/env_config.sh` | 只在沙箱假目录里测过，没在你的真实 SDK 上跑 |
| `flutter create --platforms=ios .` | 没跑 |
| Arch / CachyOS / Manjaro | 只有 Ubuntu 机器；本文的命令都是 Ubuntu 的 |

### A.3 验证环境和你的网络可能不同

我的验证环境里 `github.com` 连不上，Gradle 也不走系统代理，所以文中几处镜像用法是照着“GitHub 不通”验证的：Gradle 用腾讯云镜像、ESP-IDF 工具用 `IDF_GITHUB_ASSETS`、ESP-IDF 源码用极狐镜像。如果你那里 GitHub 直连快，这些镜像都不是必须的；但 4.4 的改动 2 和 3（SDK 37）与网络无关，一定要做。
