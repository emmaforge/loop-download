#!/usr/bin/env bash
# 循环下载脚本 - 交互式面板
# 用途: 以固定速率循环下载大文件, 产生稳定的下行流量, 不占满带宽, 不占磁盘
# 原理: 每次下载都输出到 /dev/null, 下载完删不删都一样, 循环下一轮
# 适用: 任意直链, 包括官网的荣耀安装包 / 驱动 / 系统镜像等, 也支持自填链接
# 依赖: curl (优先) 或 wget, bash 4+
# 用法: chmod +x loop_download.sh && ./loop_download.sh

set -u

# ---------- 配置 ----------
PRESET_FILE="${HOME}/.config/loop_download/presets.txt"
mkdir -p "$(dirname "$PRESET_FILE")" 2>/dev/null || true

# 内置预设: 名字|链接
# 注意: 荣耀官网的下载链接经常带 token / 会过期, 不要硬编码一个会失效的链接。
# 正确做法: 去荣耀官网下载页, 右键下载按钮 -> 复制链接地址, 在菜单里选 [自填链接] 粘贴,
# 跑通一次后选 [保存为预设], 下次就能一键选它。
# 下面这几个是公开的大文件测速源, 仅作示例 / 备用, 你可以删掉换成自己的。
declare -a BUILTIN_PRESETS=(
  "Cloudflare测速100MB|https://speed.cloudflare.com/__down?bytes=104857600"
  "Cloudflare测速1GB|https://speed.cloudflare.com/__down?bytes=1073741824"
  "Ubuntu 24.04 ISO(约5.7GB)|https://releases.ubuntu.com/24.04/ubuntu-24.04.3-desktop-amd64.iso"
)

# 当前会话配置 (默认值)
SELECTED_NAME="未选择"
SELECTED_URL=""
RATE="2M"          # curl/wget 都认的格式: 100K / 500K / 1M / 2M / 5M / 10M
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
  echo "限速   : $RATE / 秒 (curl --limit-rate, 不占满带宽)"
  echo "循环   : $mode_text"
  echo "间隔   : 每轮间隔 ${INTERVAL} 秒"
  echo "落盘   : 不落盘, 直接输出到 /dev/null"
  echo "--------------------------------------------"
}

# 限速格式校验: 数字 + 可选 K/M, 如 500K 1M 2048K
valid_rate() {
  [[ "$1" =~ ^[0-9]+[KkMm]?$ ]]
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

# ---------- 设置限速 ----------
choose_rate() {
  while true; do
    clear
    echo "========== 选择固定速率 =========="
    echo "当前: $RATE / 秒"
    echo "  1) 100K / 秒  (最省, 挂机拉底量)"
    echo "  2) 500K / 秒"
    echo "  3) 1M   / 秒"
    echo "  4) 2M   / 秒  (推荐, 既有流量又不影响正常用网)"
    echo "  5) 5M   / 秒"
    echo "  6) 10M  / 秒"
    echo "  7) 不限速 (不推荐, 会占满带宽)"
    echo "  c) 自定义, 如 300K / 1536K / 3M"
    echo "  0) 返回"
    echo "=================================="
    read -rp "请选择: " ch
    case "$ch" in
      0) return ;;
      1) RATE="100K" ;;
      2) RATE="500K" ;;
      3) RATE="1M" ;;
      4) RATE="2M" ;;
      5) RATE="5M" ;;
      6) RATE="10M" ;;
      7) RATE="0" ;;
      c|C)
        read -rp "输入速率 (如 300K / 2M): " r
        if valid_rate "$r"; then RATE="$r"; else echo "格式不对, 如 500K 或 2M"; pause; continue; fi
        ;;
      *) echo "无效选择"; pause; continue ;;
    esac
    echo "已设为: $RATE / 秒"
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
    echo "[第 $round 轮] $(date '+%H:%M:%S') 开始, 限速 $RATE/s"
    echo "  链接: $SELECTED_URL"

    if has_cmd curl; then
      # -L 跟随跳转(官网链接常跳转到CDN), --limit-rate 固定速率
      # -o /dev/null 不落盘, -w 输出本轮下载字节数
      if [[ "$RATE" == "0" ]]; then
        round_size=$(curl -L -A "$UA" --connect-timeout 15 -o /dev/null -s -w "%{size_download}" "$SELECTED_URL" 2>/dev/null || echo 0)
      else
        round_size=$(curl -L -A "$UA" --limit-rate "$RATE" --connect-timeout 15 -o /dev/null -s -w "%{size_download}" "$SELECTED_URL" 2>/dev/null || echo 0)
      fi
    else
      # wget 备用: --limit-rate 后面要带单位, 0 表示不限
      local wrate="$RATE"
      [[ "$RATE" == "0" ]] && wrate="0"
      wget -q -O /dev/null --limit-rate="$wrate" --timeout=15 -U "$UA" "$SELECTED_URL" 2>/dev/null
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
if ! has_cmd curl && ! has_cmd wget; then
  echo "警告: 未检测到 curl/wget, 请先安装 curl 再运行。"
fi

while true; do
  clear
  echo "========== 循环下载面板 =========="
  show_config
  echo
  echo "  1) 选择下载源 (预设 / 自填链接)"
  echo "  2) 选择固定速率 (当前 $RATE/s)"
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
