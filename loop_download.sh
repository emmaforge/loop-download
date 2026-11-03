#!/usr/bin/env bash
# 循环下载脚本 - 交互式面板
# 用途: 以固定速率循环下载大文件, 产生稳定的下行流量, 不占满带宽, 不占磁盘
# 原理: 每次下载都输出到 /dev/null, 下载完删不删都一样, 循环下一轮
# 适用: 任意直链, 包括官网的荣耀安装包 / 驱动 / 系统镜像等, 也支持自填链接
# 依赖: curl (优先) 或 wget, bash 4+, awk (Debian 默认的 mawk 也行)
# 支持: 主流 Linux 发行版 Ubuntu / Debian / CentOS / RHEL / Rocky / AlmaLinux / Fedora, amd64/arm64
# 用法: chmod +x loop_download.sh && ./loop_download.sh
# 一键呼出 (用 install.sh 装过后, 任意目录都行): loopdl
# 停止后台任务: 菜单 6, 或在别的终端打 loopdl stop (查看状态: loopdl status, 看日志: loopdl log)
# 注意: 国内服务器不要用 raw.githubusercontent.com 下载本脚本, 容易被重置, 用 install.sh 或 jsDelivr (见 README)。

set -u

# 版本号: 每次改脚本就改这里, install.sh 靠它识别是不是最新版,
# 防止 jsDelivr 缓存的旧版被当成新版装上 (旧版没有 stop_task 和国内预设, 但也有 RATE_MBPS, 光查 RATE_MBPS 拦不住旧版)。
# 改脚本时必须同步改 install.sh 里的 EXPECTED_VERSION, 保持一致。
LOOPDL_VERSION="1.5.3"

# ---------- 配置 ----------
CONFIG_DIR="${HOME}/.config/loop_download"
PRESET_FILE="${CONFIG_DIR}/presets.txt"
PID_FILE="${CONFIG_DIR}/loop_download.pid"
LOG_FILE="${CONFIG_DIR}/loop_download.log"
RUN_CONF="${CONFIG_DIR}/run.conf"
mkdir -p "$CONFIG_DIR" 2>/dev/null || true
# 后台任务用: 本脚本自己的路径, start_background 靠它拉起 worker
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

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
  "国外-Cloudflare测速10MB(低速率测试, 2Mbps约40秒一轮)|https://speed.cloudflare.com/__down?bytes=10485760"
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
# 注意: 千万别用 Chrome/Mozilla UA! 实测清华镜像对 Chrome UA 的 ISO 完整下载直接回 403 (1 秒就“完成” 15346 字节错误页, 日志里就是 0 MB),
# 而 curl 默认 / loopdl UA 就回 200 正常下。这就是之前清华源一跑就 0 MB 的真正原因, 不是链接失效, 是 UA 被清华 WAF 挡了。
UA="loopdl/$LOOPDL_VERSION"

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
  echo "版本   : $LOOPDL_VERSION (面板里看不到 6 / 国内预设, 就是旧版, 重新装)"
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
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null || echo 0)" 2>/dev/null; then
    echo "后台任务: 运行中 (PID $(cat "$PID_FILE"), 菜单 6 或 loopdl stop 可停)"
  else
    echo "后台任务: 未运行"
  fi
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

# ---------- 后台任务: 启动 / 停止 / 状态 ----------
# 为什么要后台: 前台跑的时候菜单被占住, 想停只能 Ctrl+C, 关了终端就没法从别处停。
# 后台跑起来后, 面板回到菜单, 菜单 6 能停, 别的终端打 loopdl stop 也能停,
# 日志在 $LOG_FILE, PID 在 $PID_FILE。
is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local p; p="$(cat "$PID_FILE" 2>/dev/null || echo "")"
  [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null
}

save_run_conf() {
  {
    printf 'SELECTED_NAME=%q\n' "$SELECTED_NAME"
    printf 'SELECTED_URL=%q\n' "$SELECTED_URL"
    printf 'RATE_MBPS=%q\n' "$RATE_MBPS"
    printf 'LOOP_MODE=%q\n' "$LOOP_MODE"
    printf 'LOOP_COUNT=%q\n' "$LOOP_COUNT"
    printf 'LOOP_MINUTES=%q\n' "$LOOP_MINUTES"
    printf 'INTERVAL=%q\n' "$INTERVAL"
  } > "$RUN_CONF"
}

