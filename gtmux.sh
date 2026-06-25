#!/usr/bin/env bash
# gtmux — tmux multi-host manager・焦點模式（純 tmux，免裝套件）
#
# 每台主機 = 一個 window，切成 [左:常駐主機欄 | 右:該台大畫面]。
# 左欄一直在、列出全部主機、目前這台反白。不用背指令:
#
#   Prefix(Ctrl+B) + ↑ / ↓   上一台 / 下一台（左欄反白跟著動）
#   Prefix + 1-9 / '         直接跳到該編號的主機
#   Prefix + Space           叫出選單（廣播 / ssh / log / 監視器 / 清理 / 關閉）
#   Prefix + b / B / Enter    廣播送出 / 廣播不送出 / 對全部送 Enter
#   Prefix + m / M           開監視器(挑幾台一起看) / 關監視器
#   Prefix + e / E           收合左欄(此台 / 全部)
#
# open 只鋪好 panes（純 shell，不自動 ssh）；要連線按選單的 ssh。
#
# Usage:
#   gtmux open                # 吃 ip.txt 鋪好並進入
#   gtmux open -n 5           # 手動開 5 個 pane(不讀 ip.txt,編號 1..5)
#   gtmux open -n 5 -p dut-   # 手動 5 個,標籤 dut-1 .. dut-5
#   gtmux open -l /tmp/logs   # 指定 log 路徑(預設 ./)
#   gtmux attach              # 重新進入
#   gtmux kill                # 關掉 session
#   gtmux help                # 這份說明
#
# Env: GTMUX_SESSION=gtmux  GTMUX_KEY=Space  IPS_FILE=./ip.txt  LOGROOT=.
#      GTMUX_SIDEBAR_W=20%   GTMUX_MON_FRESH=3
set -u

SESSION="${GTMUX_SESSION:-gtmux}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")" # 絕對路徑且改名也不壞
IPS_FILE="${IPS_FILE:-$DIR/ip.txt}"
LOGROOT="${LOGROOT:-.}" # log 路徑,預設目前目錄;也可 ./gtmux.sh open <path>
MENU_KEY="${GTMUX_KEY:-Space}"
SIDEBAR_W="${GTMUX_SIDEBAR_W:-20%}" # 百分比,隨螢幕等比例縮放（避免寬螢幕上顯得小）；也可給固定字元如 30
MON_FRESH="${GTMUX_MON_FRESH:-3}"   # 監視器:log mtime 在幾秒內算「有在動」(●live),否則顯示停了多久
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# ---- helpers ----------------------------------------------------------------

