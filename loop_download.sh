#!/usr/bin/env bash
# 循环下载脚本 - 交互式面板
# 用途: 以固定速率循环下载大文件, 产生稳定的下行流量, 不占满带宽, 不占磁盘
# 原理: 每次下载都输出到 /dev/null, 下载完删不删都一样, 循环下一轮
# 适用: 任意直链, 包括官网的荣耀安装包 / 驱动 / 系统镜像等, 也支持自填链接
# 依赖: curl (优先) 或 wget, bash 4+, awk (Debian 默认的 mawk 也行)
# 支持: 主流 Linux 发行版 Ubuntu / Debian / CentOS / RHEL / Rocky / AlmaLinux / Fedora, amd64/arm64
# 用法: chmod +x loop_download.sh && ./loop_download.sh
# 一键呼出 (用 install.sh 装过后, 任意目录都行): loopdl
# 注意: 国内服务器不要用 raw.githubusercontent.com 下载本脚本, 容易被重置, 用 install.sh 或 jsDelivr (见 README)。

set -u

# ---------- 配置 ----------
PRESET_FILE="${HOME}/.config/loop_download/presets.txt"
mkdir -p "$(dirname "$PRESET_FILE")" 2>/dev/null || true

# 内置预设: 名字|链接
# 注意: 荣耀官网的下载链接经常带 token / 会过期, 不要硬编码一个会失效的链接。
# 正确做法: 去荣耀官网下载页, 右键下载按钮 -> 复制链接地址, 在菜单里选 [自填链接] 粘贴,
# 跑通一次后选 [保存为预设], 下次就能一键选它。
# 下面这些是长期可用的大文件, 国内的放前面, 国外的放后面, 你可以删掉换成自己的。
# 国内预设都实测过 (Range 请求返回 206): 清华 / 华为云 / 网易的 Ubuntu LTS ISO,
# 都是镜像站长期保留的版本, 不是会天天变的临时链接。阿里云、USTC、中科大腾讯这几个
# 在境外实测分别返回 302 跳 http 失败 / 403 / 567, 没放进来, 免得在国内以外跑不通。
# 国外预设保留 Cloudflare 测速和 Ubuntu 官网, 给国外机器用。
declare -a BUILTIN_PRESETS=(
  "国内-清华 Ubuntu 24.04.5.1 ISO(约6.25GB)|https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/24.04/ubuntu-24.04.5.1-desktop-amd64.iso"
  "国内-华为云 Ubuntu 24.04.5.1 ISO(约6.25GB)|https://mirrors.huaweicloud.com/ubuntu-releases/24.04/ubuntu-24.04.5.1-desktop-amd64.iso"
  "国内-网易 Ubuntu 24.04.5.1 ISO(约6.25GB)|https://mirrors.163.com/ubuntu-releases/24.04/ubuntu-24.04.5.1-desktop-amd64.iso"
  "国内-清华 Ubuntu 22.04.5 ISO(约4.76GB)|https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/22.04/ubuntu-22.04.5-desktop-amd64.iso"
  "国外-Cloudflare测速100MB|https://speed.cloudflare.com/__down?bytes=104857600"
  "国外-Cloudflare测速1GB|https://speed.cloudflare.com/__down?bytes=1073741824"
  "国外-Ubuntu官网 24.04 ISO|https://releases.ubuntu.com/24.04/ubuntu-24.04.3-desktop-amd64.iso"
)

# 当前会话配置 (默认值)
# 速率单位: Mbps (兆比特/秒), 跟宽带测速、面板带宽口径一致, 好换算。
# curl/wget 的 --limit-rate 按字节/秒算, 所以内部换算: 1 Mbps = 125000 字节/秒。
# 默认 16 Mbps = 2 MB/s, 等于改版前的默认 2M, 速度不变, 只是单位换了。
SELECTED_NAME="未选择"
SELECTED_URL=""
RATE_MBPS="16"
LOOP_MODE="infinite" # infinite | count | minutes
LOOP_COUNT=0       # count 模式用
LOOP_MINUTES=60    # minutes 模式用
INTERVAL=3         # 每轮间隔秒数, 别设 0, 给服务器喘口气, 也避免被限流
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