show_task_status() {
  if is_running; then
    echo "后台任务: 运行中, PID $(cat "$PID_FILE")"
    if [[ -f "$RUN_CONF" ]]; then
      # 子 shell 里 source, 不影响面板当前会话, 且中文能正常显示 (run.conf 里 %q 转义过的中文直接 grep 会很难看)
      ( . "$RUN_CONF" 2>/dev/null; echo "下载源: $SELECTED_NAME"; echo "链接: $SELECTED_URL"; echo "限速: ${RATE_MBPS} Mbps, 循环: $LOOP_MODE" )
    fi
  else
    [[ -f "$PID_FILE" ]] && rm -f "$PID_FILE"
    echo "后台任务: 未运行"
  fi
  if [[ -f "$LOG_FILE" ]]; then
    echo "--- 最近日志 ($LOG_FILE, 最后 20 行) ---"
    tail -20 "$LOG_FILE"
  else
    echo "还没有日志文件。"
  fi
}

stop_task() {
  if ! is_running; then
    [[ -f "$PID_FILE" ]] && rm -f "$PID_FILE"
    echo "没有后台下载任务在跑。"
    return 1
  fi
  local pid; pid="$(cat "$PID_FILE")"
  echo "正在停止后台任务 PID $pid ..."
  # 先停整个进程组 (worker + 它正在跑的 curl), 再停主进程和子进程, 防止只杀壳留 curl 继续跑
  kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  pkill -TERM -P "$pid" 2>/dev/null || true
  local i
  for i in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "还在跑, 强制结束..."
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    pkill -KILL -P "$pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$PID_FILE"
  if kill -0 "$pid" 2>/dev/null; then
    echo "停止失败, PID $pid 还在, 请手动: kill -9 $pid"
    return 1
  fi
  echo "已停止。"
  return 0
}

start_background() {
  if [[ -z "$SELECTED_URL" ]]; then
    echo "先选一个下载源 (菜单 1)。"
    pause; return
  fi
  if ! has_cmd curl && ! has_cmd wget; then
    echo "没找到 curl 或 wget, 先装一个: sudo apt install curl / yum install curl"
    pause; return
  fi
  if is_running; then
    echo "已经有一个后台任务在跑 (PID $(cat "$PID_FILE")), 先用菜单 6 停了它再开新的。"
    pause; return
  fi
  save_run_conf
  echo "后台任务启动: $(date '+%Y-%m-%d %H:%M:%S')" > "$LOG_FILE"
  echo "下载源: $SELECTED_NAME ($SELECTED_URL)" >> "$LOG_FILE"
  echo "限速: ${RATE_MBPS} Mbps, 循环: $LOOP_MODE" >> "$LOG_FILE"
  if has_cmd setsid; then
    setsid nohup "$SCRIPT_PATH" --worker >> "$LOG_FILE" 2>&1 < /dev/null &
  else
    nohup "$SCRIPT_PATH" --worker >> "$LOG_FILE" 2>&1 < /dev/null &
  fi
  local pid=$!
  echo "$pid" > "$PID_FILE"
  sleep 1
  if is_running; then
    echo "已在后台启动, PID $pid, 日志: $LOG_FILE"
    echo "想停的时候: 回面板选 6, 或在别的终端打 loopdl stop (不用进面板也行)。"
  else
    echo "启动失败, 看日志:"
    tail -20 "$LOG_FILE" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  pause
}