read_ips() {
  [[ -r "$IPS_FILE" ]] || {
    echo "找不到 $IPS_FILE" >&2
    return 1
  }
  mapfile -t IPS < <(sed 's/#.*//' "$IPS_FILE" | tr -d '[:blank:]' | grep -vE '^$')
  ((${#IPS[@]})) || {
    echo "$IPS_FILE 沒有任何 IP" >&2
    return 1
  }
}

has_session() { tmux has-session -t "$SESSION" 2>/dev/null; }
# 目前 log 目錄存在 session 選項裡（跨程序、改路徑都穩）
log_dir() { tmux show-option -t "$SESSION" -qv @gtmux_logdir 2>/dev/null; }
set_log_dir() { tmux set-option -t "$SESSION" @gtmux_logdir "$1"; }

# 把選擇字串(1-4 / 1,3,5 / 1-3,7 / all)展開成 1-based 位置清單(限制在 1..max)
expand_selection() {
  local sel="${1// /}" max="$2" part a b x
  if [[ -z "$sel" || "$sel" == "all" ]]; then
    seq 1 "$max"
    return
  fi
  local IFS=','
  for part in $sel; do
    if [[ "$part" == *-* ]]; then
      a="${part%-*}"
      b="${part#*-}"
      [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || continue
      for ((x = a; x <= b; x++)); do ((x >= 1 && x <= max)) && echo "$x"; done
    elif [[ "$part" =~ ^[0-9]+$ ]] && ((part >= 1 && part <= max)); then
      echo "$part"
    fi
  done
}

# 裝置 pane + 標籤 + window 編號(| 分隔,廣播佔位符用)
dev_panes_full() {
  tmux list-panes -s -t "$SESSION" -F '#{pane_id}|#{@gtmux}|#{pane_title}|#{window_index}' 2>/dev/null |
    awk -F'|' '$2=="dev"{print $1"|"$3"|"$4}'
}

# 列出所有「裝置 pane」（排除左側欄）:輸出 "pane_id ip"
dev_panes() {
  tmux list-panes -s -t "$SESSION" -F '#{pane_id}|#{@gtmux}|#{pane_title}' 2>/dev/null \
    | awk -F'|' '$2=="dev"{print $1, $3}'
}

# ---- open（焦點模式）--------------------------------------------------------

build_window() {
  local idx="$1" ip="$2" d="$3" base="$4" win dev side
  if [[ -z "${_FIRST_DONE:-}" ]]; then
    win="$(tmux list-windows -t "$SESSION" -F '#{window_id}' | head -1)"
    tmux rename-window -t "$win" "$ip"
    _FIRST_DONE=1
  else
    win="$(tmux new-window -t "$SESSION" -n "$ip" -P -F '#{window_id}')"
  fi
  dev="$(tmux list-panes -t "$win" -F '#{pane_id}' | head -1)"
  # 左側常駐欄:在 device pane 左邊切一條,跑 _sidebar
  # 傳 idx(反白)、base(序號)、ip 檔、session(左欄要查 monitor windows)
  side="$(tmux split-window -h -b -l "$SIDEBAR_W" -t "$dev" -P -F '#{pane_id}' \
    "exec '$SELF' _sidebar '$idx' '$base' '$IPS_FILE' '$SESSION'")"
  tmux set -p -t "$side" @gtmux side
  tmux set -p -t "$dev" @gtmux dev
  tmux select-pane -t "$dev" -T "$ip"
  tmux pipe-pane -t "$dev" "cat >> '$d/${ip}.log'" # log 開機就開
  tmux select-pane -t "$dev"                       # 焦點停在裝置畫面,不在左欄
}

action_open() {
  # 參數: -n N 手動開 N 個 pane   -p PREFIX 手動標籤前綴(如 dut- → dut-1)
  #        -l PATH / 位置參數 = log 路徑
  local count="" logbase="" prefix=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -n)
      count="${2:-}"
      shift 2
      ;;
    -p)
      prefix="${2:-}"
      shift 2
      ;;
    -l)
      logbase="${2:-}"
      shift 2
      ;;
    *)
      logbase="$1"
      shift
      ;;
    esac
  done
  [[ -n "$logbase" ]] && LOGROOT="$logbase"

  # 裝置清單:-n 走手動編號(前綴+1..N),否則讀 ip.txt
  if [[ -n "$count" ]]; then
    if ! [[ "$count" =~ ^[0-9]+$ ]] || ((count < 1)); then
      echo "-n 需要正整數,got: $count" >&2
      return 1
    fi
    IPS=()
    local k
    for ((k = 1; k <= count; k++)); do IPS+=("${prefix}${k}"); done
  else
    [[ -n "$prefix" ]] && echo "註:-p 只在 -n 手動模式有效,ip.txt 模式忽略" >&2
    read_ips || return 1
  fi

  if has_session; then
    echo "session '$SESSION' 已存在 → '$0 attach' 進入,或 '$0 kill' 重來" >&2
    return 1
  fi
  local ts d ip
  ts="$(date +%Y%m%d_%H%M%S)"
  d="$LOGROOT/$ts"
  mkdir -p "$d" || {
    echo "無法建立 log 目錄: $d" >&2
    return 1
  }
  # 固化裝置清單到 log 目錄,左欄統一讀這份(手動模式也有、且不受原檔變動影響)
  printf '%s\n' "${IPS[@]}" >"$d/.devices"
  IPS_FILE="$d/.devices"

  tmux new-session -d -s "$SESSION" -x 280 -y 60
  set_log_dir "$d"
  # 1-based:讓 window 從 1 開始,使用者按 Prefix+1 = 第一台
  tmux set -t "$SESSION" base-index 1 2>/dev/null || true
  tmux set -t "$SESSION" pane-base-index 1 2>/dev/null || true
  tmux move-window -r -t "$SESSION" 2>/dev/null || true
  tmux set -t "$SESSION" mouse on 2>/dev/null || true # 可滑鼠點 pane/捲動
  tmux set -t "$SESSION" pane-border-status off 2>/dev/null || true

  # 序號要對上 tmux window 編號,使用者看到幾號就按 Prefix+幾跳過去
  local i base
  base="$(tmux list-windows -t "$SESSION" -F '#{window_index}' | head -1)"
  for i in "${!IPS[@]}"; do build_window "$i" "${IPS[$i]}" "$d" "$base"; done

  bind_keys
  tmux select-window -t "${SESSION}:${base}" # 第一台(1-based 後為 1)
  tmux set -t "$SESSION" status-left "#[bold] gtmux #[default]"
  tmux set -t "$SESSION" status-right "Prefix+${MENU_KEY} 選單 · Prefix ↑↓ 換台 · Prefix b 廣播"

  echo "已開 ${#IPS[@]} 台（焦點模式,純 shell 未 ssh）。log → $d/<ip>.log"
  echo "進入後:Prefix ↑↓ 換台 · Prefix+${MENU_KEY} 選單 · Prefix b 廣播"
  [[ -z "${TMUX:-}" ]] && tmux attach -t "$SESSION"
}

