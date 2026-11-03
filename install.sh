#!/usr/bin/env bash
# loop-download 安装脚本
# 解决两个实际问题:
# 1. 国内服务器直连 raw.githubusercontent.com 常被重置 (curl 35 Connection reset by peer),
#    所以默认走 jsDelivr CDN, 失败再依次试其他镜像, 最后才试 raw。
# 2. 主流 Linux 发行版适配: Ubuntu / Debian / CentOS / RHEL / Rocky / AlmaLinux / Fedora,
#    amd64 / arm64, 缺 curl 时按发行版自动用 apt / dnf / yum 装。
# 用法 (分国内 / 国外, 装完都是一键呼出命令 loopdl):
#   国内: curl -fsSL https://cdn.jsdelivr.net/gh/emmaforge/loop-download@v1.5.2/install.sh | bash
#         (必须用 @v1.5.2 这种 tag 版, @main 的 jsDelivr 缓存还是旧版, 装完会没有菜单 6 / 国内预设)
#   国外: curl -fsSL https://raw.githubusercontent.com/emmaforge/loop-download/main/install.sh | bash
#   装完呼出面板 (任意目录): loopdl
#   没装全局命令时, 在下载目录跑: ./loop_download.sh
#   本地已有 install.sh 时装完直接进面板: bash install.sh --run
set -u

REPO="emmaforge/loop-download"
FILE="loop_download.sh"
TARGET="./${FILE}"
GLOBAL_CMD="/usr/local/bin/loopdl"
# 期望的脚本版本, 必须跟 loop_download.sh 里的 LOOPDL_VERSION 一致, 改脚本时同步改。
# 用途: jsDelivr @main 缓存经常还是旧版, 旧版也有 RATE_MBPS, 光查那个拦不住。
# 现在要求下载到的文件必须带这个版本号, 旧版缓存会被跳过, 继续试下一个镜像 (最后是 raw, 国外能直连 raw 就一定能拿到新版)。
# 另外: jsDelivr @vX.Y.Z 这种带 tag 的路径是新路径, 第一次请求就从 GitHub 现取, 不会命中 @main 的旧缓存,
# 所以国内安装命令要用 @v1.5.2 这种 tag 版 install.sh, 并且下面镜像列表先试 @v1.5.2, 国内不用 raw 也能拿到新版。
EXPECTED_VERSION="1.5.2"

# ---------- 系统检测 (主流发行版) ----------
OS_ID="unknown"; OS_NAME="unknown"; ARCH="$(uname -m 2>/dev/null || echo unknown)"
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"; OS_NAME="${PRETTY_NAME:-$OS_ID}"
fi
echo "系统: $OS_NAME, 架构: $ARCH"
case "$OS_ID" in
  ubuntu|debian|centos|rhel|rocky|almalinux|fedora)
    echo "发行版: $OS_ID (主流支持范围)"
    ;;
  *)
    echo "注意: $OS_ID 不在主流支持清单里 (Ubuntu/Debian/CentOS/RHEL/Rocky/AlmaLinux/Fedora), 仍尽力继续, 出问题按上面命令手动装 curl 即可。"
    ;;
esac
case "$ARCH" in
  x86_64|aarch64|arm64) ;;
  *) echo "注意: 架构 $ARCH 不是常见的 amd64/arm64, 脚本本身是纯 bash, 一般仍可跑。" ;;
esac

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------- 缺 curl/wget 时按发行版安装 ----------
if ! has_cmd curl && ! has_cmd wget; then
  echo "未检测到 curl/wget, 尝试按发行版自动安装 curl..."
  SUDO=""
  [[ "$(id -u 2>/dev/null || echo 1)" != "0" ]] && has_cmd sudo && SUDO="sudo"
  if has_cmd apt-get; then
    $SUDO apt-get update && $SUDO apt-get install -y curl
  elif has_cmd dnf; then
    $SUDO dnf install -y curl
  elif has_cmd yum; then
    $SUDO yum install -y curl
  elif has_cmd apk; then
    $SUDO apk add curl
  else
    echo "找不到 apt/dnf/yum/apk, 请手动安装 curl 后再跑本脚本。"
    exit 1
  fi
  has_cmd curl || { echo "curl 安装失败, 请手动安装后重试。"; exit 1; }
fi

