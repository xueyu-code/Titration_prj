#!/usr/bin/env bash
# =============================================================================
#  Flutter / ESP-IDF 开发环境 部署 + 智能卸载  v5
#  适配项目：ESP32-S3 滴定仪（Flutter Android App，BLE 通信；ESP-IDF 固件）
#  支持：Ubuntu 22.04+ · CachyOS / Arch Linux / Manjaro
#  设计：幂等可重跑 · 纯 CLI 不装 Android Studio · 国内镜像加速 · 分级安全卸载
#
#  ── 部署（在仓库根目录运行）────────────────────────────────────
#    ./tools/env_config.sh                      标准安装
#    ./tools/env_config.sh --create-project     顺便创建项目骨架（独立的纯 Android 工程）
#    ./tools/env_config.sh --with-esp-idf       顺便装 ESP-IDF（默认 v5.5.5 → ~/esp/esp-idf-v5.5.5）
#    ./tools/env_config.sh --no-mirror          不用国内镜像（海外网络）
#    ./tools/env_config.sh --pacman-mirror-cn   Arch系：额外切 pacman 国内镜像
#    ./tools/env_config.sh --skip-system-upgrade
#    ./tools/env_config.sh --dry-run            只预览不执行
#
#  ── 卸载 ────────────────────────────────────────────────────────
#    ./tools/env_config.sh --uninstall                智能扫描 + 交互确认
#    ./tools/env_config.sh --uninstall --dry-run      ★ 强烈建议先跑这个
#    ./tools/env_config.sh --uninstall --yes          无交互全删（★含第三方项）
#    ./tools/env_config.sh --uninstall --purge-deps   连系统依赖一起卸
#    ./tools/env_config.sh --uninstall --purge-jdk    连 JDK 一起卸（危险）
#    ./tools/env_config.sh --uninstall --remove-project 连项目代码一起删（极危险）
#
#  卸载三级安全策略：
#    [AUTO]  manifest 记录 = 本脚本装的产物 → 整体确认一次后删除
#    [ASK]   扫描到的第三方/手动安装/系统包 → 逐项确认
#    [INFO]  共享或高危项（JDK、项目代码、已装系统包）→ 只报告，永不自动删
# =============================================================================

set -euo pipefail
# 出错时打印行号，避免 set -e 静默退出后一脸茫然
trap 'printf "\n\033[31m✘ 第 %s 行执行失败: %s\033[0m\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

FLUTTER_VERSION="${FLUTTER_VERSION:-3.47.7}"
FORCE_VERSION="${FORCE_VERSION:-0}"
JDK_VERSION="${JDK_VERSION:-17}"
# 两个都要装：permission_handler_android / reactive_ble_mobile 的最新版要求 compileSdk 37；
# 而 shared_preferences_android 的 compileSdk 是 flutter.compileSdkVersion（3.47.7 里是 36），flutter_local_notifications 也是 36。
# 缺了 36，Gradle 会在第一次构建时自己下载安装，既慢又依赖网络和许可证，所以在这里先装好
# SDK 37 的 sdkmanager 包名是 android-37.0（没有 android-37），见 5/8 里的符号链接
ANDROID_PLATFORMS="${ANDROID_PLATFORMS:-android-36 android-37.0}"
# build-tools 36.0.0 不能去掉：AGP 9.1.0 的默认 build-tools 就是它，缺了 Gradle 会自己再下一遍
ANDROID_BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-36.0.0}"
COMPILE_SDK="${COMPILE_SDK:-37}"
# --create-project 时 flutter pub add 的包，默认是 app/ 现在用的这些。BLE: flutter_reactive_ble · 状态: flutter_riverpod
# 权限: permission_handler · 图表: fl_chart · 本地存储: shared_preferences · 通知: flutter_local_notifications · 格式化: intl
# 开发依赖 flutter_lints / fake_async；flutter_localizations 是 Flutter SDK 自带的包，要用 --sdk=flutter 单独加。
# 都可以用环境变量覆盖，例如 FLUTTER_PACKAGES="flutter_reactive_ble"
# 下面是早期的 Wi-Fi / MQTT 方案用的包，本项目没有采用，暂时留作参考
# FLUTTER_PACKAGES="${FLUTTER_PACKAGES:-flutter_reactive_ble flutter_riverpod permission_handler mqtt_client web_socket_channel http network_info_plus connectivity_plus nsd}"
FLUTTER_PACKAGES="${FLUTTER_PACKAGES:-flutter_reactive_ble flutter_riverpod permission_handler fl_chart shared_preferences flutter_local_notifications intl}"
FLUTTER_DEV_PACKAGES="${FLUTTER_DEV_PACKAGES:-flutter_lints fake_async}"
FLUTTER_SDK_PACKAGES="${FLUTTER_SDK_PACKAGES:-flutter_localizations}"
FLUTTER_HOME="${FLUTTER_HOME:-$HOME/development/flutter}"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
PROJECT_NAME="${PROJECT_NAME:-titrator_app}"
PROJECT_DIR="${PROJECT_DIR:-$HOME/projects/$PROJECT_NAME}"
ESP_IDF_VERSION="${ESP_IDF_VERSION:-v5.5.5}"
# 卸载部分在部署部分之前运行，所以要在这里定义
IDF_HOME="${IDF_HOME:-$HOME/esp/esp-idf-$ESP_IDF_VERSION}"

USE_MIRROR=1; PACMAN_MIRROR_CN=0; WITH_ESP_IDF=0; CREATE_PROJECT=0
SKIP_SYSUPGRADE=0; DRY_RUN=0
UNINSTALL=0; ASSUME_YES=0; PURGE_DEPS=0; PURGE_JDK=0; REMOVE_PROJECT=0

MARK_BEGIN="# >>> flutter-titrator-env >>>"
MARK_END="# <<< flutter-titrator-env <<<"
STATE_DIR="$HOME/.flutter-titrator-env"
MANIFEST="$STATE_DIR/manifest.txt"

if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else R=""; G=""; Y=""; B=""; N=""; fi
step(){ printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
info(){ printf '    %s\n' "$*"; }
ok(){   printf '    %s✔%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '    %s!%s %s\n' "$Y" "$N" "$*"; }
die(){  printf '\n%s✘ 失败:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
ask(){  # ask <prompt> -> 0=yes 1=no
  local p="$1" a=""
  if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
  if [[ ! -t 0 ]]; then warn "非交互终端且未加 --yes，跳过：$p"; return 1; fi
  read -r -p "    ${p} [y/N] " a || true
  [[ "$a" =~ ^[Yy]$ ]]
}
# fd3 = 原始 stdout：调用方即使写成 `run cmd >/dev/null 2>&1`，dry-run 预览也不会被一起吞掉
exec 3>&1
run(){ if [[ $DRY_RUN -eq 1 ]]; then printf '    [dry-run] %s\n' "$*" >&3; else "$@"; fi; }
# 以 root 写文件：sudo_write <目标> <内容>
# 不能再用 `cat <<EOF | run sudo tee ...`：dry-run 下 run 立刻返回，cat 往已关闭的管道写会吃 SIGPIPE，pipefail 直接杀脚本
sudo_write(){
  if [[ $DRY_RUN -eq 1 ]]; then printf '    [dry-run] 写入 %s\n' "$1" >&3; return 0; fi
  printf '%s\n' "$2" | sudo tee "$1" >/dev/null
}
# 幂等追加 manifest 记录：重跑、或之后再加 --with-esp-idf 都不会丢掉旧记录
manifest_add(){  # manifest_add <KIND> <value>
  if [[ $DRY_RUN -eq 1 ]]; then return 0; fi
  local line; line="$(printf '%s\t%s' "$1" "$2")"
  mkdir -p "$STATE_DIR"
  if ! grep -qxF -- "$line" "$MANIFEST" 2>/dev/null; then printf '%s\n' "$line" >> "$MANIFEST"; fi
}
# 需要 root 权限的删除：父目录不可写时自动 sudo（修 /etc、/opt、/usr/* 删不掉）
sudo_rm(){
  local flag="$1" target="$2" d
  d="$(dirname -- "$target")"
  if [[ -w "$d" ]]; then rm -"$flag" -- "$target"; else sudo rm -"$flag" -- "$target"; fi
}

# ─────────────────────────── 参数 ───────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-esp-idf) WITH_ESP_IDF=1; shift ;;
    --create-project) CREATE_PROJECT=1; shift ;;
    --no-mirror) USE_MIRROR=0; shift ;;
    --pacman-mirror-cn) PACMAN_MIRROR_CN=1; shift ;;
    --skip-system-upgrade) SKIP_SYSUPGRADE=1; shift ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    --uninstall|--remove) UNINSTALL=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --purge-deps) PURGE_DEPS=1; shift ;;
    --purge-jdk) PURGE_JDK=1; shift ;;
    --remove-project) REMOVE_PROJECT=1; shift ;;
    --help|-h) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) die "未知参数: $1（--help 查看用法）" ;;
  esac