# 左側常駐欄的內容（這個 process 就活在左欄 pane 裡）
action_sidebar() {
  local cur="$1" base="${2:-0}" ipf="${3:-}" sess="${4:-}"
  [[ -n "$ipf" ]] && IPS_FILE="$ipf"
  [[ -n "$sess" ]] && SESSION="$sess"
  read_ips 2>/dev/null || IPS=("(no ip.txt)")
  render_sidebar() {
    printf '\033[H\033[2J'
    printf ' \033[1mgtmux\033[0m\n'
    printf ' \033[2m%s 台\033[0m\n' "${#IPS[@]}"
    printf ' ────────────────\n'
    local i num
    for i in "${!IPS[@]}"; do
      num=$((base + i)) # = tmux window 編號 = Prefix+數字 要按的號
      if ((i == cur)); then
        printf ' \033[7m %02d ▸ %s \033[0m\n' "$num" "${IPS[$i]}" # 反白依位置
      else
        printf ' \033[36m%02d\033[0m   \033[2m%s\033[0m\n' "$num" "${IPS[$i]}"
      fi
    done
    # 監視器(動態):列出名稱 mon-* 的 window,可 Prefix+其編號跳過去
    local mons widx wname
    mons="$(tmux list-windows -t "$SESSION" -F '#{window_index}|#{window_name}' 2>/dev/null |
      awk -F'|' '$2 ~ /^mon-/')"
    if [[ -n "$mons" ]]; then
      printf ' ────────────────\n'
      printf ' \033[1m監視器\033[0m\n'
      while IFS='|' read -r widx wname; do
        [[ -n "$widx" ]] || continue
        printf ' \033[33m%02d\033[0m \033[2m%s\033[0m\n' "$widx" "${wname#mon-}"
      done <<<"$mons"
    fi
    printf ' ────────────────\n'
    printf ' \033[2mPfx 1-9 跳台\033[0m\n'
    printf " \033[2mPfx ' 編號跳\033[0m\n"
    printf ' \033[2mPfx ↑↓ 換台\033[0m\n'
    printf ' \033[2mPfx e/E 收左欄\033[0m\n'
    printf ' \033[2mPfx m 監視/M 關\033[0m\n'
    printf ' \033[2mPfx b 廣播/B 不送\033[0m\n'
    printf ' \033[2mPfx Enter 全部送出\033[0m\n'
    printf ' \033[2mPfx Spc 選單\033[0m\n'
  }
  # 每 2s 重畫,但只在內容變(有新/關監視器)時才真的 repaint → 不閃
  local _last=""
  trap '_last=' WINCH
  while :; do
    local c
    c="$(render_sidebar)"
    if [[ "$c" != "$_last" ]]; then
      printf '%s' "$c"
      _last="$c"
    fi
    sleep 2
  done
}

# ---- 選單動作（跨 window 對所有裝置 pane 操作）-------------------------------

# 廣播一條指令到全部裝置。支援佔位符,送出前每台各自替換:
#   {}  → 該台標籤(IP 或名)   {n} → 該台編號
# 例:  ./download {} 100      →  每台變成 ./download 192.168.1.23 100 ...
#       ./download 192.168.1.{n} 100   (標籤非 IP 時用編號組)
action_bcast() {
  local withenter="$1"
  shift
  local tmpl="$*" p ip widx cmd n=0
  [[ -n "$tmpl" ]] || return 0
  while IFS='|' read -r p ip widx; do
    [[ -n "$p" ]] || continue
    cmd="$tmpl"
    cmd="${cmd//\{\}/$ip}"
    cmd="${cmd//\{n\}/$widx}"
    if [[ "$withenter" == 1 ]]; then
      tmux send-keys -t "$p" "$cmd" Enter
    else
      tmux send-keys -t "$p" "$cmd" # 只打,不送 Enter
    fi
    n=$((n + 1))
  done < <(dev_panes_full)
  if [[ "$withenter" == 1 ]]; then
    tmux display-message "已廣播並送出 → $n 台"
  else
    tmux display-message "已打入(未送出)→ $n 台;確認後 Prefix Enter 一起送出"
  fi
}

