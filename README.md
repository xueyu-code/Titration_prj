# 滴定仪（Titrator）

面向高校小型实验室的 pH 自动滴定仪：ESP32-S3 固件驱动两个注射泵，读取 pH 模块，通过 BLE 与安卓 Flutter App 通信。用户在 App 里设目标 pH 并开始滴定，设备按目标 pH 自动加酸或加碱，App 看着曲线判断是否到达终点，到点后停止设备并通知用户。烧杯由用户手动搅拌。定位是小实验室的辅助工具，不做计量认证，功能保持克制。

硬件：

- 主控：ESP32-S3-DevKitC-1 N16R8（模组 ESP32-S3-WROOM-1-N16R8：16 MB quad flash，8 MB octal PSRAM）。
- 两个 42 步进电机，各配一块 TMC2209（STEP/DIR 模式），驱动注射泵。通道 1 加酸，通道 2 加碱；每个通道在排空端有一个限位开关；吸液和排液共用一根管。
- pH 模块 PH-4502C：Po 经 15k/10k 分压接 ESP32-S3 内部 ADC1。

## 目录结构

```
Titration_prj/
├── app/                     Flutter 安卓 App（只用 BLE）
│   ├── lib/
│   │   ├── core/            纯 Dart：协议编解码、完成判定、标定算法、数据模型
│   │   ├── data/            平台适配：BLE 连接、通知、前台服务
│   │   ├── state/           Riverpod 控制器：扫描、设备会话、标定、语言
│   │   ├── ui/              页面和组件
│   │   ├── l10n/            中英文 ARB 翻译（Dart 文件由 flutter pub get 生成）
│   │   └── sim/             无硬件模拟器，只被 main_sim.dart 引用
│   ├── test/                单元测试和 widget 测试
│   └── android/             Android 工程：BLE 权限、前台服务、compileSdk 37
├── firmware/                ESP-IDF 固件
│   ├── main/                装配：队列、任务、设备端口
│   ├── components/
│   │   ├── core/            纯 C，不依赖 ESP-IDF：协议、pH、电极异常、运动、滴定环、设备状态机
│   │   └── platform/        薄的 ESP-IDF 封装：stepper、ph_adc、ble_link、cal_store
│   ├── test/host/           主机单元测试和闭环烧杯仿真
│   ├── DESIGN.md            固件设计（中文）
│   ├── README.md            固件构建和测试
│   ├── sdkconfig.defaults   芯片、flash/PSRAM、NimBLE 等默认配置
│   ├── version.txt          固件版本号
│   └── .clangd              clangd 配置
├── docs/
│   ├── protocol.md          App 与固件之间的 BLE 协议（唯一契约）
│   ├── DEV_GUIDE.md         开发环境搭建指南
│   ├── info.md              最初的需求说明
│   ├── PH4502C.PNG          PH-4502C 模块引脚参考图
│   └── TMC2209.PNG          TMC2209 模块引脚参考图
└── tools/
    └── env_config.sh        开发环境部署和卸载脚本（见下文）
```

## 先看哪份文档

| 想做什么 | 看 |
|---|---|
| 改 App 与固件之间的消息、错误码、行为约定 | `docs/protocol.md`（契约，先改它再改两端） |
| 理解固件设计、引脚规划、待确认的硬件问题、上板验证项 | `firmware/DESIGN.md`（第 18 节待确认清单，第 19 节上板验证清单） |
| 编译、测试 App，用模拟器 | `app/README.md` |
| 打包 App 正式版发给别人 | 本文“打包正式版”一节 |
| 编译、烧录固件，跑主机测试 | `firmware/README.md` |
| 搭开发环境（Flutter、Android SDK、JDK、ESP-IDF、手机真机调试） | `docs/DEV_GUIDE.md` |
| 了解最初要什么功能 | `docs/info.md` |

## 快速开始

环境没搭好先看 `docs/DEV_GUIDE.md`。

App（在 `app/` 下）：

```bash
cd app
flutter pub get                  # 同时生成 lib/l10n/app_localizations*.dart
flutter analyze
flutter test
flutter build apk --release --obfuscate --split-debug-info=build/symbols   # 打包正式版，见下面“打包正式版”

# 没有硬件时用模拟器（需要连着安卓手机或模拟器）
flutter run -t lib/main_sim.dart
```

模拟器版本和正式版 application id 相同，会覆盖安装；细节见 `app/README.md`。

固件（ESP-IDF v5.5.5，装在 `~/esp/esp-idf-v5.5.5`）：

```bash
. ~/esp/esp-idf-v5.5.5/export.sh
cd firmware
idf.py build                              # 目标芯片和选项来自 sdkconfig.defaults
idf.py -p /dev/ttyUSB0 flash monitor      # 板上 UART 口；原生 USB 口是 /dev/ttyACM0
```