done

# ─────────────────────────── 发行版识别 ───────────────────────────
step "0 识别操作系统与包管理器"
if [[ $EUID -eq 0 ]]; then die "请勿用 root 运行（会污染 SDK 权限），用普通用户执行"; fi
command -v sudo >/dev/null || die "未找到 sudo"
[[ -r /etc/os-release ]] || die "无法读取 /etc/os-release"
# shellcheck disable=SC1091
source /etc/os-release

PKG=""; JDK_PKG=""; JAVA_HOME_CANDIDATES=()
case "${ID}" in
  ubuntu)
    case "${VERSION_ID}" in
      22.04|24.04) info "Ubuntu ${VERSION_ID} LTS ✓" ;;
      *) die "仅支持 Ubuntu 22.04/24.04，当前 $VERSION_ID" ;; esac
    PKG="apt"; JDK_PKG="openjdk-${JDK_VERSION}-jdk"
    JAVA_HOME_CANDIDATES=("/usr/lib/jvm/java-${JDK_VERSION}-openjdk-amd64" "/usr/lib/jvm/java-${JDK_VERSION}-openjdk")
    ;;
  cachyos|cachyos*|arch|manjaro|manjaro*)
    info "${PRETTY_NAME} ✓"
    PKG="pacman"; JDK_PKG="jdk${JDK_VERSION}-openjdk"
    JAVA_HOME_CANDIDATES=("/usr/lib/jvm/java-${JDK_VERSION}-openjdk" "/usr/lib/jvm/java-${JDK_VERSION}-openjdk-amd64")
    ;;
  *) die "不支持的发行版: ${ID}（支持 Ubuntu / CachyOS / Arch / Manjaro）" ;;
esac

## ★ 修复：直接 grep /etc/pacman.conf 的 'cachyos-v4' 字符串会命中被注释掉的 disabled_v4 段
#   （真机实测：CachyOS 默认 pacman.conf 里即使 v4 仓库禁用，注释行里也留着这串文字），
#   导致 v4 根本没启用也误报。改用 pacman-conf --repo-list 只看实际生效的仓库。
if [[ "${ID}" == cachyos* ]] \
   && pacman-conf --repo-list 2>/dev/null | grep -Eq '(^|-)(v4|znver4)$' \
   && ! grep -qw avx512f /proc/cpuinfo 2>/dev/null; then
  warn "检测到已启用 v4/znver4 仓库但 CPU 无 AVX-512 → 二进制会崩溃"
  warn "请在 /etc/pacman.conf 中注释掉对应 v4/znver4 仓库的 [section] 段"
fi

LOGIN_SHELL="$(basename "${SHELL:-/bin/bash}")"
case "$LOGIN_SHELL" in
  bash) RC_FILE="$HOME/.bashrc"; RC_SYNTAX="bash" ;;
  zsh)  RC_FILE="$HOME/.zshrc";  RC_SYNTAX="zsh" ;;
  fish) RC_FILE="$HOME/.config/fish/config.fish"; RC_SYNTAX="fish" ;;
  *)    RC_FILE="$HOME/.bashrc"; RC_SYNTAX="bash"
        warn "未识别 shell $LOGIN_SHELL，回退 ~/.bashrc" ;;
esac
info "shell: $LOGIN_SHELL → $RC_FILE"

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) FLUTTER_ARCH="linux-x64" ;;
  aarch64|arm64) FLUTTER_ARCH="linux-arm64" ;;
  *) die "不支持的架构: $ARCH_RAW" ;;
esac

# ★ 修复：不再用 "for ...; do [[ -d ]] && {...}; done"（最后一个候选不存在时
#   循环返回 1，set -e 会静默杀掉脚本）。统一走 find_java_home。
find_java_home(){
  local c j
  for c in "${JAVA_HOME_CANDIDATES[@]}"; do
    if [[ -d "$c" ]]; then printf '%s' "$c"; return 0; fi
  done
  if command -v javac >/dev/null 2>&1; then
    j="$(readlink -f "$(command -v javac)")"
    printf '%s' "$(dirname "$(dirname "$j")")"; return 0
  fi
  return 0
}
JAVA_HOME="$(find_java_home)"
[[ -n "$JAVA_HOME" ]] || info "未检测到 JAVA_HOME（装完 JDK 后会再探测一次）"

###############################################################################
#                             卸 载 模 式
###############################################################################
if [[ $UNINSTALL -eq 1 ]]; then

# ── 目标登记（自动去重，dir 一律规范化后去重） ──
declare -a T_TIER T_KIND T_ARG T_DESC
declare -A T_SEEN=()
add_t(){  # add_t <tier> <kind> <arg> <desc>
  local tier="$1" kind="$2" arg="$3" desc="$4"
  [[ -n "$arg" ]] || return 0
  if [[ "$kind" == "dir" ]]; then arg="$(readlink -f "$arg" 2>/dev/null || printf '%s' "$arg")"; fi
  local key="$kind:$arg"
  if [[ -n "${T_SEEN[$key]:-}" ]]; then return 0; fi
  T_SEEN[$key]=1
  T_TIER+=("$tier"); T_KIND+=("$kind"); T_ARG+=("$arg"); T_DESC+=("$desc")
  return 0
}