# 后台 worker: 不进菜单, 只循环下载写日志, 被 stop_task 杀掉时清理 PID 文件。
worker_loop() {
  if [[ -f "$RUN_CONF" ]]; then
    # shellcheck disable=SC1090
    . "$RUN_CONF"
  fi
  if [[ -z "${SELECTED_URL:-}" ]]; then
    echo "worker: 没有下载链接, 退出。"
    exit 1
  fi
  local limit_bytes=""
  if [[ "$RATE_MBPS" != "0" ]]; then
    limit_bytes=$(mbps_to_bytes "$RATE_MBPS")
  fi
  local round=0 total_bytes=0 start_ts end_ts fail_streak=0
  start_ts=$(date +%s)
  end_ts=$((start_ts + LOOP_MINUTES * 60))
  trap 'echo "[$(date "+%Y-%m-%d %H:%M:%S")] 已停止: 共 $round 轮, 累计约 $((total_bytes/1024/1024)) MB"; rm -f "$PID_FILE"; exit 0' TERM INT
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] worker 启动, 限速 ${RATE_MBPS} Mbps"
  # 预估一轮时间: 先 HEAD 取文件大小, 算一下按当前速率要多久, 免得用户看日志半天不动以为卡死了。
  # 比如 6.25GB 的 ISO 按 2 Mbps 跑, 一轮要约 6.9 小时, 日志在这一轮完成前都不会更新, 属正常, 流量其实一直在跑。
  if has_cmd curl && [[ "$RATE_MBPS" != "0" ]]; then
    local head_size est_sec est_text
    head_size=$(curl -sIL --max-time 15 "$SELECTED_URL" 2>/dev/null | grep -i "^Content-Length:" | tail -1 | awk '{print $2}' | tr -d '\r')
    if [[ "$head_size" =~ ^[0-9]+$ ]] && (( head_size > 0 )); then
      est_sec=$(awk -v s="$head_size" -v m="$RATE_MBPS" 'BEGIN{printf "%.0f", s/(m*125000)}')
      if (( est_sec >= 3600 )); then
        est_text="$(awk -v s="$est_sec" 'BEGIN{printf "%.1f", s/3600}') 小时"
      elif (( est_sec >= 60 )); then
        est_text="$(awk -v s="$est_sec" 'BEGIN{printf "%.0f", s/60}') 分钟"
      else
        est_text="${est_sec} 秒"
      fi
      echo "  文件大小约 $((head_size/1024/1024)) MB, 按 ${RATE_MBPS} Mbps 约需 $est_text 完成一轮, 期间日志无更新属正常, 流量仍在跑, 可用 cat /proc/net/dev 或 nethogs 检查实时流量。"
      if (( est_sec >= 3600 )); then
        echo "  提示: 一轮要超过 1 小时, 想让日志经常动、想快点看到累计量, 建议换个小文件 (比如测速 10MB/100MB) 或把速率调高, 否则停掉重开也没用, 只是换个大文件继续等。"
      fi
    else
      echo "  文件大小未知 (HEAD 没取到 Content-Length), 无法预估一轮时间。"
    fi
  fi
  while true; do
    round=$((round+1))
    if [[ "$LOOP_MODE" == "count" ]] && (( round > LOOP_COUNT )); then break; fi
    if [[ "$LOOP_MODE" == "minutes" ]] && (( $(date +%s) >= end_ts )); then break; fi
    local round_start round_size http_code curl_exit curl_out
    round_start=$(date +%s)
    round_size=0; http_code=""; curl_exit=0; curl_out=""
    echo "[第 $round 轮] $(date '+%H:%M:%S') 开始, 限速 ${RATE_MBPS} Mbps, 链接: $SELECTED_URL"
    if has_cmd curl; then
      # 以前这里用 -s + 2>/dev/null + || echo 0, curl 一失败就只剩 0 MB, 根本看不出是 404、DNS、TLS 还是被重置,
      # 用户截图里 0 MB / 0s 就是这么来的。现在把 http 码、curl 退出码、错误信息都记到日志里。
      if [[ "$RATE_MBPS" == "0" ]]; then
        curl_out=$(curl -L -sS -A "$UA" --connect-timeout 15 -o /dev/null -w "%{size_download} %{http_code}" "$SELECTED_URL" 2>"$CONFIG_DIR/curl_error.txt"); curl_exit=$?
      else
        curl_out=$(curl -L -sS -A "$UA" --limit-rate "$limit_bytes" --connect-timeout 15 -o /dev/null -w "%{size_download} %{http_code}" "$SELECTED_URL" 2>"$CONFIG_DIR/curl_error.txt"); curl_exit=$?
      fi
      round_size=$(echo "$curl_out" | awk '{print $1}')
      http_code=$(echo "$curl_out" | awk '{print $2}')
    else
      if [[ "$RATE_MBPS" == "0" ]]; then
        wget -O /dev/null --timeout=15 -U "$UA" "$SELECTED_URL" 2>"$CONFIG_DIR/curl_error.txt"; curl_exit=$?
      else
        wget -O /dev/null --limit-rate="$limit_bytes" --timeout=15 -U "$UA" "$SELECTED_URL" 2>"$CONFIG_DIR/curl_error.txt"; curl_exit=$?
      fi
      http_code="wget:$curl_exit"
      round_size=0
    fi
    [[ -z "$round_size" ]] && round_size=0
    [[ "$round_size" =~ ^[0-9]+$ ]] || round_size=0
    total_bytes=$((total_bytes + round_size))
    # 失败判定不能只看大小: 404 时 curl 退出码是 0, 但会下回一个 153 字节的错误页, 大小不是 0, http 码却是 404。
    # 所以 curl 要同时看退出码、http 码 (200/206 才算成功)、大小; wget 没有 http 码, 只看退出码。
    local failed=0
    if has_cmd curl; then
      if [[ "$curl_exit" != "0" ]] || [[ "$http_code" != "200" && "$http_code" != "206" ]] || [[ "$round_size" == "0" ]]; then failed=1; fi
    else
      [[ "$curl_exit" != "0" ]] && failed=1
    fi
    if [[ "$failed" == "1" ]]; then
      fail_streak=$((fail_streak+1))
      echo "  本轮失败: 大小 ${round_size} 字节, http=${http_code:-?}, curl退出码=${curl_exit}, 错误: $(head -c 300 "$CONFIG_DIR/curl_error.txt" 2>/dev/null | tr '\n' ' ')"
      if (( fail_streak >= 5 )); then
        echo "  警告: 已连续 ${fail_streak} 轮失败, 链接或网络很可能有问题 (404/DNS/TLS/被重置都可能), 建议先停掉 (菜单 6 / loopdl stop) 检查链接, 本任务仍会继续重试。"
      fi
    else
      fail_streak=0
      echo "  本轮完成: 约 $((round_size/1024/1024)) MB, 用时 $(( $(date +%s) - round_start ))s, 累计约 $((total_bytes/1024/1024)) MB"
    fi
    if [[ "$LOOP_MODE" == "count" ]] && (( round >= LOOP_COUNT )); then break; fi
    if [[ "$LOOP_MODE" == "minutes" ]] && (( $(date +%s) >= end_ts )); then break; fi
    sleep "$INTERVAL"
  done
  trap - TERM INT
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] worker 正常结束: 共 $round 轮, 累计约 $((total_bytes/1024/1024)) MB"
  rm -f "$PID_FILE"
}