烧录需要用户在 `dialout` 组里，否则报 `Permission denied`。运行 `sudo usermod -aG dialout $USER` 之后要注销再登录才生效（只想让当前终端生效，用 `newgrp dialout`），再用 `id -nG` 确认输出里有 `dialout`，细节见 `docs/DEV_GUIDE.md` 3.1。主机测试不需要开发板（在仓库根目录运行）：

```bash
cmake -S firmware/test/host -B firmware/test/host/build -G Ninja
cmake --build firmware/test/host/build
ctest --test-dir firmware/test/host/build --output-on-failure
```

## 打包正式版

在 `app/` 下运行：

```bash
cd app
flutter build apk --release --obfuscate --split-debug-info=build/symbols
```

- 产物是 `app/build/app/outputs/flutter-apk/app-release.apk`，约 8 MB，只含 arm64-v8a。连着手机时用 `adb install -r build/app/outputs/flutter-apk/app-release.apk` 安装，或者把文件传到手机上安装。
- 两个参数不要省：`--obfuscate` 混淆 Dart 代码，`--split-debug-info` 把调试符号从安装包里拿出来放进 `build/symbols`，合起来让 APK 小约 0.5 MB。原生库压缩存放已经写在 `android/app/build.gradle.kts` 里，不需要另加参数。
- `build/symbols/app.android-arm64.symbols` 只对应这一次打出来的包（同目录下 `arm`、`x64` 的符号文件用不到）。混淆后的崩溃堆栈要靠它还原：`flutter symbolize -i <堆栈文件> -d build/symbols/app.android-arm64.symbols`。发出去的包以后可能要查崩溃的话，把这个文件和 APK 一起留一份；`build/` 不进 git，`flutter clean` 也会把它删掉。
- 正式版用的是打包那台电脑的 debug 签名（见 `android/app/build.gradle.kts`），每台电脑的签名不同。手机上已经装着别的电脑打的包时，覆盖安装会失败，先卸载旧版再装。
- 版本号是 `app/pubspec.yaml` 里的 `version`（现在是 `1.0.0+1`），发新版时改它。
- `flutter build apk --release -t lib/main_sim.dart` 打出来的是模拟器版，不连真实设备，不要当正式版发。它和正式版的 application id 相同，装上会互相覆盖。

## 环境部署脚本 tools/env_config.sh

用来在一台干净的 Linux 机器上一次装好 Flutter、Android SDK 和 JDK（不装 Android Studio），可选再装 ESP-IDF；也带卸载功能。约 940 行 bash，不要用 root 运行，需要 `sudo`。

它做什么：

- 支持 Ubuntu 22.04 / 24.04，以及 CachyOS / Arch / Manjaro；x86_64 和 aarch64。其他发行版和 Ubuntu 其他版本会直接退出。
- 装系统依赖（git、curl、unzip、xz、zip、cmake、ninja、gcc 等；cmake、ninja、gcc 留给固件的主机测试和 ESP-IDF 用）和 OpenJDK 17。本项目只做 Android，所以不再装 Flutter Linux 桌面需要的 clang、pkg-config、gtk3，并且执行 `flutter config --no-enable-linux-desktop`，`flutter precache` 也只下载 Android 的部分。
- 装 Flutter（默认 3.47.7，克隆到 `~/development/flutter`），装 Android cmdline-tools、platform-tools、platforms（默认 `android-36` 和 `android-37.0`，并给 37.0 建 `android-37` 符号链接）、build-tools 36.0.0 到 `~/Android/Sdk`，接受协议。
- 默认使用国内镜像（Flutter 源码用清华镜像，写入 `PUB_HOSTED_URL` 和 `FLUTTER_STORAGE_BASE_URL` 指向 flutter-io.cn）；`--no-mirror` 改用官方源。
- 装 adb 的 udev 规则（只有 Google `18d1` 和树莓派 `2e8a` 两个厂商 ID，别的手机见 `docs/DEV_GUIDE.md` 3.3），把用户加入 `plugdev`。
- 往 `~/.bashrc`（zsh、fish 对应各自的配置文件）写一段带标记的环境变量块（`# >>> flutter-titrator-env >>>` 到 `# <<< flutter-titrator-env <<<`），并执行 `flutter precache`。
- 幂等，可重复运行：已有的东西跳过，环境变量块先删后写。安装记录写在 `~/.flutter-titrator-env/manifest.txt`，卸载时依赖它。

它不做什么：不把用户加入 `dialout` 组，不处理 `brltty`（这两件事见 `docs/DEV_GUIDE.md` 3.1、3.2），不换 Gradle 镜像。

常用选项：