is_safe_path(){  # 拒绝删除关键路径 + 未授权的项目目录
  local p; p="$(readlink -f "$1" 2>/dev/null || printf '%s' "$1")"
  case "$p" in
    "/"|"/home"|"/root"|"/usr"|"/etc"|"/var"|"/opt"|"/srv"|"$HOME") return 1 ;;
  esac
  # 项目代码目录默认受保护，除非显式 --remove-project
  if [[ $REMOVE_PROJECT -eq 0 && -n "${PROJECT_DIR:-}" ]]; then
    local pd; pd="$(readlink -f "$PROJECT_DIR" 2>/dev/null || printf '%s' "$PROJECT_DIR")"
    if [[ "$p" == "$pd" || "$p" == "$pd"/* ]]; then return 1; fi
  fi
  [[ "$p" == "$HOME"/* || "$p" == "/opt/"* || "$p" == "/usr/local/"* \
     || "$p" == "/usr/lib/"* || "$p" == "/usr/share/"* || "$p" == "/var/"* ]] || return 1
  return 0
}
# du 遇到无权限的子目录会返回非 0 但仍有输出，原来的 `|| printf '?'` 会拼出 "1.2G?"；超时无输出时才该显示 ?
size_of(){ { timeout 15 du -sh "$1" 2>/dev/null || true; } | awk 'NR==1{print $1; f=1} END{if(!f) print "?"}'; }

# ─────────────────────────── 扫描 ───────────────────────────
step "1/5 智能扫描系统中已安装的 Flutter / ESP-IDF 环境"

# --- 1a. 包管理器数据库（最可靠，任意路径都能拿到） ---
scan_pkg_db(){
  local p roots d
  if [[ "$PKG" == "pacman" ]]; then
    for p in flutter flutter-dev flutter-beta dart dart-sdk android-sdk android-sdk-cmdline-tools; do
      pacman -Qq "$p" >/dev/null 2>&1 || continue
      # awk -F/ 会把 "/usr/lib/flutter" 拆成 ""、usr、lib、flutter —— $1 是空串，
      # 原来的 $1=="/usr" 永远不成立，包提供的目录一个也识别不出来。
      # /usr/lib/<x> 只认名字带 flutter|dart|android 的，免得把 /usr/lib/systemd 之类的共享目录也列进来
      roots="$(pacman -Ql "$p" 2>/dev/null | awk '{print $2}' \
        | sed 's#/$##' | awk -F/ '$2=="usr" && $3=="lib" && NF>=4 && $4 ~ /flutter|dart|android/ {print "/usr/lib/"$4}
                            $2=="opt" && NF>=3 {print "/opt/"$3}' | sort -u || true)"
      if [[ -n "$roots" ]]; then
        while read -r d; do
          [[ -n "$d" && -e "$d" ]] || continue
          is_safe_path "$d" || continue
          add_t ASK dir "$d" "pacman 包 [$p] 提供的 Flutter/Dart SDK 目录"
        done <<< "$roots"
      fi
      add_t ASK pkg "pacman -Rns --noconfirm $p" "pacman 包: $p"
      info "发现 pacman 包: $p"
    done
  elif [[ "$PKG" == "apt" ]]; then
    for p in flutter dart android-sdk adb; do
      dpkg -s "$p" >/dev/null 2>&1 || continue
      # 同上：原来 /usr/lib/x 只会输出 "/usr/lib"（取错了字段），随后被 is_safe_path 拒掉
      roots="$(dpkg -L "$p" 2>/dev/null | sed 's#/$##' \
        | awk -F/ '$2=="usr" && $3=="lib" && NF>=4 && $4 ~ /flutter|dart|android/ {print "/usr/lib/"$4}
                   $2=="opt" && NF>=3 {print "/opt/"$3}' | sort -u || true)"
      if [[ -n "$roots" ]]; then
        while read -r d; do
          [[ -n "$d" && -e "$d" ]] || continue
          is_safe_path "$d" || continue
          add_t ASK dir "$d" "apt 包 [$p] 提供的目录"
        done <<< "$roots"
      fi
      add_t ASK pkg "apt-get purge -y $p" "apt 包: $p"
      info "发现 apt 包: $p"
    done
  fi

  if command -v snap >/dev/null 2>&1; then
    while read -r s; do
      [[ -n "$s" ]] || continue
      add_t ASK pkg "sudo snap remove $s" "snap 包: $s"; info "发现 snap 包: $s"
    done < <(snap list 2>/dev/null | awk 'NR>1{print $1}' | grep -Ei 'flutter|android-studio' || true)
  fi
  if command -v flatpak >/dev/null 2>&1; then
    while read -r s; do
      [[ -n "$s" ]] || continue
      add_t ASK pkg "flatpak uninstall -y $s" "flatpak 应用: $s"; info "发现 flatpak: $s"
    done < <(flatpak list --app --columns=application 2>/dev/null | grep -Ei 'flutter|androidstudio' || true)
  fi
}
scan_pkg_db

# --- 1b. which 反查（抓 snap/自带版 flutter） ---
for exe in flutter dart idf.py adb sdkmanager; do
  p="$(command -v "$exe" 2>/dev/null || true)"
  [[ -n "$p" ]] || continue
  rp="$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")"
  # snap 的入口是 /snap/bin/<app> → /usr/bin/snap，readlink -f 之后就不再是 /snap/* 了，所以要先看未解析的路径；
  # 若解析后确是 /snap/<name>/<rev>/...，name 是第 3 段（原来 cut -f4 取到的是 revision 号，拼出 "snap remove 1234"）
  snap_name=""
  case "$p" in /snap/bin/*) snap_name="$(basename "$p")"; snap_name="${snap_name%%.*}" ;; esac
  case "$rp" in /snap/*) snap_name="$(printf '%s' "$rp" | cut -d/ -f3)" ;; esac
  if [[ -n "$snap_name" ]]; then
    add_t ASK pkg "sudo snap remove $snap_name" "通过 which 发现的 snap 安装: $exe"
  fi
  case "$rp" in
    /var/lib/flatpak/*|"$HOME"/.local/share/flatpak/*) info "跳过 flatpak 管理的 $exe（用 flatpak uninstall）" ;;
  esac
done

# --- 1c. manifest（★ 放在路径扫描之前：先到先得，保证本脚本产物是 AUTO） ---
if [[ -f "$MANIFEST" ]]; then
  while IFS=$'\t' read -r kind val; do
    [[ -n "$val" ]] || continue
    case "$kind" in
      PATH) if [[ -e "$val" ]] && is_safe_path "$val"; then add_t AUTO dir "$val" "manifest: 本脚本装的目录"; fi ;;
      RC)   add_t AUTO rcblk "$val" "manifest: rc 环境变量块" ;;
      UDEV) if [[ -e "$val" ]]; then add_t AUTO udev "$val" "manifest: adb udev 规则"; fi ;;   # 与 PATH 一致：文件不在就别列进计划
      # ★ 修复：原来这里只传了 3 个参数，kind/arg 全错位 → 报告刷空行
      PKG)  add_t INFO pkg "$val" "本脚本曾安装的系统包（共享依赖，默认保留）" ;;
    esac
  done < "$MANIFEST"
  info "已读取 manifest: $MANIFEST"
else
  info "未找到 manifest（可能非本脚本安装，将依赖实时扫描）"
fi

# --- 1d. 常见手动安装路径扫描 ---
# 注意：这些路径无法证明归属，一律记为 ASK（逐项确认），不再冒充 AUTO
SCAN_CAND=(
  "$FLUTTER_HOME" "$HOME/flutter" "$HOME/sdk/flutter" "$HOME/Development/flutter"
  "$HOME/development/flutter" "$HOME/opt/flutter" "/opt/flutter" "/usr/local/flutter"
  "/usr/local/share/flutter" "/usr/lib/flutter" "/usr/share/flutter"
  "$HOME/fvm" "$HOME/.fvm" "${FVM_CACHE_PATH:-$HOME/fvm/versions}"
  "$ANDROID_HOME" "$HOME/Android/Sdk" "$HOME/android-sdk" "$HOME/Android/android-sdk"
  "/opt/android-sdk" "/opt/android-sdk-linux" "/usr/lib/android-sdk" "/usr/share/android-sdk"
  # ★ 不再扫 "$HOME/esp" 整个目录（里面可能有你自己的其它工程）
  "$IDF_HOME" "$HOME/esp/esp-idf" "$HOME/esp-idf" "/opt/esp/idf" "/opt/esp-idf" "/usr/local/esp-idf"
  "$HOME/.espressif" "$HOME/.pub-cache" "$HOME/.android"
  "/opt/android-studio" "/opt/android-studio-linux" "$HOME/android-studio"
  "/usr/local/android-studio"
)
for p in "${SCAN_CAND[@]}"; do
  [[ -n "$p" && -e "$p" ]] || continue
  rp="$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")"
  case "$rp" in /snap/*|/var/lib/flatpak/*) continue ;; esac
  if ! is_safe_path "$rp"; then warn "跳过可疑/受保护路径: $rp"; continue; fi
  cwd="$(readlink -f "$PWD")"
  if [[ "$rp" == "$cwd" || "$PWD" == "$rp"/* ]]; then warn "跳过当前工作目录所在路径: $rp"; continue; fi
  add_t ASK dir "$rp" "常见安装路径（非本脚本安装证据）"
done

# --- 1e. shell 配置文件残留 ---
# ★ 修复：原来的 for 循环体以 `grep && add_t` 结尾，没有 direnv 的机器上
#   循环体返回 1 → set -e 静默退出。全部改成 if。
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.config/fish/config.fish"; do
  [[ -f "$rc" ]] || continue
  if grep -qF "$MARK_BEGIN" "$rc" 2>/dev/null; then
    add_t AUTO rcblk "$rc" "rc 文件中的环境变量块"
  fi
  if grep -qF 'direnv hook' "$rc" 2>/dev/null; then
    add_t AUTO straydirenv "$rc" "rc 文件中的 direnv hook 行（共享工具，谨慎）"
  fi
done

# --- 1f. 其它残留 ---
# ★ 同上：修复 1f 的 for 循环 set -e 静默退出
if [[ -f /etc/udev/rules.d/51-android.rules ]]; then
  add_t AUTO udev "/etc/udev/rules.d/51-android.rules" "adb udev 规则"
fi
if [[ -e "$STATE_DIR" ]]; then add_t AUTO dir "$STATE_DIR" "本脚本的状态/manifest 目录"; fi
for f in "$IDF_HOME/.envrc" "$HOME/esp/esp-idf/.envrc" "$HOME/.envrc"; do
  [[ -f "$f" ]] || continue
  # ★ ~/.envrc 是全局 direnv 配置，降级为 ASK（绝不无脑删）
  if grep -q 'export.sh' "$f" 2>/dev/null; then
    if [[ "$f" == "$HOME/.envrc" ]]; then
      add_t ASK file "$f" "全局 ~/.envrc（含 ESP-IDF export，可能还配了别的项目）"
    else
      add_t AUTO file "$f" "ESP-IDF direnv 配置"
    fi
  fi
done
if [[ -d "$PROJECT_DIR" ]]; then
  if [[ $REMOVE_PROJECT -eq 1 ]]; then
    add_t AUTO dir "$PROJECT_DIR" "★ 你的项目源代码"
  else
    add_t INFO dir "$PROJECT_DIR" "你的项目源代码（默认保护）"
  fi
fi
if [[ $PURGE_JDK -eq 1 ]]; then
  # pkg 类条目的 arg 是"要执行的命令"，原来这里只放了包名，执行时变成 `sudo bash -c "openjdk-17-jdk"`
  if [[ "$PKG" == "pacman" ]]; then JDK_RM_CMD="pacman -Rns --noconfirm $JDK_PKG"; else JDK_RM_CMD="apt-get purge -y $JDK_PKG"; fi
  add_t ASK pkg "$JDK_RM_CMD" "★ JDK $JDK_VERSION（会影响所有 Java/Gradle 项目）"
else
  add_t INFO pkg "$JDK_PKG" "JDK $JDK_VERSION（共享组件，默认保留）"
fi

# ─────────────────────────── 展示计划 ───────────────────────────
step "2/5 卸载计划"
TOTAL=${#T_TIER[@]}
if [[ $TOTAL -eq 0 ]]; then ok "未发现任何 Flutter / ESP-IDF 环境残留，系统干净"; exit 0; fi

declare -a IDX_A=() IDX_K=()
printf '\n'
for i in $(seq 0 $((TOTAL-1))); do
  t="${T_TIER[$i]}"; k="${T_KIND[$i]}"; a="${T_ARG[$i]}"; d="${T_DESC[$i]}"
  sz=""; if [[ "$k" == "dir" ]]; then sz=" ($(size_of "$a"))"; fi
  case "$t" in
    AUTO) printf '  %s[%s] %-3d %s%s%s\n' "$Y" "AUTO" "$((i+1))" "$a" "$sz" "$N"
          printf '         %s↳ %s%s\n' "$Y" "$d" "$N"; IDX_A+=("$i") ;;
    ASK)  printf '  %s[%s] %-3d %s%s\n' "$B" "ASK " "$((i+1))" "$a" "$N"
          printf '         %s↳ %s%s\n' "$B" "$d" "$N"; IDX_K+=("$i") ;;
    INFO) printf '  %s[%s] %-3d %s%s\n' "$G" "INFO" "$((i+1))" "$a" "$N"
          printf '         %s↳ %s%s\n' "$G" "$d" "$N" ;;
  esac
done

printf '\n%s说明:%s [AUTO]=本脚本装的，整体确认后删  [ASK]=第三方安装，逐项确认  [INFO]=只报告不动\n' "$B" "$N"
if [[ $DRY_RUN -eq 1 ]]; then
  cat <<EOF

${Y}${B}══════════════════════════════════════════════════════${N}
${Y}${B} 🔍 DRY-RUN：以上均为预览，本次未做任何修改${N}
${Y}${B}══════════════════════════════════════════════════════${N}
EOF
  exit 0
fi

# ─────────────────────────── 执行 ───────────────────────────
step "3/5 执行卸载"
FAIL=0
sudo -v || die "sudo 认证失败"   # 缓存凭证，避免后面反复输密码

# 先清 rc —— 万一后面失败，shell 至少是干净的
# ★ 修复：数组为空时 "${arr[@]:-}" 会产生一个空元素，下标被当成 0 → 误操作第 0 项
for i in ${IDX_A[@]+"${IDX_A[@]}"}; do
  [[ "${T_TIER[$i]}" == "AUTO" && "${T_KIND[$i]}" == "rcblk" ]] || continue
  f="${T_ARG[$i]}"
  [[ -f "$f" ]] || continue
  cp -n "$f" "$f.pre-uninstall.bak" 2>/dev/null || true
  sed -i "\|^${MARK_BEGIN}|,\|^${MARK_END}|d" "$f"
  ok "已清理环境变量块: $f (备份: $f.pre-uninstall.bak)"
done
for i in ${IDX_A[@]+"${IDX_A[@]}"}; do
  [[ "${T_TIER[$i]}" == "AUTO" && "${T_KIND[$i]}" == "straydirenv" ]] || continue
  ask "移除 $(basename "${T_ARG[$i]}") 里的 direnv hook 行？" || continue
  cp -n "${T_ARG[$i]}" "${T_ARG[$i]}.pre-uninstall.bak" 2>/dev/null || true
  sed -i '/direnv hook/d' "${T_ARG[$i]}"
  ok "已移除 direnv hook 行"
done

AUTO_LIST=()
for i in ${IDX_A[@]+"${IDX_A[@]}"}; do
  k="${T_KIND[$i]}"
  [[ "$k" == "rcblk" || "$k" == "straydirenv" ]] && continue
  AUTO_LIST+=("$i")
done
if [[ ${#AUTO_LIST[@]} -gt 0 ]]; then
  warn "即将永久删除 ${#AUTO_LIST[@]} 项（AUTO 分类）"
  # ★ 修复：原来只检查 AUTO_LIST[0]，项目代码排在别处时不告警
  if [[ $REMOVE_PROJECT -eq 1 ]]; then
    printf '    %s⚠  包含你的项目源代码：%s%s\n' "$R" "$PROJECT_DIR" "$N"
  fi
  ask "确认删除以上 AUTO 项？此操作不可恢复" || die "已取消"
fi
for i in ${AUTO_LIST[@]+"${AUTO_LIST[@]}"}; do
  k="${T_KIND[$i]}"; a="${T_ARG[$i]}"
  case "$k" in
    # ★ 修复：/etc、/opt、/usr/* 需要 sudo，否则永远删不掉
    dir)   if sudo_rm "rf" "$a"; then ok "已删除目录: $a"; else warn "删除失败: $a"; FAIL=1; fi ;;
    file)  if sudo_rm "f"  "$a"; then ok "已删除文件: $a"; else warn "删除失败: $a"; FAIL=1; fi ;;
    udev)  if sudo_rm "f"  "$a"; then
             command -v udevadm >/dev/null && sudo udevadm control --reload-rules 2>/dev/null || true
             ok "已删除 udev 规则: $a"
           else warn "删除失败: $a"; FAIL=1; fi ;;
    *)     warn "未知类型，跳过: $k $a" ;;
  esac
done

# ASK 逐项
for i in ${IDX_K[@]+"${IDX_K[@]}"}; do
  k="${T_KIND[$i]}"; a="${T_ARG[$i]}"
  warn "待确认: ${T_DESC[$i]}"
  ask "  执行 → $a" || { info "  跳过"; continue; }
  if [[ "$k" == "pkg" ]]; then
    # flatpak 要以当前用户身份跑：root 看不到用户级安装（系统级的会走 polkit 提权）
    if [[ "$a" == flatpak\ * ]]; then PKG_RUN=(bash -c "$a"); else PKG_RUN=(sudo bash -c "$a"); fi
    if "${PKG_RUN[@]}"; then ok "已执行: $a"; else warn "执行失败: $a"; FAIL=1; fi
  else
    is_safe_path "$a" || { warn "保护规则拦截: $a"; continue; }
    if [[ "$k" == "dir" ]]; then
      if sudo_rm "rf" "$a"; then ok "已删除: $a"; else warn "删除失败: $a"; FAIL=1; fi
    else
      if sudo_rm "f" "$a"; then ok "已删除: $a"; else warn "删除失败: $a"; FAIL=1; fi
    fi
  fi
done

# ── 可选：系统依赖（原 [[ ]] || ask && {} 优先级混乱，改成 if） ──
if [[ $PURGE_DEPS -eq 1 ]]; then
  step "3b 卸载系统依赖包"
  warn "注意：git / curl / clang / cmake 等通常被其它软件共用，可能导致连带卸载"
  if [[ $ASSUME_YES -eq 1 ]] || ask "卸载系统依赖（git/curl/clang/cmake/gtk3/android-tools 等）？"; then
    if [[ "$PKG" == "pacman" ]]; then
      # Arch 没有 lzma 这个包（xz 已取代），列在里面会 "target not found"；
      # clang / pkgconf / gtk3 现在不装了，但旧版本脚本装过，所以清单里保留；
      # 另外 pacman 事务是整体的：只要有一个被别的包依赖（curl、xz 几乎必然），整条命令全部失败，所以逐个卸
      DEPS=(git curl unzip xz zip clang cmake ninja pkgconf gtk3 android-tools)
      for d in "${DEPS[@]}"; do
        pacman -Qq "$d" >/dev/null 2>&1 || continue
        if sudo pacman -Rns --noconfirm "$d"; then ok "已卸载 $d"; else warn "保留 $d（被其它软件依赖）"; fi
      done
    else
      DEPS=(git curl unzip xz-utils zip clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev)
      if sudo apt-get purge -y "${DEPS[@]}"; then ok "依赖已卸载"; else warn "部分依赖卸载失败"; fi
    fi
  else
    info "已跳过依赖卸载"
  fi
fi

# ── JDK：卸载动作已经在计划里作为 ASK 项逐项确认并执行（原来这里再问、再卸一遍，计划里那条还是坏的），
#    这里只做事后提醒 ──
if [[ $PURGE_JDK -eq 1 ]] && command -v java >/dev/null 2>&1; then
  warn "PATH 上仍有 java: $(command -v java) → 可能还有其它 JDK；rc 文件里的 JAVA_HOME 已随环境变量块删除"
fi

# ─────────────────────────── 验证 ───────────────────────────
step "4/5 验证清理结果"
LEFT=0
for p in "$FLUTTER_HOME" "$ANDROID_HOME" "$IDF_HOME" "$HOME/esp/esp-idf" "$HOME/.espressif" "$HOME/.pub-cache" \
         "$HOME/fvm" "/usr/lib/flutter" "/opt/flutter" "/opt/android-studio"; do
  if [[ -e "$p" ]]; then warn "残留: $p"; LEFT=$((LEFT+1)); fi
done
if [[ -f /etc/udev/rules.d/51-android.rules ]]; then warn "残留: /etc/udev/rules.d/51-android.rules"; LEFT=$((LEFT+1)); fi
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.config/fish/config.fish"; do   # 与 1e 扫描的 rc 列表一致
  if [[ -f "$rc" ]] && grep -qF "$MARK_BEGIN" "$rc"; then
    warn "残留环境变量块，请手动删除或重开终端: $rc"; LEFT=$((LEFT+1))
  fi
done
for exe in flutter dart idf.py adb; do
  if command -v "$exe" >/dev/null 2>&1; then warn "$exe 仍在 PATH: $(command -v "$exe")"; LEFT=$((LEFT+1)); fi
done
if [[ $LEFT -eq 0 ]]; then ok "验证通过：已无残留"; else warn "发现 $LEFT 项残留（见上），部分可能需重开 shell / 注销后复查"; fi

# ─────────────────────────── 报告 ───────────────────────────
step "5/5 保留项与后续建议"
printf '\n'
printf '  %s%s以下项目已保留（[INFO] 分类，不会自动删除）：%s\n' "$G" "$B" "$N"
for i in $(seq 0 $((TOTAL-1))); do
  if [[ "${T_TIER[$i]}" == "INFO" ]]; then printf '    • %s\n' "${T_ARG[$i]}"; fi
done
printf '    • 用户组 plugdev（可能有其他 Android 项目在用）\n'
printf '    • rc 文件备份 *.pre-uninstall.bak（如需恢复：mv 回去）\n'
cat <<EOF

${B}手动收尾（rc 文件要新开终端才生效）：${N}
    exec ${LOGIN_SHELL}          # 让清理后的 PATH 生效
    # 复查: command -v flutter dart idf.py adb ; flutter doctor
    # 若仍指向已删目录，检查 ${RC_FILE} 和 ~/.profile 里的残留 export

${Y}${B}需要更彻底时：${N}
    --purge-deps      连 git/clang/cmake/gtk3/android-tools 等系统依赖一起卸
    --purge-jdk       连 ${JDK_PKG} 一起卸（⚠ 会影响所有 Java/Gradle 项目）
    --remove-project  连项目源代码一起删（⚠⚠ 代码不可恢复，请先备份/已推 git）

${G}════════════════════════════════════════════════════════════${N}
EOF
if [[ $FAIL -eq 1 ]]; then warn "过程中有部分操作失败，请检查上方提示"; fi
exit "$FAIL"   # 原来恒为 exit 0，脚本/CI 里没法判断卸载是否成功
fi

###############################################################################
#                             部 署 模 式
###############################################################################

# ── 包管理器封装 ──
case "$PKG" in
  apt)
    pkg_install(){ sudo apt-get update -qq; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@"; }
    pkg_exists(){ dpkg -s "$1" >/dev/null 2>&1; }
    ;;
  pacman)
    # 镜像必须在 -Syu 之前切换，否则最耗流量的那次全量升级仍然走海外源
    if [[ $PACMAN_MIRROR_CN -eq 1 ]]; then
      step "0b 切换 pacman 国内镜像"
      if [[ "${ID}" == manjaro* ]]; then
        # Manjaro 仓库路径是 /manjaro/stable/$repo/$arch，覆盖成 Arch 的 mirrorlist 会让系统更新直接 404
        warn "Manjaro 的镜像格式与 Arch 不同，不覆盖 mirrorlist；请改用: sudo pacman-mirrors --country China"
      else
        ML="/etc/pacman.d/mirrorlist"
        if [[ -f "$ML" && ! -f "${ML}.bak" ]]; then run sudo cp "$ML" "${ML}.bak" && info "已备份 → ${ML}.bak"; fi
        # 这里只放 Arch 官方仓库（core/extra）的镜像；原来混进去的 cachyos-v3 行对 core/extra 全是 404
        sudo_write "$ML" '## 由 flutter 环境脚本生成  备份: mirrorlist.bak
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch'
        ok "pacman 镜像已切换（仅 Arch 官方仓库；CachyOS 自有仓库的镜像列表不动）"
      fi
    fi
    if [[ $SKIP_SYSUPGRADE -eq 0 ]]; then
      info "pacman -Syu 全量升级（Arch 禁止部分升级）..."
      # 升级失败还继续装包就是 partial upgrade，原来这里失败是静默的
      run sudo pacman -Syu --noconfirm \
        || die "pacman -Syu 失败：继续安装会造成 partial upgrade。请修复网络/镜像后重试，或加 --skip-system-upgrade 自行承担风险"
      ok "系统已升级"
    else
      warn "已跳过全量升级 —— partial upgrade 是 Arch 头号故障源，建议尽快 pacman -Syu"
    fi
    pkg_install(){ sudo pacman -S --needed --noconfirm "$@"; }
    pkg_exists(){ pacman -Qq "$1" >/dev/null 2>&1; }
    ;;
esac

MANIFEST_PKGS=()
step "1/8 安装系统依赖"
# 本项目只做 Android，不需要 Flutter Linux 桌面的 clang / pkg-config / gtk3；
# cmake / ninja / gcc 留着，给固件的主机测试（firmware/test/host）和 ESP-IDF 用
if [[ "$PKG" == "apt" ]]; then
  DEPS=(git curl unzip xz-utils zip ca-certificates cmake ninja-build g++ build-essential)
else
  DEPS=(git curl unzip xz zip ca-certificates base-devel cmake ninja android-tools)
fi
if [[ $WITH_ESP_IDF -eq 1 ]]; then
  # ESP-IDF install.sh 的前置依赖。apt 用了 --no-install-recommends，python3-venv 不会被顺带装上，缺它 install.sh 必挂
  if [[ "$PKG" == "apt" ]]; then
    DEPS+=(wget flex bison gperf python3 python3-pip python3-venv ccache libffi-dev libssl-dev dfu-util libusb-1.0-0)
  else
    DEPS+=(wget flex bison gperf python python-pip ccache libffi openssl dfu-util libusb)
  fi
fi
if run pkg_install "${DEPS[@]}"; then ok "系统依赖就绪"; else die "依赖安装失败"; fi
MANIFEST_PKGS+=("${DEPS[@]}")

step "2/8 安装 OpenJDK $JDK_VERSION  (包名: $JDK_PKG)"
# 用 javac 判断：只有 JRE 的机器 java 在、javac 不在，没法做 Android 构建；
# 同时避开 `java -version | head -1 | grep -q` 在 pipefail 下可能被 SIGPIPE 误判的写法
if command -v javac >/dev/null 2>&1 && [[ "$(javac -version 2>&1 || true)" == "javac $JDK_VERSION"* ]]; then
  ok "JDK $JDK_VERSION 已存在"
else
  run pkg_install "$JDK_PKG" || die "JDK 安装失败（Arch 可用 pacman -Ss jdk 查看版本）"
  ok "已安装 $JDK_PKG"
fi
JAVA_HOME="$(find_java_home)"
if [[ -z "$JAVA_HOME" ]]; then
  warn "仍未探测到 JAVA_HOME —— 稍后写入 rc 时将跳过 JAVA_HOME（避免写空串搞坏 Gradle）"
else
  info "JAVA_HOME=$JAVA_HOME"
fi

step "3/8 安装 Flutter SDK $FLUTTER_VERSION"
if [[ "$PKG" == "pacman" ]] && pkg_exists flutter; then
  warn "检测到 pacman 仓库版 flutter，本脚本仍装独立 SDK 到 $FLUTTER_HOME"
  warn "请确保 PATH 中只有 \$FLUTTER_HOME/bin，避免两套 flutter 抢缓存"
fi
run mkdir -p "$(dirname "$FLUTTER_HOME")"
if [[ -d "$FLUTTER_HOME/.git" ]]; then
  ok "已存在: $FLUTTER_HOME"
  CUR="$(git -C "$FLUTTER_HOME" describe --tags --exact-match 2>/dev/null || echo unknown)"
  if [[ "$CUR" != "$FLUTTER_VERSION" ]]; then
    warn "当前 $CUR ≠ 目标 $FLUTTER_VERSION"
    if [[ $FORCE_VERSION -eq 1 ]]; then
      # ★ 修复：FORCE_VERSION 之前根本没人读，现在真正生效
      info "FORCE_VERSION=1 → 强制切换到 $FLUTTER_VERSION"
      # --unshallow 只能用于浅克隆，对完整仓库直接报错——第二次切换版本必然"切换失败"
      FETCH_ARGS=(--tags origin)
      if [[ "$(git -C "$FLUTTER_HOME" rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
        FETCH_ARGS=(--unshallow "${FETCH_ARGS[@]}")
      fi
      run git -C "$FLUTTER_HOME" fetch "${FETCH_ARGS[@]}" \
        && run git -C "$FLUTTER_HOME" checkout -q "$FLUTTER_VERSION" \
        && ok "已切换到 $FLUTTER_VERSION" \
        || warn "切换失败，保持当前版本"
    else
      info "如需强制切换：FORCE_VERSION=1 $0"
    fi
  fi
else
  info "克隆 Flutter 仓库（首次数分钟）..."
  OFFICIAL="https://github.com/flutter/flutter.git"
  REPO="$OFFICIAL"; if [[ $USE_MIRROR -eq 1 ]]; then REPO="https://mirrors.tuna.tsinghua.edu.cn/git/flutter-sdk.git"; fi
  # ★ 多一级兜底：镜像 tag → 官方 tag → stable 分支（避免版本号写错就彻底卡死）
  if ! run git clone -b "$FLUTTER_VERSION" --depth 1 "$REPO" "$FLUTTER_HOME"; then
    if ! run git clone -b "$FLUTTER_VERSION" --depth 1 "$OFFICIAL" "$FLUTTER_HOME"; then
      warn "tag $FLUTTER_VERSION 不存在，回退到 stable 分支最新稳定版"
      run git clone -b stable --depth 1 "$OFFICIAL" "$FLUTTER_HOME" \
        || die "Flutter 克隆失败（可加 --no-mirror 重试，或手动设置 FLUTTER_VERSION）"
    fi
  fi
  ok "已安装 Flutter（目标 $FLUTTER_VERSION）"
  info "以后 flutter upgrade 前先执行: git -C $FLUTTER_HOME fetch --unshallow"
fi

step "4/8 配置国内镜像"
if [[ $USE_MIRROR -eq 1 ]]; then
  # 本进程也必须导出：后面的 flutter config / precache / create 都在本脚本进程里跑，
  # 只写进 rc 的话，首次下载 Dart SDK 与引擎仍然走 storage.googleapis.com，国内镜像等于没配
  export PUB_HOSTED_URL="https://pub.flutter-io.cn"
  export FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
  info "PUB_HOSTED_URL / FLUTTER_STORAGE_BASE_URL 已对本次安装生效，第 6 步会写入 $RC_FILE"
else ok "使用官方源"; fi

step "5/8 安装 Android SDK（不装 Android Studio）"
SDKMANAGER_BIN="$ANDROID_HOME/cmdline-tools/latest/bin"
if [[ ! -x "$SDKMANAGER_BIN/sdkmanager" ]]; then
  run mkdir -p "$ANDROID_HOME/cmdline-tools"
  info "解析最新 command-line tools..."
  # sort -V：构建号位数不同时（9477386 vs 11076708），字典序 sort -u | tail -1 会挑中更旧的那个
  # 这一步有兜底版本号，所以必须限时：dl.google.com 不通时 --retry 3 会挂上好几分钟
  CT="$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 https://dl.google.com/android/repository/repository2-3.xml 2>/dev/null \
        | grep -o 'commandlinetools-linux-[0-9]\+_latest\.zip' | sort -uV | tail -1 || true)"
  [[ -z "$CT" ]] && CT="commandlinetools-linux-11076708_latest.zip"
  info "使用: $CT"
  # dry-run 不建临时目录；真跑时用完即删（原来无论如何都 mktemp -d，且从不清理）
  CT_DIR=""; TMP="(dry-run)/ct.zip"
  if [[ $DRY_RUN -eq 0 ]]; then CT_DIR="$(mktemp -d)"; TMP="$CT_DIR/ct.zip"; fi
  run curl -fSL --retry 3 -o "$TMP" "https://dl.google.com/android/repository/$CT" || die "cmdline-tools 下载失败"
  # 必须整理成 cmdline-tools/latest/ 结构，否则 flutter doctor 报组件缺失
  # 顺手清掉上次中断可能残留的 cmdline-tools/cmdline-tools；unzip 加 -o，避免它交互询问是否覆盖而卡死
  run rm -rf "$ANDROID_HOME/cmdline-tools/latest" "$ANDROID_HOME/cmdline-tools/cmdline-tools"
  run mkdir -p "$ANDROID_HOME/cmdline-tools/latest"
  run unzip -qo "$TMP" -d "$ANDROID_HOME/cmdline-tools" || die "解压 cmdline-tools 失败"
  run bash -c "mv '$ANDROID_HOME/cmdline-tools/cmdline-tools'/* '$ANDROID_HOME/cmdline-tools/latest/' 2>/dev/null; rm -rf '$ANDROID_HOME/cmdline-tools/cmdline-tools'"
  if [[ -n "$CT_DIR" ]]; then rm -rf "$CT_DIR"; fi
  # dry-run 下什么都没装，原来这里的结构检查会必然 die
  if [[ $DRY_RUN -eq 1 ]]; then info "[dry-run] 跳过 sdkmanager 目录结构检查"
  elif [[ -x "$SDKMANAGER_BIN/sdkmanager" ]]; then ok "cmdline-tools 安装完成"
  else die "cmdline-tools 目录结构异常，未找到 $SDKMANAGER_BIN/sdkmanager"; fi
fi
export ANDROID_HOME
# JAVA_HOME 探测不到时别导出空串；用 export -n 去掉导出属性但保留变量（unset 会让后面 set -u 下的 "$JAVA_HOME" 直接炸）
if [[ -n "$JAVA_HOME" ]]; then export JAVA_HOME; else export -n JAVA_HOME; fi
export PATH="$SDKMANAGER_BIN:$ANDROID_HOME/platform-tools:$PATH"
run bash -c "yes 2>/dev/null | sdkmanager --licenses >/dev/null 2>&1 || true"
run sdkmanager --install "platform-tools" >/dev/null 2>&1 || warn "platform-tools 异常"
for p in $ANDROID_PLATFORMS; do
  if run sdkmanager --install "platforms;$p" >/dev/null 2>&1; then info "已装 platforms;$p"; else warn "platforms;$p 失败"; fi
done
for b in $ANDROID_BUILD_TOOLS; do
  if run sdkmanager --install "build-tools;$b" >/dev/null 2>&1; then info "已装 build-tools;$b"; else warn "build-tools;$b 失败"; fi
done
# SDK 37 的目录叫 platforms/android-37.0，AGP 9.1 却按 android-37 查，报 "Failed to find target with hash string 'android-37'"
# 补一个符号链接；已存在（含上次建的）就跳过，装失败时不留悬空链接
for p in $ANDROID_PLATFORMS; do
  if [[ "$p" =~ ^(android-[0-9]+)\.0$ ]]; then
    short="${BASH_REMATCH[1]}"; link="$ANDROID_HOME/platforms/$short"
    if [[ -e "$link" || -L "$link" ]]; then info "platforms/$short 已存在，跳过"
    elif [[ $DRY_RUN -eq 1 || -d "$ANDROID_HOME/platforms/$p" ]]; then
      if run ln -s "$p" "$link"; then info "已建符号链接 platforms/$short -> $p"; else warn "符号链接 platforms/$short 创建失败"; fi
    else warn "platforms/$p 不存在，未建符号链接"; fi
  fi
done
ok "Android SDK 就绪"

RULE="/etc/udev/rules.d/51-android.rules"
if [[ ! -f "$RULE" ]]; then
  sudo_write "$RULE" 'SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", MODE="0666", GROUP="plugdev"'
  run sudo udevadm control --reload-rules 2>/dev/null || true
  if ! getent group plugdev >/dev/null 2>&1; then run sudo groupadd -r plugdev 2>/dev/null || true; fi
  run sudo usermod -aG plugdev "$(id -un)" 2>/dev/null || true   # $USER 在 cron/容器里可能未设置，set -u 下会直接炸
  ok "adb udev 规则已装（注销后生效）"
fi

step "6/8 写入环境变量 → $RC_FILE"
run mkdir -p "$(dirname "$RC_FILE")"   # fish 的 ~/.config/fish 可能还不存在，touch 会直接失败
run touch "$RC_FILE"
if grep -qF "$MARK_BEGIN" "$RC_FILE" 2>/dev/null; then
  run sed -i "\|^${MARK_BEGIN}|,\|^${MARK_END}|d" "$RC_FILE" || true
  info "已移除旧配置块（幂等）"
fi
write_block(){
  {
    echo "$MARK_BEGIN"
    if [[ "$RC_SYNTAX" == "fish" ]]; then
      echo "set -gx FLUTTER_HOME \"$FLUTTER_HOME\""
      echo "set -gx ANDROID_HOME \"$ANDROID_HOME\""
      # ★ 没有 JAVA_HOME 时不再写空串
      [[ -n "$JAVA_HOME" ]] && echo "set -gx JAVA_HOME \"$JAVA_HOME\""
      for pp in "$FLUTTER_HOME/bin" "$ANDROID_HOME/cmdline-tools/latest/bin" "$ANDROID_HOME/platform-tools" "$ANDROID_HOME/emulator" "$HOME/.pub-cache/bin"; do
        echo "fish_add_path \"$pp\""; done
      if [[ $USE_MIRROR -eq 1 ]]; then
        echo "set -gx PUB_HOSTED_URL https://pub.flutter-io.cn"
        echo "set -gx FLUTTER_STORAGE_BASE_URL https://storage.flutter-io.cn"
      fi
    else
      echo "export FLUTTER_HOME=\"$FLUTTER_HOME\""
      echo "export ANDROID_HOME=\"$ANDROID_HOME\""
      [[ -n "$JAVA_HOME" ]] && echo "export JAVA_HOME=\"$JAVA_HOME\""
      echo "export PATH=\"\$FLUTTER_HOME/bin:\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/emulator:\$HOME/.pub-cache/bin:\$PATH\""
      if [[ $USE_MIRROR -eq 1 ]]; then
        echo "export PUB_HOSTED_URL=\"https://pub.flutter-io.cn\""
        echo "export FLUTTER_STORAGE_BASE_URL=\"https://storage.flutter-io.cn\""
      fi
    fi
    echo "$MARK_END"; echo ""
  } >> "$RC_FILE"
}
if run write_block; then ok "已写入（带幂等标记块，卸载时可精确定位）"; else die "写入 $RC_FILE 失败"; fi

# 写 manifest —— 让将来的卸载能精确知道本脚本装过什么
# 追加去重而不是整体覆盖：重跑不会丢掉之前 --with-esp-idf 记下的条目
for k in ${MANIFEST_PKGS[@]+"${MANIFEST_PKGS[@]}"}; do manifest_add PKG "$k"; done
manifest_add PATH "$FLUTTER_HOME"
manifest_add PATH "$ANDROID_HOME"
manifest_add PATH "$HOME/.pub-cache"
manifest_add RC "$RC_FILE"
manifest_add UDEV "$RULE"
if [[ $DRY_RUN -eq 0 ]]; then ok "已写入 manifest: $MANIFEST（卸载时用于精确识别）"; fi

step "7/8 初始化 Flutter"
export FLUTTER_HOME ANDROID_HOME
[[ -n "$JAVA_HOME" ]] && export JAVA_HOME
export PATH="$FLUTTER_HOME/bin:$PATH"
# --add 每次都追加一行，重跑会堆出重复项；先查再加才算幂等
if ! git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$FLUTTER_HOME"; then
  run git config --global --add safe.directory "$FLUTTER_HOME" 2>/dev/null || true
fi
# App 只做 Android：关掉 Linux 桌面，flutter doctor 也就不会再抱怨没装 clang / gtk 之类的 Linux 工具链
run flutter config --no-enable-linux-desktop >/dev/null 2>&1 || true
run flutter config --no-analytics >/dev/null 2>&1 || true
info "预缓存引擎（首次 2-5 分钟）..."
run flutter precache --android >/dev/null 2>&1 || warn "precache 有告警，通常不影响"
ok "Flutter 初始化完成"

# Flutter 模板的 compileSdk 是 flutter.compileSdkVersion（3.47 里是 36），而 permission_handler / flutter_reactive_ble 要求 37；
# 不改的话 :app:checkDebugAarMetadata 直接失败（36 的 platform 默认也装了，但 App 自己的 compileSdk 必须不低于依赖要求的最高值）
patch_compile_sdk(){  # patch_compile_sdk <项目目录>
  local kts="$1/android/app/build.gradle.kts" props="$1/android/gradle.properties"
  if grep -q 'compileSdk = flutter\.compileSdkVersion' "$kts" 2>/dev/null; then
    sed -i "s/compileSdk = flutter\.compileSdkVersion/compileSdk = $COMPILE_SDK/" "$kts"
  elif ! grep -q "compileSdk = $COMPILE_SDK" "$kts" 2>/dev/null; then
    return 1
  fi
  # AGP 9.1.0 只推荐到 36；文件末尾没有换行时先补一个，免得和上一行粘在一起
  if [[ -s "$props" && -n "$(tail -c1 "$props")" ]]; then printf '\n' >> "$props"; fi
  if ! grep -qxF "android.suppressUnsupportedCompileSdk=$COMPILE_SDK" "$props" 2>/dev/null; then
    printf 'android.suppressUnsupportedCompileSdk=%s\n' "$COMPILE_SDK" >> "$props"
  fi
}

pub_add_deps(){  # pub_add_deps <项目目录>
  ( cd "$1" && flutter pub add $FLUTTER_PACKAGES && flutter pub add --dev $FLUTTER_DEV_PACKAGES \
      && { [[ -z "$FLUTTER_SDK_PACKAGES" ]] || flutter pub add $FLUTTER_SDK_PACKAGES --sdk=flutter; } )
}

if [[ $CREATE_PROJECT -eq 1 ]]; then
  step "8/8 创建项目骨架: $PROJECT_NAME"
  run mkdir -p "$(dirname "$PROJECT_DIR")"
  if [[ -d "$PROJECT_DIR" ]]; then warn "已存在，跳过: $PROJECT_DIR"
  else
    if run flutter create --org com.lab --project-name "$PROJECT_NAME" --platforms=android "$PROJECT_DIR"; then
      # ★ 修复：原来子 shell 失败会直接冒泡 set -e，整个部署被中断
      #   dry-run 下项目目录并不存在，cd 必败 → 会错误地报"pub add 失败"，所以单独走预览分支
      if [[ $DRY_RUN -eq 1 ]]; then
        run flutter pub add $FLUTTER_PACKAGES
        run flutter pub add --dev $FLUTTER_DEV_PACKAGES
        if [[ -n "$FLUTTER_SDK_PACKAGES" ]]; then run flutter pub add $FLUTTER_SDK_PACKAGES --sdk=flutter; fi
        info "[dry-run] android/app/build.gradle.kts: compileSdk = $COMPILE_SDK；android/gradle.properties: android.suppressUnsupportedCompileSdk=$COMPILE_SDK"
      else
        # 与 pub add 是否成功无关，先改：这是项目能用已装的 SDK 37 编译的前提
        if patch_compile_sdk "$PROJECT_DIR"; then ok "compileSdk 已改为 $COMPILE_SDK（android/app/build.gradle.kts）"
        else warn "没找到 compileSdk = flutter.compileSdkVersion，请手动把 android/app/build.gradle.kts 的 compileSdk 改成 $COMPILE_SDK"; fi
        if pub_add_deps "$PROJECT_DIR"; then
          ok "项目已创建"
        # 国内镜像偶尔对个别包返回 525（实测 win32、ffi_leak_tracker 的压缩包），换官方源重试一次
        elif [[ "${PUB_HOSTED_URL:-}" != "https://pub.dev" ]] \
             && { warn "pub add 失败，改用 https://pub.dev 重试一次"; PUB_HOSTED_URL=https://pub.dev pub_add_deps "$PROJECT_DIR"; }; then
          ok "项目已创建（依赖改从 pub.dev 拉取）"
        else
          warn "项目骨架已创建，但 pub add 失败 —— 请在项目目录重跑 flutter pub get（通常是网络问题）"
        fi
      fi
    else
      warn "flutter create 失败"
    fi
  fi
else step "8/8 跳过项目创建（--create-project 可启用）"; fi

if [[ $WITH_ESP_IDF -eq 1 ]]; then
  step "[可选] 安装 ESP-IDF $ESP_IDF_VERSION"
  run mkdir -p "$(dirname "$IDF_HOME")"
  if [[ -d "$IDF_HOME/.git" ]]; then ok "已存在: $IDF_HOME"
  else
    run git clone -b "$ESP_IDF_VERSION" --recursive --depth 1 https://github.com/espressif/esp-idf.git "$IDF_HOME" \
      || run git clone -b "$ESP_IDF_VERSION" --recursive https://github.com/espressif/esp-idf.git "$IDF_HOME" \
      || warn "ESP-IDF 克隆失败，可稍后手动重试"
    # 只有这次是本脚本克隆的才登记，别把用户原有的 ESP-IDF 当成"本脚本产物"（会被当 AUTO 直接删）
    if [[ -d "$IDF_HOME/.git" ]]; then manifest_add PATH "$IDF_HOME"; fi
  fi
  if [[ -d "$IDF_HOME/.git" ]]; then
    if ! command -v direnv >/dev/null 2>&1; then
      # 原来的 MANIFEST_PKGS+=(direnv) 发生在 manifest 写完之后，是死代码；直接登记
      if run pkg_install direnv; then manifest_add PKG direnv; else warn "direnv 安装失败"; fi
    fi
    # hook 与"这次是不是刚装的 direnv"无关：原来机器上已有 direnv 但 rc 里没 hook 时，整段都被跳过
    case "$RC_SYNTAX" in
      bash) grep -q 'direnv hook bash' "$RC_FILE" 2>/dev/null || run bash -c "echo 'eval \"\$(direnv hook bash)\"' >> '$RC_FILE'" ;;
      zsh)  grep -q 'direnv hook zsh'  "$RC_FILE" 2>/dev/null || run bash -c "echo 'eval \"\$(direnv hook zsh)\"'  >> '$RC_FILE'" ;;
      fish) grep -q 'direnv hook fish' "$RC_FILE" 2>/dev/null || run bash -c "echo 'direnv hook fish | source'   >> '$RC_FILE'" ;;
    esac
    run bash -c "echo 'source ./export.sh' > '$IDF_HOME/.envrc'"
    # 不 allow 的话 direnv 会拒绝加载 .envrc，"cd 进目录自动生效"就落空了
    if command -v direnv >/dev/null 2>&1; then
      run direnv allow "$IDF_HOME" || warn "direnv allow 失败，请手动执行: direnv allow $IDF_HOME"
    fi
    if run bash -c "cd '$IDF_HOME' && chmod +x install.sh && ./install.sh esp32s3" >/dev/null 2>&1; then
      ok "ESP-IDF 工具链已装（cd 进目录后 direnv 自动生效）"
    else
      warn "install.sh 异常，请手动 cd $IDF_HOME && ./install.sh esp32s3"
    fi
  fi
fi

step "验证: flutter doctor -v"
export PATH="$FLUTTER_HOME/bin:$PATH"
if [[ $DRY_RUN -eq 1 ]]; then
  info "[dry-run] flutter doctor -v"
else
  if ! command -v flutter >/dev/null 2>&1; then
    warn "flutter 不在 PATH（是否还没 exec \$SHELL 重载 rc？）"
  else
    flutter doctor -v 2>&1 | sed 's/^/    /' || true
  fi
fi
cat <<EOF

${G}${B}════════════════════════════════════════════════════════════${N}
${G}${B} ✅ 环境部署完成${N}   ${PRETTY_NAME:-${ID}}

${B}立即生效：${N}  exec ${LOGIN_SHELL}
${B}验证：${N}      flutter doctor -v  /  flutter devices
${B}常用：${N}      cd app
            flutter run -t lib/main_sim.dart   # 无硬件模拟器版本（需连手机）
            flutter run -d <真机ID>            # 连真实滴定仪（BLE）
            flutter analyze && flutter test    # 提交前必跑
${B}卸载：${N}      $0 --uninstall --dry-run   # 先预览

${B}版本：${N} Flutter $FLUTTER_VERSION / JDK $JDK_VERSION ($JDK_PKG) / Android SDK @ $ANDROID_HOME
${G}${B}════════════════════════════════════════════════════════════${N}
EOF