# ---------- 测试所有预设是否可用 ----------
# 只下每个源的前 1MB (Range), 不下完整文件, 几十秒就能知道哪个源在这台机器上真能用、
# 哪个是 404 / DNS / TLS / 被重置, 而不是凭“日志不动”猜。用法: 菜单 9, 或 loopdl test。
test_sources() {
  if ! has_cmd curl; then
    echo "测试需要 curl, 请先装 curl。"
    return
  fi
  load_presets
  echo "========== 测试预设链接 (每个只下前 1KB, Cloudflare 小文件除外) =========="
  echo "注意: 这里不按限速跑, 只看能不能连上、下不下得动, 跟正式跑的速率无关。"
  echo "Range 用 1KB 不用 1MB: 实测 1MB Range 会让个别镜像超时/403, 1KB 最稳, 能下 1KB 就能下完整文件。"
  local i=1
  for p in "${PRESETS[@]}"; do
    local name="${p%%|*}" url="${p#*|}"
    local out exit_code http_code size time_total
    out=$(curl -L -A "$UA" --connect-timeout 10 --max-time 20 -r 0-1023 -o /dev/null -sS -w "%{http_code} %{size_download} %{time_total}" "$url" 2>"$CONFIG_DIR/curl_error.txt"); exit_code=$?
    http_code=$(echo "$out" | awk '{print $1}')
    size=$(echo "$out" | awk '{print $2}')
    time_total=$(echo "$out" | awk '{print $3}')
    if [[ "$exit_code" == "0" ]] && [[ "$http_code" == "200" || "$http_code" == "206" ]] && [[ -n "$size" && "$size" != "0" ]]; then
      echo "  [$i] [可用] $name: http=$http_code, 下到 ${size} 字节, 用时 ${time_total}s"
    else
      echo "  [$i] [不可用] $name: http=${http_code:-?}, curl退出码=$exit_code, 下到 ${size:-0} 字节, 错误: $(head -c 200 "$CONFIG_DIR/curl_error.txt" 2>/dev/null | tr '\n' ' ')"
    fi
    i=$((i+1))
  done
  echo "=============================================="
  echo "如果全是不可用, 把上面 http 码和 curl 退出码发出来, 才能定位是 DNS(6)、连不上(7)、TLS(35)、被重置(56) 还是 404/403, 光说不可用没法修。"
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
    echo "  1) 无限循环, 直到停止 (后台: 菜单 6 / loopdl stop, 前台: Ctrl+C)"
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
  echo "注意: 这是前台模式, 会占住这个终端, 一轮没跑完之前不会回菜单, 想边跑边用菜单请用菜单 4 后台模式。"
  echo "=================================="

  # 前台也预估一轮时间, 否则大文件 + 静默 curl 看起来就像卡死, 其实只是在等一轮跑完。
  # 比如你这张图: 6.25GB 按 16 Mbps 跑, 一轮约 52 分钟, 开始 1 分多钟没动静是正常的。
  if has_cmd curl && [[ "$RATE_MBPS" != "0" ]]; then
    local head_size est_sec est_text
    head_size=$(curl -sIL --max-time 15 "$SELECTED_URL" 2>/dev/null | grep -i "^Content-Length:" | tail -1 | awk '{print $2}' | tr -d '\r')
    if [[ "$head_size" =~ ^[0-9]+$ ]] && (( head_size > 0 )); then
      est_sec=$(awk -v s="$head_size" -v m="$RATE_MBPS" 'BEGIN{printf "%.0f", s/(m*125000)}')
      if (( est_sec >= 3600 )); then
        est_text="$(awk -v s="$est_sec" 'BEGIN{printf "%.1f", s/3600}') 小时"
      elif (( est_sec >= 60 )); then
        est_text="$(awk -v s="$est_sec" 'BEGIN{printf "%.0f", s/60}') 分钟"
      else
        est_text="${est_sec} 秒"
      fi
      echo "  文件大小约 $((head_size/1024/1024)) MB, 按 ${RATE_MBPS} Mbps 约需 $est_text 完成一轮, 下面进度条会动, 流量在跑, 不是卡死。"
    else
      echo "  文件大小未知, 无法预估一轮时间, 下面进度条会动就说明在跑。"
    fi
    echo "=================================="
  fi

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

    local round_start round_size http_code curl_exit curl_out
    round_start=$(date +%s)
    round_size=0; http_code=""; curl_exit=0; curl_out=""
    if [[ "$RATE_MBPS" == "0" ]]; then
      echo "[第 $round 轮] $(date '+%H:%M:%S') 开始, 不限速"
    else
      echo "[第 $round 轮] $(date '+%H:%M:%S') 开始, 限速 ${RATE_MBPS} Mbps"
    fi
    echo "  链接: $SELECTED_URL"

    if has_cmd curl; then
      # 前台跟后台不一样: 后台要静默写日志, 前台要让人看见在动, 所以这里用 -# 进度条, stderr 直接打到终端,
      # 不用 -sS、不重定向到错误文件, 否则进度条和错误都被吞掉, 看起来就是“卡在这里”。
      # $() 只抓 stdout 的 -w 结果, 进度条走 stderr, 不会进变量, 轮完会正常打印本轮完成/失败。
      if [[ "$RATE_MBPS" == "0" ]]; then
        curl_out=$(curl -L -# -A "$UA" --connect-timeout 15 -o /dev/null -w "%{size_download} %{http_code}" "$SELECTED_URL"); curl_exit=$?
      else
        curl_out=$(curl -L -# -A "$UA" --limit-rate "$limit_bytes" --connect-timeout 15 -o /dev/null -w "%{size_download} %{http_code}" "$SELECTED_URL"); curl_exit=$?
      fi
      round_size=$(echo "$curl_out" | awk '{print $1}')
      http_code=$(echo "$curl_out" | awk '{print $2}')
    else
      # wget 备用: --limit-rate 按字节/秒, 0 表示不限
      if [[ "$RATE_MBPS" == "0" ]]; then
        wget -O /dev/null --timeout=15 -U "$UA" "$SELECTED_URL" 2>"$CONFIG_DIR/curl_error.txt"; curl_exit=$?
      else
        wget -O /dev/null --limit-rate="$limit_bytes" --timeout=15 -U "$UA" "$SELECTED_URL" 2>"$CONFIG_DIR/curl_error.txt"; curl_exit=$?
      fi
      http_code="wget:$curl_exit"
      round_size=0  # wget 不方便直接取字节数, 本轮计 0, 只看轮数
    fi
    [[ -z "$round_size" ]] && round_size=0
    # 防止非数字
    [[ "$round_size" =~ ^[0-9]+$ ]] || round_size=0
    total_bytes=$((total_bytes + round_size))
    local round_elapsed=$(( $(date +%s) - round_start ))
    local failed=0
    if has_cmd curl; then
      if [[ "$curl_exit" != "0" ]] || [[ "$http_code" != "200" && "$http_code" != "206" ]] || [[ "$round_size" == "0" ]]; then failed=1; fi
    else
      [[ "$curl_exit" != "0" ]] && failed=1
    fi
    if [[ "$failed" == "1" ]]; then
      echo "  本轮失败: 大小 ${round_size} 字节, http=${http_code:-?}, curl退出码=${curl_exit} (curl 前台的错误已在上面进度条处直接显示)"
    else
      echo "  本轮完成: 约 $((round_size/1024/1024)) MB, 用时 ${round_elapsed}s, 累计约 $((total_bytes/1024/1024)) MB"
    fi
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

# ---------- 命令行子命令 (不用进面板也能停) ----------
# loopdl stop / status / log: 给别的终端用的, 面板被下载占住时也能停。
# --worker: 后台 worker 专用, 不要手动打。
case "${1:-}" in
  stop) stop_task; exit $? ;;
  status) show_task_status; exit 0 ;;
  test) test_sources; exit 0 ;;
  log)
    if [[ -f "$LOG_FILE" ]]; then tail -50 "$LOG_FILE"; else echo "还没有日志文件。"; fi
    exit 0
    ;;
  --worker) worker_loop; exit $? ;;
  "") ;;
  *) echo "用法: loopdl [stop|status|log|test]"; echo "  不带参数进面板, stop 停后台任务, status 看状态, log 看日志, test 测试所有预设是否可用"; exit 1 ;;
esac

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
  echo "  4) 开始下载 (后台运行, 回菜单后可用 6 停止)"
  echo "  5) 管理预设链接"
  echo "  6) 停止下载任务"
  echo "  7) 查看后台任务状态和日志"
  echo "  8) 开始下载 (前台运行, 按 Ctrl+C 停止)"
  echo "  9) 测试所有预设链接是否可用 (每个只下前 1KB)"
  echo "  0) 退出"
  echo "=================================="
  read -rp "请选择 [0-9]: " choice
  case "$choice" in
    1) choose_source ;;
    2) choose_rate ;;
    3) choose_loop ;;
    4) start_background ;;
    5) manage_presets ;;
    6) stop_task; pause ;;
    7) show_task_status; pause ;;
    8) run_loop ;;
    9) test_sources; pause ;;
    0) echo "退出, 再见。"; exit 0 ;;
    *) echo "无效选择"; pause ;;
  esac
done