# ---------- 工具函数 ----------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

pause() { echo; read -rp "按回车返回菜单..." _; }

# 读取全部预设到数组 PRESETS, 格式 名字|链接
load_presets() {
  PRESETS=()
  for p in "${BUILTIN_PRESETS[@]}"; do PRESETS+=("$p"); done
  if [[ -f "$PRESET_FILE" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "$line" == \#* ]] && continue
      PRESETS+=("$line")
    done < "$PRESET_FILE"
  fi
}

show_config() {
  local mode_text=""
  case "$LOOP_MODE" in
    infinite) mode_text="无限循环 (Ctrl+C 停止)";;
    count)    mode_text="固定 ${LOOP_COUNT} 轮";;
    minutes)  mode_text="持续 ${LOOP_MINUTES} 分钟";;
  esac
  echo "---------------- 当前配置 ----------------"
  echo "下载源 : $SELECTED_NAME"
  [[ -n "$SELECTED_URL" ]] && echo "链接   : $SELECTED_URL"
  if [[ "$RATE_MBPS" == "0" ]]; then
    echo "限速   : 不限速 (不推荐, 会占满带宽)"
  else
    echo "限速   : ${RATE_MBPS} Mbps (约 $(awk -v m="$RATE_MBPS" 'BEGIN{printf "%g", m/8}') MB/s, curl/wget 内部换算为字节/秒)"
  fi
  echo "循环   : $mode_text"
  echo "间隔   : 每轮间隔 ${INTERVAL} 秒"
  echo "落盘   : 不落盘, 直接输出到 /dev/null"
  echo "--------------------------------------------"
}

# 限速格式校验: Mbps, 整数或小数, 如 2 / 2.5 / 16 / 100
valid_mbps() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

# Mbps -> curl/wget 用的字节/秒: 1 Mbps = 1000000 bit/s / 8 = 125000 Byte/s
mbps_to_bytes() {
  awk -v m="$1" 'BEGIN{printf "%.0f", m*125000}'
}

# ---------- 预设管理 ----------
manage_presets() {
  while true; do
    clear
    echo "========== 预设链接管理 =========="
    load_presets
    local i=1
    for p in "${PRESETS[@]}"; do
      echo "  $i) ${p%%|*}"
      echo "     ${p#*|}"
      i=$((i+1))
    done
    echo "----------------------------------"
    echo "  a) 添加一个预设 (自填链接保存下来)"
    echo "  d) 删除一个自定义预设"
    echo "  0) 返回主菜单"
    echo "=================================="
    echo "自定义预设存在: $PRESET_FILE"
    read -rp "请选择 [0/a/d/编号查看]: " ch
    case "$ch" in
      0) return ;;
      a|A)
        read -rp "预设名字 (如: 荣耀MagicOS安装包): " pname
        read -rp "下载链接 (直链, 以 http 开头): " purl
        [[ -z "$pname" || -z "$purl" ]] && { echo "名字和链接都不能为空"; pause; continue; }
        echo "${pname}|${purl}" >> "$PRESET_FILE"
        echo "已保存, 下次在主菜单选下载源里就能看到。"
        pause
        ;;
      d|D)
        if [[ ! -f "$PRESET_FILE" ]] || [[ ! -s "$PRESET_FILE" ]]; then
          echo "还没有自定义预设可删。"; pause; continue
        fi
        echo "自定义预设:"
        nl -w2 -s') ' "$PRESET_FILE"
        read -rp "输入要删除的行号 (0取消): " del
        [[ "$del" == "0" || -z "$del" ]] && continue
        sed -i "${del}d" "$PRESET_FILE" 2>/dev/null || sed -i '' "${del}d" "$PRESET_FILE"
        echo "已删除。"
        pause
        ;;
      *) echo "无效选择"; pause ;;
    esac
  done
}

