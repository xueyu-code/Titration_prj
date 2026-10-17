# 滴定仪项目开发指南（Flutter App + ESP-IDF 固件）

适用环境：Ubuntu 24.04 · bash · 由 `my_env.sh` 部署的 Flutter 3.47.7 / Android SDK / JDK 17
整理日期：2026-10-16

## 0. 先看这个：命令的验证程度

文档里每条命令都按下面的标记区分验证程度，没有标记的是纯说明文字。

| 标记 | 含义 |
|---|---|
| ✅ | 在你这台机器上实际运行通过 |
| 🧪 | 在临时环境里实际运行通过：ESP-IDF 装在一个独立的临时目录（不碰你的 `~/.espressif`），工程也建在临时目录 |
| 📖 | 确认命令和选项确实存在（Flutter / adb / sdkmanager 用本机的 `--help`，ESP-IDF 用 v5.3 源码和官方文档），但没有真正运行（需要开发板、手机或交互终端，或会改动你的环境） |
| ⚠️ | 没有验证，使用前请自己确认 |

标了“🧪 无板子”的命令，是指没接开发板时参数能被正确解析，并在访问串口那一步按预期报错；真正烧录没有验证。

验证细节和没验证到的地方见文末的附录 A。

## 1. 你现在的状态

| 项目 | 状态 |
|---|---|
| Flutter 3.47.7（`~/development/flutter`） | ✅ 新开终端可直接用 |
| Android SDK（platform 36 和 37.0，build-tools 36.0.0，platform-tools，NDK 28.2.13676358；旧脚本留下的 platform 35 和 build-tools 35.0.0 现在已经不在了，不是我卸的，见第 7 节末尾） | ✅ 已装；platform 36 曾按你的要求卸载，后来加 WiFi 相关库，构建时 Gradle 又自动装回来了，见 4.4 |
| JDK 17 | ✅ 已装 |
| `flutter doctor` | 只剩 channel、Chrome、`eglinfo` 三类无关紧要的告警 |
| ESP-IDF | ❌ 未安装（`~/esp` 不存在） |
| Flutter 工程 / 固件工程 | ❌ 都还没创建 |
| 串口权限 | ❌ 你不在 `dialout` 组，烧录会 `Permission denied` |
| `brltty` | ⚠️ 已安装；如果你的板子用 CH340 / CP210x 串口芯片，它会抢占 `/dev/ttyUSB0` |
| Android 编译（Gradle） | 🧪 我用新建的临时工程（4.1 的 9 个业务包）编出了 debug APK；**新建工程要先改 `compileSdk`**（见 4.4，新版 `my_env.sh --create-project` 会自动改）；release 包、真机安装和运行没验证 |
| 我对你环境做过的改动 | `~/Android/Sdk` 里：多了 `platforms/android-37.0`、符号链接 `platforms/android-37`、`ndk/28.2.13676358`；**按你的要求卸载了 `platforms/android-36`**（释放 147 MB），但后来验证 WiFi 相关库的构建时，Gradle 又把它自动装回来了（原因见 4.4）。`~/.gradle` 约 4 GB（Gradle 发行包和依赖缓存）；`~/.pub-cache` 多了几个包。没动你的 `~/.bashrc`，也没在你的目录下建任何工程 |

## 2. 推荐的下一步顺序