# ---------- 多镜像下载, 一个不行换下一个 ----------
# 顺序有讲究: 先试带 tag 的 jsDelivr (@v1.5.2 是新路径, 不命中 @main 旧缓存, 国内能通),
# 再试 @main 的 jsDelivr, 最后试 raw (raw 最容易被重置, 放最后, 国外能直连 raw 就一定能拿到新版)。
MIRRORS=(
  "https://cdn.jsdelivr.net/gh/${REPO}@v${EXPECTED_VERSION}/${FILE}"
  "https://fastly.jsdelivr.net/gh/${REPO}@v${EXPECTED_VERSION}/${FILE}"
  "https://gcore.jsdelivr.net/gh/${REPO}@v${EXPECTED_VERSION}/${FILE}"
  "https://cdn.jsdelivr.net/gh/${REPO}@main/${FILE}"
  "https://fastly.jsdelivr.net/gh/${REPO}@main/${FILE}"
  "https://gcore.jsdelivr.net/gh/${REPO}@main/${FILE}"
  "https://ghproxy.com/https://raw.githubusercontent.com/${REPO}/main/${FILE}"
  "https://raw.githubusercontent.com/${REPO}/main/${FILE}"
)

TMP_FILE="$(mktemp /tmp/loop_download.XXXXXX)"
trap 'rm -f "$TMP_FILE"' EXIT

OK=""
for url in "${MIRRORS[@]}"; do
  echo "尝试: $url"
  rm -f "$TMP_FILE"
  if has_cmd curl; then
    curl -fsSL --connect-timeout 15 --retry 1 -o "$TMP_FILE" "$url" 2>/dev/null || true
  else
    wget -q -O "$TMP_FILE" "$url" 2>/dev/null || true
  fi
  # 校验: 必须是真正的脚本, 不是代理返回的 HTML 错误页, 也不是空文件,
  # 而且版本必须等于 EXPECTED_VERSION, 否则就是 jsDelivr 缓存的旧版, 不能要。
  # ghproxy 失败时常返回一个 2KB 的 HTML, 这一关正好把它拦下来。
  if [[ -s "$TMP_FILE" ]] && head -1 "$TMP_FILE" | grep -q "^#!/usr/bin/env bash" && grep -q "LOOPDL_VERSION=\"${EXPECTED_VERSION}\"" "$TMP_FILE"; then
    echo "下载成功: $url ($(wc -c < "$TMP_FILE") 字节, 版本 $EXPECTED_VERSION)"
    OK=1
    break
  else
    if [[ -s "$TMP_FILE" ]] && grep -q "LOOPDL_VERSION=" "$TMP_FILE"; then
      echo "  这个源是旧版缓存 (版本不对, 要 $EXPECTED_VERSION), 跳过, 换下一个..."
    else
      echo "  这个源不行 (空文件 / HTML / 被重置 / 不是脚本), 换下一个..."
    fi
  fi
done

if [[ -z "$OK" ]]; then
  echo "所有镜像都失败了, 可能原因: 服务器出站网络受限、DNS 异常, 或者 jsDelivr 缓存还是旧版且 raw 又被重置 (国内常见)。"
  echo "  等几分钟让 jsDelivr 缓存刷新后再跑一次, 或者先用已有的旧版, 等新版缓存刷过来再重装。"
  echo "换个办法试试:"
  echo "  git clone https://github.com/${REPO}.git"
  echo "  cd loop-download && chmod +x loop_download.sh && ./loop_download.sh"
  exit 1
fi

cp "$TMP_FILE" "$TARGET"
chmod +x "$TARGET"
echo "已保存: $TARGET"

# ---------- 一键呼出命令 loopdl ----------
# 把脚本再拷一份到 /usr/local/bin/loopdl, 以后任意目录打 loopdl 就进面板,
# 不用每次 cd 到下载目录再 ./loop_download.sh。
# 名字定为 loopdl: loop-download 的缩写, 短、好打, 跟系统现有命令不撞名。
if cp "$TMP_FILE" "$GLOBAL_CMD" 2>/dev/null; then
  chmod +x "$GLOBAL_CMD"
  echo "一键命令已安装: loopdl (在任意目录输入 loopdl 即可呼出面板)"
elif has_cmd sudo && sudo cp "$TMP_FILE" "$GLOBAL_CMD" 2>/dev/null; then
  sudo chmod +x "$GLOBAL_CMD"
  echo "一键命令已安装: loopdl (在任意目录输入 loopdl 即可呼出面板)"
else
  echo "注意: 写不了 $GLOBAL_CMD (没权限且无 sudo), 一键命令没装上。"
  echo "  手动装: sudo cp $TARGET $GLOBAL_CMD && sudo chmod +x $GLOBAL_CMD"
  echo "  没装之前, 在下载目录用: ./$FILE"
fi
echo "呼出面板: loopdl"

if [[ "${1:-}" == "--run" ]]; then
  if [[ -x "$GLOBAL_CMD" ]]; then
    exec "$GLOBAL_CMD"
  else
    exec "./$FILE"
  fi
fi