# ---------- 选择下载源 ----------
choose_source() {
  load_presets
  while true; do
    clear
    echo "========== 选择下载源 =========="
    local i=1
    for p in "${PRESETS[@]}"; do
      echo "  $i) ${p%%|*}"
      i=$((i+1))
    done
    echo "  c) 自填链接 (任意直链, 包括荣耀官网安装包)"
    echo "  0) 返回"
    echo "=================================="
    read -rp "请选择: " ch
    case "$ch" in
      0) return ;;
      c|C)
        echo "提示: 去官网下载页右键复制链接地址, 在这里粘贴 (Ctrl+Shift+V) 即可。"
        read -rp "请输入下载链接: " url
        [[ -z "$url" ]] && { echo "链接不能为空"; pause; continue; }
        SELECTED_URL="$url"
        SELECTED_NAME="自定义链接"
        echo "已选: $url"
        read -rp "是否保存为预设, 下次一键选? [y/N]: " save
        if [[ "$save" == "y" || "$save" == "Y" ]]; then
          read -rp "给它起个名字: " pname
          [[ -n "$pname" ]] && echo "${pname}|${url}" >> "$PRESET_FILE" && echo "已保存到预设。"
        fi
        pause; return ;;
      *)
        if [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#PRESETS[@]} )); then
          local sel="${PRESETS[$((ch-1))]}"
          SELECTED_NAME="${sel%%|*}"
          SELECTED_URL="${sel#*|}"
          echo "已选: $SELECTED_NAME"
          pause; return
        else
          echo "无效选择"; pause
        fi
        ;;
    esac
  done
}

# ---------- 设置限速 (单位 Mbps) ----------
choose_rate() {
  while true; do
    clear
    echo "========== 选择固定速率 (Mbps) =========="
    if [[ "$RATE_MBPS" == "0" ]]; then echo "当前: 不限速"; else echo "当前: ${RATE_MBPS} Mbps (约 $(awk -v m="$RATE_MBPS" 'BEGIN{printf "%g", m/8}') MB/s)"; fi
    echo "  1) 2 Mbps   (最省, 挂机拉底量, 约 0.25 MB/s)"
    echo "  2) 5 Mbps   (约 0.625 MB/s)"
    echo "  3) 10 Mbps  (约 1.25 MB/s)"
    echo "  4) 16 Mbps  (推荐, 约 2 MB/s, 等于旧默认 2M)"
    echo "  5) 20 Mbps  (约 2.5 MB/s)"
    echo "  6) 50 Mbps  (约 6.25 MB/s)"
    echo "  7) 100 Mbps (约 12.5 MB/s)"
    echo "  8) 不限速 (不推荐, 会占满带宽)"
    echo "  c) 自定义, 如 2.5 / 30, 单位就是 Mbps"
    echo "  0) 返回"
    echo "=========================================="
    read -rp "请选择: " ch
    case "$ch" in
      0) return ;;
      1) RATE_MBPS="2" ;;
      2) RATE_MBPS="5" ;;
      3) RATE_MBPS="10" ;;
      4) RATE_MBPS="16" ;;
      5) RATE_MBPS="20" ;;
      6) RATE_MBPS="50" ;;
      7) RATE_MBPS="100" ;;
      8) RATE_MBPS="0" ;;
      c|C)
        read -rp "输入速率, 单位 Mbps (如 2.5 / 30): " r
        if valid_mbps "$r"; then RATE_MBPS="$r"; else echo "格式不对, 只要数字, 如 2.5"; pause; continue; fi
        ;;
      *) echo "无效选择"; pause; continue ;;
    esac
    if [[ "$RATE_MBPS" == "0" ]]; then echo "已设为: 不限速"; else echo "已设为: ${RATE_MBPS} Mbps (约 $(awk -v m="$RATE_MBPS" 'BEGIN{printf "%g", m/8}') MB/s)"; fi
    pause; return
  done
}