| 选项 | 作用 |
|---|---|
| `--dry-run`（`-n`） | 只预览，不执行 |
| `--no-mirror` | 不用国内镜像 |
| `--skip-system-upgrade` | Arch 系：跳过 `pacman -Syu` |
| `--pacman-mirror-cn` | Arch 系：额外把 pacman 换成国内镜像 |
| `--with-esp-idf` | 额外安装 ESP-IDF（默认 v5.5.5，装到 `~/esp/esp-idf-v5.5.5`，见下面的说明） |
| `--create-project` | 另建一个只含 Android 平台的新 Flutter 工程（见下面的说明） |
| `--uninstall` | 卸载，配合下面几个选项 |
| `--yes`（`-y`） | 卸载时不再询问，ASK 项也一并删除，慎用 |
| `--purge-deps` / `--purge-jdk` / `--remove-project` | 卸载时连系统依赖 / JDK / 项目代码一起删 |
| `--help`（`-h`） | 显示文件头里的用法 |

还可以用环境变量覆盖默认值：`FLUTTER_VERSION`、`FORCE_VERSION=1`（已装的 Flutter 版本不同时强制切换）、`JDK_VERSION`、`ANDROID_PLATFORMS`、`ANDROID_BUILD_TOOLS`、`COMPILE_SDK`、`FLUTTER_HOME`、`ANDROID_HOME`、`ESP_IDF_VERSION`、`IDF_HOME`（ESP-IDF 的安装目录，默认 `~/esp/esp-idf-$ESP_IDF_VERSION`），以及 `--create-project` 用的 `FLUTTER_PACKAGES`、`FLUTTER_DEV_PACKAGES`、`FLUTTER_SDK_PACKAGES`（用 `--sdk=flutter` 添加的 SDK 自带包，默认 `flutter_localizations`）。

卸载有三级安全策略：

- AUTO：manifest 里记录的产物（Flutter、Android SDK、`~/.pub-cache`、rc 里的环境变量块、udev 规则），整体确认一次后删除。这些目录是整个删掉的，包括你在脚本之外放进去的东西。
- ASK：扫描到的第三方 / 手动安装 / 系统包（例如 `~/.android`、`~/.espressif`、`~/esp/esp-idf-v5.5.5`、旧版本脚本用过的 `~/esp/esp-idf`），逐项确认。
- INFO：JDK、项目代码目录、已装的系统包、`plugdev` 组，只报告，不会自动删。

卸载前务必先运行 `./tools/env_config.sh --uninstall --dry-run`，看清楚会删什么。`~/esp/esp-idf-v5.5.5` 和它的工具链 `~/.espressif` 现在都会作为 ASK 项出现（只有脚本自己用 `--with-esp-idf` 克隆的 ESP-IDF 才会记进 manifest 成为 AUTO）；想保留固件工具链就不要确认删除它们，也不要加 `--yes`。

和本仓库的关系：

- `--create-project` 会另建一个独立的新工程 `~/projects/titrator_app`，只含 Android 平台，依赖是 `app/` 现在用的那些（`flutter_reactive_ble`、`flutter_riverpod`、`permission_handler`、`fl_chart`、`flutter_local_notifications`、`intl`，开发依赖 `flutter_lints`、`fake_async`，再加 SDK 自带的 `flutter_localizations`），并把 `compileSdk` 改成 37。它不会碰本仓库的 `app/`，而 `app/` 已经建好，所以日常用不到这个选项。脚本里早期 Wi-Fi / MQTT 方案的那串包（`mqtt_client`、`web_socket_channel`、`http`、`network_info_plus`、`connectivity_plus`、`nsd`）还留着，但已经注释掉，本项目没有采用，暂时留作参考。
- `--with-esp-idf` 默认装 v5.5.5，克隆到 `~/esp/esp-idf-v5.5.5`，和仓库文档一致。但它仍然只从 GitHub 克隆（没有国内镜像），丢弃 `install.sh` 的输出（失败时只有一句笼统的警告），还会装 direnv、往 rc 文件里加 hook，并在 ESP-IDF 目录里写一个 `.envrc`。GitHub 慢或连不上时，按 `docs/DEV_GUIDE.md` 第 5 节手动装。

## 协作约定

- `docs/protocol.md` 是 App 和固件之间唯一的契约：改协议先改文档，再改两端。
- 滴定用到的常量在 `firmware/components/core/include/core/config.h`，`app/lib/sim/sim_titrator.dart` 里有一份镜像，两边必须保持一致。
- 改了 `firmware/sdkconfig.defaults` 之后，先删除生成的 `firmware/sdkconfig` 再编译，否则新的默认值不会生效。
- 提交信息用简短的英文祈使句概括主要改动，例如 `Add phone connection steps to the developer guide`；每完成一个阶段性任务就提交一次。