# 對全部裝置送一個 Enter(把「不送出」打入的指令一起執行)
action_enterall() {
  local p ip widx n=0
  while IFS='|' read -r p ip widx; do
    [[ -n "$p" ]] || continue
    tmux send-keys -t "$p" Enter
    n=$((n + 1))
  done < <(dev_panes_full)
  tmux display-message "已對 $n 台送出 Enter"
}

action_ssh_all() {
  local p ip n=0
  while read -r p ip; do
    [[ -n "$p" ]] || continue
    tmux send-keys -t "$p" "ssh $SSH_OPTS $ip" Enter
    n=$((n + 1))
  done < <(dev_panes)
  tmux display-message "已對 $n 台送出 ssh"
}

action_log_start() {
  local d p ip n=0
  d="$(log_dir)"
  [[ -d "$d" ]] || {
    d="$LOGROOT/manual_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$d"
    set_log_dir "$d"
  }
  while read -r p ip; do
    [[ -n "$p" ]] || continue
    tmux pipe-pane -t "$p" "cat >> '$d/${ip}.log'"
    n=$((n + 1))
  done < <(dev_panes)
  tmux display-message "全機 log 開始（$n 台）→ $d"
}

action_log_stop() {
  local p ip n=0
  while read -r p ip; do
    [[ -n "$p" ]] || continue
    tmux pipe-pane -t "$p"
    n=$((n + 1))
  done < <(dev_panes)
  tmux display-message "全機 log 已停止（$n 台）"
}