# ---------- 设置循环模式 ----------
choose_loop() {
  while true; do
    clear
    echo "========== 循环模式 =========="
    echo "  1) 无限循环, 直到 Ctrl+C 停止"
    echo "  2) 固定轮数"
    echo "  3) 固定时长 (分钟)"
    echo "  4) 设置每轮间隔 (当前 ${INTERVAL} 秒)"
    echo "  0) 返回"
    echo "=============================="
    read -rp "请选择: " ch
    case "$ch" in
      0) return ;;
      1) LOOP_MODE="infinite"; echo "已设: 无限循环"; pause; return ;;
      2)
        read -rp "跑几轮? (如 10): " n
        [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) && { LOOP_MODE="count"; LOOP_COUNT="$n"; echo "已设: $n 轮"; } || echo "请输入正整数"
        pause; return ;;
      3)
        read -rp "跑多少分钟? (如 60): " m
        [[ "$m" =~ ^[0-9]+$ ]] && (( m > 0 )) && { LOOP_MODE="minutes"; LOOP_MINUTES="$m"; echo "已设: $m 分钟"; } || echo "请输入正整数"
        pause; return ;;
      4)
        read -rp "每轮间隔秒数 (建议 2-10, 当前 $INTERVAL): " s
        [[ "$s" =~ ^[0-9]+$ ]] && { INTERVAL="$s"; echo "已设: ${s} 秒"; } || echo "请输入整数"
        pause; return ;;
      *) echo "无效选择"; pause ;;
    esac
  done
}

# ---------- 开始下载 ----------
run_loop() {
  if [[ -z "$SELECTED_URL" ]]; then
    echo "先选一个下载源 (菜单 1)。"
    pause; return
  fi
  if ! has_cmd curl && ! has_cmd wget; then
    echo "没找到 curl 或 wget, 先装一个: sudo apt install curl / yum install curl"
    pause; return
  fi

  clear
  show_config
  echo
  echo "按 Ctrl+C 随时停止, 会打印本轮汇总。"
  echo "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=================================="

  # Mbps 换算一次, 后面每轮直接用字节/秒, 避免每轮重复算
  local limit_bytes=""
  if [[ "$RATE_MBPS" != "0" ]]; then
    limit_bytes=$(mbps_to_bytes "$RATE_MBPS")
  fi

  local round=0 total_bytes=0 start_ts end_ts
  start_ts=$(date +%s)
  end_ts=$((start_ts + LOOP_MINUTES * 60))

  # Ctrl+C 时优雅退出
  trap 'echo; echo "--- 已手动停止 ---"; echo "共跑 $round 轮, 累计约 $((total_bytes/1024/1024)) MB"; trap - INT; return 0' INT

  while true; do
    round=$((round+1))
    # 固定轮数 / 固定时长 的退出条件
    if [[ "$LOOP_MODE" == "count" ]] && (( round > LOOP_COUNT )); then break; fi
    if [[ "$LOOP_MODE" == "minutes" ]] && (( $(date +%s) >= end_ts )); then break; fi

    local round_start round_size
    round_start=$(date +%s)
    if [[ "$RATE_MBPS" == "0" ]]; then
      echo "[第 $round 轮] $(date '+%H:%M:%S') 开始, 不限速"
    else
      echo "[第 $round 轮] $(date '+%H:%M:%S') 开始, 限速 ${RATE_MBPS} Mbps"
    fi
    echo "  链接: $SELECTED_URL"

    if has_cmd curl; then
      # -L 跟随跳转(官网链接常跳转到CDN), --limit-rate 按字节/秒, 已由 Mbps 换算好
      # -o /dev/null 不落盘, -w 输出本轮下载字节数
      if [[ "$RATE_MBPS" == "0" ]]; then
        round_size=$(curl -L -A "$UA" --connect-timeout 15 -o /dev/null -s -w "%{size_download}" "$SELECTED_URL" 2>/dev/null || echo 0)
      else
        round_size=$(curl -L -A "$UA" --limit-rate "$limit_bytes" --connect-timeout 15 -o /dev/null -s -w "%{size_download}" "$SELECTED_URL" 2>/dev/null || echo 0)
      fi
    else
      # wget 备用: --limit-rate 按字节/秒, 0 表示不限
      if [[ "$RATE_MBPS" == "0" ]]; then
        wget -q -O /dev/null --timeout=15 -U "$UA" "$SELECTED_URL" 2>/dev/null
      else
        wget -q -O /dev/null --limit-rate="$limit_bytes" --timeout=15 -U "$UA" "$SELECTED_URL" 2>/dev/null
      fi
      round_size=0  # wget 不方便直接取字节数, 本轮计 0, 只看轮数
    fi
    [[ -z "$round_size" ]] && round_size=0
    # 防止非数字
    [[ "$round_size" =~ ^[0-9]+$ ]] || round_size=0
    total_bytes=$((total_bytes + round_size))
    local round_elapsed=$(( $(date +%s) - round_start ))
    echo "  本轮完成: 约 $((round_size/1024/1024)) MB, 用时 ${round_elapsed}s, 累计约 $((total_bytes/1024/1024)) MB"
    echo

    if [[ "$LOOP_MODE" == "count" ]] && (( round >= LOOP_COUNT )); then break; fi
    if [[ "$LOOP_MODE" == "minutes" ]] && (( $(date +%s) >= end_ts )); then break; fi

    echo "  间隔 ${INTERVAL}s 后开始下一轮..."
    sleep "$INTERVAL"
  done

  trap - INT
  echo "=================================="
  echo "结束: 共 $round 轮, 累计约 $((total_bytes/1024/1024)) MB, 总用时 $(( ($(date +%s)-start_ts)/60 )) 分钟"
  pause
}