1. 做 [第 3 节](#3-一次性系统准备)：加入 `dialout` 组（必做）。
2. 做 [第 4 节](#4-flutter-工程)：创建 Flutter 工程，先用 Linux 桌面端跑通。
3. 做 [第 5 节](#5-esp-idf)：安装 ESP-IDF，建固件工程，烧一个 `hello_world`。
4. 在 Android 真机上跑一次 Flutter（4.3、4.4）。
5. 约定 App 和固件之间的通信协议（[第 6 节](#6-目录结构与通信协议)），再开始写业务代码。

## 3. 一次性系统准备

### 3.1 串口权限（必做）

```bash
sudo usermod -aG dialout $USER     # 把自己加进 dialout 组
```

要注销再登录才对所有终端生效。想在当前这一个终端马上生效，可以用：

```bash
newgrp dialout
```

用 `id -nG` 检查输出里有没有 `dialout`。

### 3.2 brltty（只有用 CH340 / CP210x 串口芯片时才需要）

```bash
sudo apt remove brltty
```

现象：板子插上后 `/dev/ttyUSB0` 出现一下又消失。ESP32-S3 的原生 USB 口（`/dev/ttyACM0`）不受它影响。

### 3.3 手机的 udev 权限（`adb devices` 显示 `no permissions` 时）

`my_env.sh` 只写了 Google（`18d1`）和树莓派（`2e8a`）两个厂商 ID。别的手机要补一行：

```bash
lsusb                      # 找到手机那一行，ID 后面冒号前的 4 位就是 idVendor
```

把下面的 `XXXX` 换成你查到的值：

```bash
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="XXXX", MODE="0666", GROUP="plugdev"' | sudo tee -a /etc/udev/rules.d/51-android.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
```

然后拔插手机。你已经在 `plugdev` 组里。

## 4. Flutter 工程

### 4.1 创建工程

下面的目录结构见第 6 节：App 放 `~/projects/titrator/app`。

```bash
mkdir -p ~/projects/titrator && cd ~/projects/titrator
flutter create --org com.lab --project-name titrator_app --platforms=android,linux app
cd app
flutter pub add flutter_reactive_ble flutter_riverpod permission_handler mqtt_client \
                web_socket_channel http network_info_plus connectivity_plus nsd
flutter pub add --dev flutter_lints
```

- 上面 9 个业务包是 `my_env.sh --create-project` 默认会加的那一组（变量 `FLUTTER_PACKAGES`，见第 7 节）：

  | 用途 | 包 |
  |---|---|
  | BLE | `flutter_reactive_ble` |
  | 状态管理、运行时权限 | `flutter_riverpod`、`permission_handler` |
  | WiFi：和 ESP32 的 HTTP / WebSocket 服务通信 | `http`、`web_socket_channel` |
  | WiFi：读当前网络、监听连接状态 | `network_info_plus`、`connectivity_plus` |
  | WiFi：mDNS 发现设备 | `nsd` |
  | 经 MQTT broker 通信 | `mqtt_client` |

  这 9 个包 + `flutter_lints` 我在新建的临时工程里解析成功、编出了 debug APK（约 157 MB）。✅ 只验证了能编译，**没有**和真实的 ESP32 联调过。
- 编译时会提示 `nsd_android` 用了 Kotlin Gradle Plugin：“Future versions of Flutter will fail to build if your app uses plugins that apply KGP”。现在只是警告；以后升级 Flutter 可能变成错误。不需要 mDNS 就别加 `nsd`（`FLUTTER_PACKAGES` 里去掉它）。✅ 警告是实际看到的，“以后会变成错误”是警告原文的说法。
- 国内镜像 `pub.flutter-io.cn` 在我验证时对 `win32` 和 `ffi_leak_tracker` 的压缩包返回 HTTP 525（镜像自身的问题，重试 5 次都一样，同一时间 `pub.dev` 正常）。所以脚本在 `pub add` 失败后会自动改用 `https://pub.dev` 重试一次；手动操作时可以这样：`PUB_HOSTED_URL=https://pub.dev flutter pub get`。✅ 镜像是否一直如此我不知道，你那边可能是好的。
- `--platforms=android,linux`：只生成 Android 和 Linux 两个平台目录。需要别的平台时，在工程目录里运行 `flutter create --platforms=ios .`（⚠️ 未验证）。

### 4.2 运行和检查

```bash
flutter analyze            # 静态检查 ✅
flutter test               # 跑 test/ 下的测试 ✅
flutter run -d linux       # 用 Linux 桌面窗口调界面 📖
```

`flutter_reactive_ble` 的 README 只有 Android 和 iOS 的说明，**Linux 桌面上没有 BLE**。Linux 窗口只能用来调界面，BLE 必须上 Android 真机。

**编 Android 之前先做 4.4 的三处改动**，否则 `flutter run` / `flutter build apk` 会失败。

`flutter run` 运行后，终端里按键：`r` 热重载，`R` 热重启，`q` 退出，`h` 看全部按键。📖

### 4.3 Android 真机

1. 手机：设置 → 关于手机，连点“版本号”打开开发者选项 → 打开“USB 调试”。
2. 用数据线连电脑，手机上点“允许 USB 调试”。
3. 检查：

```bash
adb devices -l             # ✅ 应该看到设备状态是 device
flutter devices            # ✅
flutter run -d <设备id>    # 📖
```

`adb devices` 的状态含义：`device` 正常；`unauthorized` 要在手机上点允许；`no permissions` 见 3.3；列表为空多半是线只能充电、或手机 USB 模式不对。

BLE 在 Android 12 及以上需要在 `android/app/src/main/AndroidManifest.xml` 的 `<manifest>` 里声明权限。这段来自 `flutter_reactive_ble 5.6.0` 的 README：

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" android:maxSdkVersion="30" />
```

代码里还要用 `permission_handler` 在运行时请求这些权限。

走 WiFi 还要在同一个 `AndroidManifest.xml` 里补这些（`my_env.sh` **不会**自动写）：

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />
<!-- 读当前 WiFi 的 SSID 需要定位权限；Android 13+ 扫描 / 连接附近设备用 NEARBY_WIFI_DEVICES -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" android:usesPermissionFlags="neverForLocation" />
```

- **`INTERNET` 必须加**：新建工程的 `src/main/AndroidManifest.xml` 里没有它，只有 `src/debug` 和 `src/profile` 里有（我看了模板）。所以 debug 下联网正常，装 release 包就连不上。✅
- ESP32 上的服务一般是 `http://` / `ws://`，Android 默认拦截明文流量，需要在 `<application>` 标签上加 `android:usesCleartextTraffic="true"`。📖 这是 Android 的行为，我没在真机上试过。
- 其余几条权限的具体要求（哪个 Android 版本需要哪条）我没有逐个核对，写代码时以各个包 README 为准。⚠️

### 4.4 首次编译 Android：为什么用 SDK 37，以及要改什么

**必须装 37 吗？** 对按 4.1 装的这组依赖，是的：`permission_handler_android 14.1.0` 和 `reactive_ble_mobile 5.6.0`（`flutter_reactive_ble 5.6.0` 的 Android 实现）自己的 `compileSdk` 就是 37，Android Gradle 插件要求依赖它们的 App 也用 37 编译，否则 `:app:checkDebugAarMetadata` 报错。这不是 Android 通用要求，而是这两个包当前版本的要求；如果把它们固定在更老的版本，可能用 36 也行，但我没有试过。⚠️

**36 还需要吗？** 看你装哪些包。只用 BLE / MQTT 那 4 个包时不需要：我卸载 `platforms/android-36` 后重新编过，成功，也没有被装回来。🧪 但加了 `connectivity_plus`、`network_info_plus`、`nsd` 之后需要：这三个包的 `compileSdk` 写的是 `flutter.compileSdkVersion`（Flutter 3.47.7 里是 36），而 App 本身改成了 37，所以 Gradle 要同时有 36 和 37。我编这 9 个包时，Gradle 发现缺 36，在构建中途自己下载安装了 `platforms/android-36`（这也是那次构建慢的原因之一）。🧪 因此新版 `my_env.sh` 默认两个都装，避免第一次构建时临时去下载。 但 **`build-tools 36.0.0` 不能卸**：它是另一个东西（构建工具，不是平台），AGP 9.1.0 的默认 build-tools 版本就是 `36.0.0`（我从 AGP 的 jar 里看到的），`flutter doctor` 显示的 “Android SDK version 36.0.0” 也是它。卸了只会让 Gradle 下次再下载一遍。

`my_env.sh` 已经改成默认装 `android-36` 和 `android-37.0`（见第 7 节）。在这之前，我在临时工程里直接编 `flutter build apk --debug` 会失败，做完下面三处改动才成功，产物 `build/app/outputs/flutter-apk/app-debug.apk`（约 151 MB）。🧪

先说明是怎么回事：Flutter 3.47.7 模板默认 `compileSdk` 是 36，但上面两个包要求 **Android SDK 37**。

**改动 1：Gradle 发行包换国内镜像。** Gradle 官方地址（`services.gradle.org`）会 307 跳转到 `github.com/gradle/gradle-distributions/…`，GitHub 慢或不通时会下载超时。如果你那里下载正常，可以跳过这一步。

```bash
cd ~/projects/titrator/app
sed -i 's#https\\://services.gradle.org/distributions/#https\\://mirrors.cloud.tencent.com/gradle/#' \
    android/gradle/wrapper/gradle-wrapper.properties
grep distributionUrl android/gradle/wrapper/gradle-wrapper.properties
```

这条 `sed` 只换域名，版本号（现在是 `gradle-9.3.1-all.zip`）保持文件里原来的。腾讯云镜像上有这个文件，下载并解压成功。

**改动 2：让 App 用 SDK 37 编译。** 每个新建的 Flutter 工程都要做（`./my_env.sh --create-project` 建的工程脚本已经替你做了；手动 `flutter create` 的要自己做）。在工程目录里：

```bash
sed -i 's/compileSdk = flutter.compileSdkVersion/compileSdk = 37/' android/app/build.gradle.kts
echo 'android.suppressUnsupportedCompileSdk=37' >> android/gradle.properties
```

第二行是因为 Flutter 模板里的 Android Gradle 插件（9.1.0）报错信息里写着“最高推荐的 compile SDK 是 36”，这行用来告诉它 37 是有意为之。我没有单独测过去掉这一行是否也能编过。

**改动 3：SDK 37 的目录名。** Gradle 首次编译时会自动下载 SDK 37 和 NDK，但新版 SDK 37 被装到了 `platforms/android-37.0`，而 Gradle 要找的是 `android-37`，报 `Failed to find target with hash string 'android-37'`。加一个符号链接：

```bash
ln -s android-37.0 ~/Android/Sdk/platforms/android-37
```

**这台机器上这一步已经做过了**（SDK 37、NDK `28.2.13676358` 和符号链接都已经在 `~/Android/Sdk` 里）。换一台机器时，新版 `my_env.sh` 在装完 `android-37.0` 后会自动建这个链接（`sdkmanager` 里 37 只有 `platforms;android-37.0` 这一个包名，没有 `android-37`）。

补充说明：

- 首次编译要下载并解压 Gradle、NDK、SDK 37 和 Maven 依赖，比较慢，是正常的。我这次磁盘上多出约 6 GB（`~/Android/Sdk` 增加约 2.3 GB，`~/.gradle` 约 4 GB）。
- 我的验证环境连不上 GitHub，且 Gradle 不走系统代理，所以我给 JVM 单独设了代理才下载成功；这和你的网络无关。Maven 依赖（`dl.google.com`、Maven Central）在我这里能正常下载；如果在你的网络下卡住，需要配 Maven 镜像，**这一步我没有验证出可用的配置**，遇到时把报错贴出来再处理。⚠️
- 以后插件升级后可能继续抬高 `compileSdk`，再遇到 `checkDebugAarMetadata` 报错时，同样是把 `compileSdk` 改到报错里要求的版本。
- `release` 包（`flutter build apk --release`）我没有编，R8 混淆等可能有新问题。⚠️

### 4.5 Flutter 常用命令

| 命令 | 作用 | 验证 |
|---|---|---|
| `flutter doctor` / `flutter doctor -v` | 环境检查（`-v` 看详情） | ✅ |
| `flutter doctor --android-licenses` | 接受 Android SDK 协议 | 📖 |
| `flutter devices` | 列出可运行的设备 | ✅ |
| `flutter emulators` | 列出模拟器（你没装，会是空） | 📖 |
| `flutter create --org com.lab --project-name x --platforms=android,linux 目录` | 新建工程 | ✅ |
| `flutter pub get` | 按 `pubspec.yaml` 拉依赖 | ✅ |
| `flutter pub add 包名…` / `flutter pub add --dev 包名` | 加依赖 / 加开发依赖 | ✅ |
| `flutter pub remove 包名` | 删依赖 | 📖 |
| `flutter pub upgrade` | 在版本约束内升级依赖 | 📖 |
| `flutter pub outdated`（在工程目录里） | 看哪些依赖有新版 | ✅ |
| `flutter analyze` | 静态分析 | ✅ |
| `flutter test` | 跑测试 | ✅ |
| `flutter run -d <设备id>` | 运行；`--release` / `--profile` 切换模式 | 📖 |
| `flutter build apk --debug` | 打 debug APK（先做 4.4 的改动） | 🧪 |
| `flutter build apk --release` | 打 release APK | ⚠️ 没编过，见 4.4 |
| `flutter build apk --release --split-per-abi` | 按 CPU 架构拆成多个更小的 APK | 📖 |
| `flutter build linux` | 打 Linux 桌面包 | ✅（之前冒烟测试通过） |
| `flutter install -d <设备id>` | 把已构建的 App 装到设备 | 📖 |
| `flutter logs` | 看已连接设备的日志 | 📖 |
| `flutter clean` | 清构建缓存（构建出怪问题时先试它） | 📖 |

**不要用 `flutter upgrade`**：你的 SDK 是固定到 `3.47.7` 标签的浅克隆，`flutter doctor` 显示它不在标准分支上。升级 Flutter 请用脚本：

```bash
FLUTTER_VERSION=<新版本号> FORCE_VERSION=1 ./my_env.sh
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

脚本默认版本是 `v5.3`。官方要求 Python 3.8 或更新；我在临时目录里用你的 Python 3.12.3 完整跑通了 v5.3 的安装（`install.sh esp32s3`）和 `hello_world` 编译。🧪

磁盘占用（我的测试值）：源码含子模块约 600 MB，`~/.espressif`（工具链、Python 环境和下载缓存）约 2.2 GB。

### 5.1 安装

**1. 前置依赖。** 这些你已经都有了（`git`、`cmake`、`ninja`、`python3-venv` ✅）。下面是官方文档里的完整清单，供换机器时参考：

```bash
sudo apt-get install git wget flex bison gperf python3 python3-pip python3-venv cmake ninja-build ccache libffi-dev libssl-dev dfu-util libusb-1.0-0
```

**2. 下载源码。** 官方地址在 GitHub（命令来自乐鑫文档，我的环境连不上 GitHub，没有实际运行 📖）：

```bash
mkdir -p ~/esp && cd ~/esp
git clone -b v5.3 --recursive --depth 1 --shallow-submodules https://github.com/espressif/esp-idf.git
```

GitHub 慢或连不上时，改用极狐 GitLab 上乐鑫的镜像。ESP-IDF 的 29 个子模块写的是相对地址，在这个镜像上能正确解析；但**其中 `components/cmock/CMock` 自己的嵌套子模块写死了 `github.com`**（只用于单元测试，编译你的工程用不到），所以不能直接用 `--recursive`，要分步做：

```bash
git clone -b v5.3 --depth 1 https://jihulab.com/esp-mirror/espressif/esp-idf.git
cd esp-idf
git submodule update --init --depth 1                                       # 29 个子模块，走镜像
git submodule update --init --depth 1 --recursive -- components/mbedtls/mbedtls   # 这个子模块自带嵌套子模块，也走镜像
```

这样会跳过 CMock 的嵌套子模块。🧪 如果你的 GitHub 能直连，直接用上一条官方命令即可。

**不要用 Gitee 镜像（`gitee.com/EspressifSystems/esp-idf`）**：它的主仓库能克隆，但子模块（例如 `esp32-wifi-lib`）在 Gitee 上无法匿名访问，子模块拉不下来。

**3. 安装工具链。** 国内先设下载镜像：

```bash
export IDF_GITHUB_ASSETS="dl.espressif.cn/github_assets"
cd ~/esp/esp-idf
./install.sh esp32s3
```

工具链和 Python 虚拟环境会装到 `~/.espressif`。`IDF_GITHUB_ASSETS` 的作用见乐鑫文档：把安装时本来要从 `github.com` 下载的文件改走这个服务器。我的测试环境里 `github.com` 完全连不上，设了它之后 `install.sh esp32s3` 约 2 分钟装完、退出码 0。🧪

**4. 加一个别名。** ESP-IDF 官方的用法是每次要用时在当前终端里 `source export.sh`，所以给它起个短别名：

```bash
cat >> ~/.bashrc <<'EOF'
alias get_idf='. $HOME/esp/esp-idf/export.sh'
EOF
source ~/.bashrc
```

这行在 `my_env.sh` 的标记块**外面**，所以以后 `./my_env.sh --uninstall` 不会帮你删它，需要的话自己删。

> 为什么不用 `./my_env.sh --with-esp-idf`：它把 `install.sh` 的输出全部丢掉，失败时你只能看到一句笼统的警告；它配的 direnv 也只在 `~/esp/esp-idf` 目录里自动生效，在你自己的固件目录里不生效。

### 5.2 创建固件工程

每个新终端，用 ESP-IDF 之前先运行一次 `get_idf`：

```bash
get_idf
echo $IDF_PATH             # 应该显示 /home/xueyu/esp/esp-idf
idf.py --version
```

方式 A（推荐）：从官方 `hello_world` 示例复制，能一次验证整条烧录链路。

```bash
cd ~/projects/titrator
cp -r $IDF_PATH/examples/get-started/hello_world firmware
cd firmware
idf.py set-target esp32s3
idf.py build
```

方式 B：用 `idf.py` 建一个空骨架。

```bash
cd ~/projects/titrator
idf.py create-project firmware
```

它会在当前目录下新建 `firmware/`，里面是 `CMakeLists.txt` 和 `main/firmware.c`（文件名跟着工程名走）。🧪

`hello_world` 通了之后，和 App 的 `flutter_reactive_ble` 对接的 BLE 外设示例在 `$IDF_PATH/examples/bluetooth/nimble/bleprph`，可以拷过来改。

### 5.3 烧录和看串口

先插上板子，确认串口名：

```bash
ls /dev/ttyACM* /dev/ttyUSB*
```

- ESP32-S3 的**原生 USB 口**通常是 `/dev/ttyACM0`；
- **串口桥芯片那个口**（CH340 / CP210x）是 `/dev/ttyUSB0`。

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

建议把固件和 App 放在同一个仓库里：

```
~/projects/titrator/
├── app/            Flutter 工程（4.1 创建）
├── firmware/       ESP-IDF 工程（5.2 创建）
└── docs/
    └── protocol.md BLE / MQTT 通信约定
```

```bash
cd ~/projects/titrator && git init
```

在写业务代码之前，先把 `docs/protocol.md` 写出来。App 用到了 `flutter_reactive_ble`、`web_socket_channel` / `http` 和 `mqtt_client`，至少要定下：

- BLE：GATT 服务 UUID、每个特征的 UUID 和读写 / 通知属性、数据包的字节格式、协议版本号；
- WiFi：ESP32 是开热点还是连路由器、HTTP 接口路径、WebSocket 消息格式、mDNS 服务名；
- MQTT：topic 命名、消息载荷格式；
- 错误码和超时规则。

固件和 App 都按这份文档实现，改协议时先改文档。

## 7. `my_env.sh` 速查

| 命令 | 作用 |
|---|---|
| `./my_env.sh --dry-run` | 只预览，不执行 |
| `./my_env.sh` | 标准安装（幂等，可重跑） |
| `./my_env.sh --with-esp-idf` | 顺便装 ESP-IDF（不推荐，见 5.1） |
| `./my_env.sh --create-project` | 创建 `~/projects/titrator_app`（目录和本文的 `~/projects/titrator/app` 不同），加上 4.1 的 9 个包，并自动把 `compileSdk` 改成 37。`pub add` 失败时会改用 `pub.dev` 重试一次 |
| `ANDROID_PLATFORMS="android-36 android-37.0" ./my_env.sh` | 改要装的 SDK 平台。默认值就是这个；`COMPILE_SDK=37` 同理，要和平台里的最高版本对应 |
| `FLUTTER_PACKAGES="flutter_reactive_ble http" ./my_env.sh --create-project` | 改 `--create-project` 时 `flutter pub add` 的包。默认是 4.1 里那 9 个；`FLUTTER_DEV_PACKAGES` 同理，默认 `flutter_lints` |
| `./my_env.sh --uninstall --dry-run` | 预览卸载会删什么（**卸载前务必先跑这条**） |
| `./my_env.sh --uninstall` | 交互式卸载 |
| `./my_env.sh --help` | 全部选项 |

**脚本里和 SDK 37 有关的改动**（相对旧版）：默认装 `android-36` 和 `android-37.0`（37 给 `permission_handler`、`reactive_ble`，36 给 `connectivity_plus`、`network_info_plus`、`nsd`，见 4.4）；装完后给 `android-37.0` 建 `platforms/android-37` 符号链接（已存在则跳过，目录没装成功则不建）；`--create-project` 建好工程后改 `android/app/build.gradle.kts` 的 `compileSdk` 并在 `android/gradle.properties` 加 `android.suppressUnsupportedCompileSdk=37`。`build-tools` 默认只装 `36.0.0`（AGP 9.1.0 的默认值，见 4.4）；`android-35` 和 `build-tools 35.0.0` 已从默认值里去掉。脚本**没有**自动换 Gradle 镜像，那一步（4.4 改动 1）仍需手动。

`android-35` 和 `build-tools 35.0.0` 是旧版脚本默认值留下的，没有任何依赖要求它们，所以新版脚本不再安装。我检查时它们已经不在 `~/Android/Sdk` 里了（不是我卸的）。我后来用 9 个业务包编 debug APK 时，SDK 里只有 `android-36`（Gradle 自动装的）、`android-37` / `android-37.0` 和 `build-tools 36.0.0`，编成功了，所以“没有 35 也能编”这一点验证过。🧪

## 8. 常见问题

| 现象 | 原因和处理 |
|---|---|
| 新终端里 `flutter: command not found` | 先 `source ~/.bashrc`；再检查 `~/.bashrc` 里有没有 `# >>> flutter-titrator-env >>>` 这一块。非交互的 shell（cron、`ssh host 'cmd'`）不会读到它 |
| `idf.py: command not found` | 这个终端还没运行 `get_idf` |
| 烧录时 `Permission denied: '/dev/ttyACM0'` | 没加入 `dialout` 组，或加了但没重新登录，见 3.1 |
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
| 首次 `flutter build apk` 中途打印 `Installing Android SDK Platform 36` | Gradle 在自动补装缺的平台。用新版 `my_env.sh` 的话 36 已经装好，不会再出现 |

---

## 附录 A：验证记录

### A.1 怎么验证的

**Flutter / adb / sdkmanager**：在你这台机器上，用你已装好的工具链。

- `flutter create`、`pub add`（4 个业务包 + `flutter_lints`）、`pub get`、`pub outdated`、`analyze`、`test`、`devices` 在一个临时工程里实际运行，全部成功。
- `flutter build apk --debug` 在同一个临时工程里：先失败两次（Gradle 下载超时；SDK 37 目录名），按 4.4 的三处改动处理后成功，产出 151 MB 的 `app-debug.apk`。
- 卸载 platform 36 之后（此时依赖只有 4 个业务包）：新建一个临时工程，用从 `my_env.sh` 里原样抽出来的 `patch_compile_sdk` 函数改 `compileSdk`，再编 debug APK，成功（151 MB）。此时 `~/Android/Sdk/platforms` 里只有 `android-35`、`android-37`、`android-37.0`，编完后也没有 36 被装回来；`flutter doctor` 的 Android toolchain 一项仍是 ✓（`Platform android-37, build-tools 36.0.0`）。
- 加 WiFi 相关库之后（9 个业务包 + `flutter_lints`）：新建临时工程，包列表直接从 `my_env.sh` 里抽出来用，`compileSdk` 用 `patch_compile_sdk` 改成 37。结果：
  - 第一次 `pub add` 失败，原因是镜像对个别包返回 525；改 `PUB_HOSTED_URL=https://pub.dev` 后 `pub get` 成功（73 个依赖有变化）。
  - `flutter build apk --debug` 成功，产物 `app-debug.apk` 约 157 MB，耗时约 9 分半。构建中途 Gradle 自动装回了 `platforms/android-36`，原因是三个新包的 `compileSdk` 是 36，见 4.4。
  - 这次构建**把 `platforms/android-36` 装回了你的 `~/Android/Sdk`**（约 147 MB），不是我手动装的，是 Gradle 做的。
  - 这次构建时 SDK 里已经没有 `android-35` 和 `build-tools 35.0.0`，所以顺带验证了没有它们也能编。
  - 没有测的：release 包、真机安装运行、和 ESP32 的实际通信。
- `my_env.sh` 的改动：`bash -n` 通过；在假 `HOME` 里 `--dry-run --create-project --skip-system-upgrade` 退出码 0，预览里有 `sdkmanager --install platforms;android-37.0`、`ln -s android-37.0 …/platforms/android-37` 和 `compileSdk = 37`；`patch_compile_sdk` 在真实的 `flutter create` 模板上测了 5 种情况（首次、重复执行、`gradle.properties` 末尾无换行、无法识别的 build 文件、工程目录不存在），符号链接循环测了 5 种情况（新建、重复、目录缺失、dry-run、非 `.0` 平台），全部符合预期。**没有**在真机/真实 `HOME` 里完整跑一遍部署（sdkmanager 真装 37 没跑）。`pub add` 的 pub.dev 兜底用假的 `flutter` 命令测了 4 种情况（镜像成功、镜像失败 pub.dev 成功、两者都失败、本来就用 pub.dev 且失败时不重试），全部符合预期；真实的镜像故障是我在构建时遇到的。
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
| `FLUTTER_VERSION=… FORCE_VERSION=1 ./my_env.sh` | 只在沙箱假目录里测过，没在你的真实 SDK 上跑 |
| `flutter create --platforms=ios .` | 没跑 |
| Arch / CachyOS / Manjaro | 只有 Ubuntu 机器；本文的命令都是 Ubuntu 的 |

### A.3 验证环境和你的网络可能不同

我的验证环境里 `github.com` 连不上，Gradle 也不走系统代理，所以文中几处镜像用法是照着“GitHub 不通”验证的：Gradle 用腾讯云镜像、ESP-IDF 工具用 `IDF_GITHUB_ASSETS`、ESP-IDF 源码用极狐镜像。如果你那里 GitHub 直连快，这些镜像都不是必须的；但 4.4 的改动 2 和 3（SDK 37）与网络无关，一定要做。