action_clean() {
  local d f out n=0
  d="$(log_dir)"
  [[ -d "$d" ]] || {
    tmux display-message "找不到 log 目錄"
    return
  }
  for f in "$d"/*.log; do
    [[ -e "$f" ]] || continue
    out="${f%.log}.clean.txt"
    if command -v ansi2txt >/dev/null 2>&1; then
      ansi2txt <"$f" | col -b >"$out"
    else
      sed -r $'s/\e\\[[0-9;?]*[a-zA-Z]//g; s/\r//g' "$f" | col -b >"$out"
    fi
    n=$((n + 1))
  done
  tmux display-message "清好 $n 檔 → $d/*.clean.txt"
}

# 監視器單格:背景跑 tail,前景每 2s 看 log mtime,把新鮮度寫進該格邊框標題。
action_montail() {
  local title="$1" file="$2" pane="${TMUX_PANE:-}" tpid mtime now age
  tail -n 200 -F "$file" 2>/dev/null &
  tpid=$!
  trap 'kill "$tpid" 2>/dev/null' EXIT INT TERM
  while :; do
    if [[ -f "$file" ]]; then
      mtime="$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null)"
      now="$(date +%s)"
      if [[ -n "$mtime" ]]; then
        age=$((now - mtime))
        if ((age <= MON_FRESH)); then
          tmux select-pane -t "$pane" -T "$title  ●live" 2>/dev/null
        else
          tmux select-pane -t "$pane" -T "$title  ⏸停${age}s" 2>/dev/null
        fi
      fi
    else
      tmux select-pane -t "$pane" -T "$title  (無log)" 2>/dev/null
    fi
    sleep 2
  done
}

# 監視器:挑幾台,在一個 'monitor' window 裡 tiled 一起看(tail -F 各自的 log)。
# 非破壞性 — 不動原本的裝置 window;需要 log 開著(預設 open 就開)。
action_monitor() {
  local sel="$*" logd label p win i first
  logd="$(log_dir)"
  [[ -n "$logd" && -f "$logd/.devices" ]] || {
    tmux display-message "監視器需要已 open 的 session"
    return
  }
  local DEVS=()
  mapfile -t DEVS <"$logd/.devices"
  local max=${#DEVS[@]} pos=()
  mapfile -t pos < <(expand_selection "$sel" "$max")
  ((${#pos[@]})) || {
    tmux display-message "沒有有效選擇(用 1-4 / 1,3,5 / all)"
    return
  }
  local mname="mon-${sel// /}"                     # 名稱含選擇 → 多個監視器可並存
  tmux kill-window -t "$SESSION:$mname" 2>/dev/null # 同樣選擇的才覆蓋,不同的並存
  local title
  first="${pos[0]}"
  label="${DEVS[first - 1]}"
  printf -v title '%02d  %s' "$first" "$label"
  # _montail = tail + 在邊框標題顯示「有沒有在動」(●live / ⏸停Ns / 無log)
  win="$(tmux new-window -t "$SESSION" -n "$mname" -P -F '#{window_id}' \
    "exec '$SELF' _montail '$title' '$logd/${label}.log'")"
  tmux set-option -w -t "$win" pane-border-status top
  tmux set-option -w -t "$win" pane-border-format ' #{pane_title} '
  for i in "${pos[@]:1}"; do
    label="${DEVS[i - 1]}"
    printf -v title '%02d  %s' "$i" "$label"
    p="$(tmux split-window -t "$win" -P -F '#{pane_id}' \
      "exec '$SELF' _montail '$title' '$logd/${label}.log'")"
    tmux select-layout -t "$win" tiled >/dev/null
  done
  tmux select-layout -t "$win" tiled >/dev/null
  tmux select-window -t "$win"
  tmux display-message "監視器 [$mname]:${#pos[@]} 台 — Prefix M 關閉"
}

# 關閉監視器:在某個監視器裡按 → 只關那個;在裝置 window 按 → 關全部監視器
action_monitor_close() {
  local winid="$1" winname="${2:-}"
  if [[ "$winname" == mon-* ]]; then
    tmux kill-window -t "$winid" 2>/dev/null && tmux display-message "已關閉 $winname"
    return
  fi
  local id name n=0
  while IFS='|' read -r id name; do
    [[ "$name" == mon-* ]] || continue
    tmux kill-window -t "$id" 2>/dev/null && n=$((n + 1))
  done < <(tmux list-windows -t "$SESSION" -F '#{window_id}|#{window_name}')
  ((n)) && tmux display-message "關閉 $n 個監視器" || tmux display-message "沒有開著的監視器"
}

# 收合/展開左欄:把該 window 的 device pane zoom 全螢幕（蓋住左欄）/還原
action_toggle_side() {
  local win="$1" dev
  dev="$(tmux list-panes -t "$win" -F '#{pane_id}|#{@gtmux}' 2>/dev/null \
    | awk -F'|' '$2=="dev"{print $1}')"
  [[ -n "$dev" ]] && tmux resize-pane -Z -t "$dev"
}

# 全部 window 一起收合/展開:任何一個還展開著 → 全部收合;否則全部展開
action_toggle_side_all() {
  local win dev z want=0
  while read -r win; do
    z="$(tmux display -t "$win" -p '#{window_zoomed_flag}' 2>/dev/null)"
    [[ "$z" == 1 ]] || want=1 # 有任一展開 → 目標=全部收合(zoom)
  done < <(tmux list-windows -t "$SESSION" -F '#{window_id}')
  while read -r win; do
    z="$(tmux display -t "$win" -p '#{window_zoomed_flag}' 2>/dev/null)"
    dev="$(tmux list-panes -t "$win" -F '#{pane_id}|#{@gtmux}' | awk -F'|' '$2=="dev"{print $1}')"
    [[ -n "$dev" ]] || continue
    { [[ "$want" == 1 && "$z" != 1 ]] || [[ "$want" == 0 && "$z" == 1 ]]; } &&
      tmux resize-pane -Z -t "$dev"
  done < <(tmux list-windows -t "$SESSION" -F '#{window_id}')
}

# 改 log 路徑:建立新目錄、存進 session 選項、把所有裝置的 pipe 重新指過去
action_logpath() {
  local base="$*" d p ip n=0
  [[ -n "$base" ]] || return 0
  base="${base/#\~/$HOME}" # 展開開頭的 ~
  d="$base/$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$d" || {
    tmux display-message "無法建立: $d"
    return
  }
  set_log_dir "$d"
  while read -r p ip; do
    [[ -n "$p" ]] || continue
    tmux pipe-pane -t "$p" "cat >> '$d/${ip}.log'"
    n=$((n + 1))
  done < <(dev_panes)
  tmux display-message "log 路徑改為 $d（$n 台已重新指向）"
}

bind_keys() {
  # 換台:Prefix ↑↓
  tmux bind-key -T prefix Up previous-window
  tmux bind-key -T prefix Down next-window
  # 廣播({}=該台IP/名 {n}=編號):b 打完即送、B 只打不送、Enter 對全部送出
  tmux bind-key -T prefix b command-prompt -p "廣播+送出:" \
    "run-shell -b '$SELF _bcast 1 \"%%\"'"
  tmux bind-key -T prefix B command-prompt -p "廣播不送出:" \
    "run-shell -b '$SELF _bcast 0 \"%%\"'"
  tmux bind-key -T prefix Enter run-shell -b "$SELF _enterall"
  # 收合/展開左欄:Prefix e(目前這台)、Prefix E(全部 window 一起)
  tmux bind-key -T prefix e run-shell "$SELF _toggle_side '#{window_id}'"
  tmux bind-key -T prefix E run-shell -b "$SELF _toggle_side_all"
  # 監視器:Prefix m 開(挑幾台)、Prefix M 關
  tmux bind-key -T prefix m command-prompt -p "監視:" \
    "run-shell -b '$SELF _monitor \"%%\"'"
  tmux bind-key -T prefix M run-shell "$SELF _monitor_close '#{window_id}' '#{window_name}'"
  # 選單:Prefix Space
  tmux bind-key "$MENU_KEY" display-menu -T "#[align=centre] gtmux " \
    "廣播+送出({}台 {n}號)" b "command-prompt -p '廣播+送出:' \"run-shell -b '$SELF _bcast 1 \\\"%%\\\"'\"" \
    "廣播不送出(待確認)" B "command-prompt -p '廣播不送出:' \"run-shell -b '$SELF _bcast 0 \\\"%%\\\"'\"" \
    "對全部送出 Enter(執行)" r "run-shell -b '$SELF _enterall'" \
    "全部 ssh 連線" c "run-shell -b '$SELF _ssh_all'" \
    "收合/展開左欄(此台)" e "run-shell '$SELF _toggle_side \"#{window_id}\"'" \
    "收合/展開左欄(全部)" E "run-shell -b '$SELF _toggle_side_all'" \
    "監視器:挑幾台一起看" m "command-prompt -p '監視:' \"run-shell -b '$SELF _monitor \\\"%%\\\"'\"" \
    "關閉監視器(此/全部)" M "run-shell '$SELF _monitor_close \"#{window_id}\" \"#{window_name}\"'" \
    "" \
    "開始全機 log" l "run-shell -b '$SELF _log_start'" \
    "停止全機 log" k "run-shell -b '$SELF _log_stop'" \
    "改 log 路徑" L "command-prompt -p 'log 路徑:' \"run-shell -b '$SELF _logpath \\\"%%\\\"'\"" \
    "清 log 雜訊" C "run-shell -b '$SELF _clean'" \
    "" \
    "上一台" p "previous-window" \
    "下一台" n "next-window" \
    "" \
    "離開(保留 session,可 attach 回來)" d "detach-client" \
    "關閉並刪除 session" x "kill-session -t $SESSION"
}

# ---- dispatch ---------------------------------------------------------------

case "${1:-open}" in
open)
  shift
  action_open "$@"
  ;;
attach) tmux attach -t "$SESSION" ;;
kill) tmux kill-session -t "$SESSION" 2>/dev/null && echo killed || echo "session 不存在" ;;
rebind) bind_keys && echo "已重新綁定快捷鍵" ;;
help | -h | --help) sed -n '2,33p' "$SELF" | sed 's/^#\{0,1\} \{0,1\}//' ;;
_sidebar)
  shift
  action_sidebar "$@"
  ;;
_bcast)
  shift
  action_bcast "$@"
  ;;
_enterall) action_enterall ;;
_ssh_all) action_ssh_all ;;
_log_start) action_log_start ;;
_log_stop) action_log_stop ;;
_clean) action_clean ;;
_toggle_side)
  shift
  action_toggle_side "$@"
  ;;
_toggle_side_all) action_toggle_side_all ;;
_monitor)
  shift
  action_monitor "$@"
  ;;
_montail)
  shift
  action_montail "$@"
  ;;
_monitor_close)
  shift
  action_monitor_close "$@"
  ;;
_logpath)
  shift
  action_logpath "$@"
  ;;
*)
  echo "usage: $0 [open [-n N] [-p PREFIX] [-l LOGPATH] | attach | kill | help]" >&2
  exit 2
  ;;
esac