# ---------- 主菜单 ----------
# 主流发行版缺 curl 时的安装提示: Ubuntu/Debian 用 apt, RHEL 系用 dnf/yum。
if ! has_cmd curl && ! has_cmd wget; then
  echo "警告: 未检测到 curl/wget, 请先安装 curl 再运行。"
  if has_cmd apt-get; then
    echo "  Ubuntu/Debian: sudo apt update && sudo apt install -y curl"
  elif has_cmd dnf; then
    echo "  RHEL/Rocky/AlmaLinux/Fedora: sudo dnf install -y curl"
  elif has_cmd yum; then
    echo "  CentOS/RHEL(老版): sudo yum install -y curl"
  else
    echo "  请用你发行版的包管理器安装 curl。"
  fi
  echo "  或者直接用安装脚本, 它会自动装 curl 并走镜像下载: 见 README 快速开始。"
fi

while true; do
  clear
  echo "========== 循环下载面板 =========="
  show_config
  echo
  echo "  1) 选择下载源 (预设 / 自填链接)"
  if [[ "$RATE_MBPS" == "0" ]]; then
    echo "  2) 选择固定速率 (当前 不限速)"
  else
    echo "  2) 选择固定速率 (当前 ${RATE_MBPS} Mbps)"
  fi
  echo "  3) 设置循环模式 / 间隔"
  echo "  4) 开始下载"
  echo "  5) 管理预设链接"
  echo "  0) 退出"
  echo "=================================="
  read -rp "请选择 [0-5]: " choice
  case "$choice" in
    1) choose_source ;;
    2) choose_rate ;;
    3) choose_loop ;;
    4) run_loop ;;
    5) manage_presets ;;
    0) echo "退出, 再见。"; exit 0 ;;
    *) echo "无效选择"; pause ;;
  esac
done
