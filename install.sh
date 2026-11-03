#!/usr/bin/env bash
# loop-download 安装脚本
# 解决两个实际问题:
# 1. 国内服务器直连 raw.githubusercontent.com 常被重置 (curl 35 Connection reset by peer),
#    所以默认走 jsDelivr CDN, 失败再依次试其他镜像, 最后才试 raw。
# 2. 主流 Linux 发行版适配: Ubuntu / Debian / CentOS / RHEL / Rocky / AlmaLinux / Fedora,
#    amd64 / arm64, 缺 curl 时按发行版自动用 apt / dnf / yum 装。
# 用法 (分国内 / 国外, 装完都是一键呼出命令 loopdl):
#   国内: curl -fsSL https://cdn.jsdelivr.net/gh/emmaforge/loop-download@main/install.sh | bash
#   国外: curl -fsSL https://raw.githubusercontent.com/emmaforge/loop-download/main/install.sh | bash
#   装完呼出面板 (任意目录): loopdl
#   没装全局命令时, 在下载目录跑: ./loop_download.sh
#   本地已有 install.sh 时装完直接进面板: bash install.sh --run
set -u

REPO="emmaforge/loop-download"
FILE="loop_download.sh"
TARGET="./${FILE}"
GLOBAL_CMD="/usr/local/bin/loopdl"

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
# 顺序有讲究: jsDelivr 在国内一般能通, 放最前; raw 放最后, 因为它最容易被重置。
MIRRORS=(
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
  # 校验: 必须是真正的脚本, 不是代理返回的 HTML 错误页, 也不是空文件。
  # ghproxy 失败时常返回一个 2KB 的 HTML, 这一关正好把它拦下来。
  if [[ -s "$TMP_FILE" ]] && head -1 "$TMP_FILE" | grep -q "^#!/usr/bin/env bash" && grep -q "RATE_MBPS" "$TMP_FILE"; then
    echo "下载成功: $url ($(wc -c < "$TMP_FILE") 字节)"
    OK=1
    break
  else
    echo "  这个源不行 (空文件 / HTML / 被重置), 换下一个..."
  fi
done

if [[ -z "$OK" ]]; then
  echo "所有镜像都失败了, 可能原因: 服务器出站网络受限、DNS 异常。"
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
