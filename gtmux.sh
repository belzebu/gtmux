#!/usr/bin/env bash
# gtmux — a keyboard-light tmux multi-host manager (pure tmux, no plugins).
#
# One window per host, split [ sidebar | host shell ]. The sidebar is always
# there, lists every host, highlights the current one. Nothing to memorize:
#
#   Prefix(Ctrl+B) + ↑ / ↓   previous / next host
#   Prefix + 1-9 / '         jump to a host by its number
#   Prefix + Space           menu (broadcast / ssh / log / monitor / close)
#   Prefix + b / B / Enter    broadcast+send / broadcast-no-send / send Enter all
#   Prefix + m / M           open monitor (pick hosts) / close monitor
#   Prefix + e / E           collapse sidebar (this host / all)
#
# `open` only lays out the panes (plain shells, no auto-ssh); connect via menu.
#
# Usage:
#   gtmux open                # read ip.txt, lay out, enter
#   gtmux open -n 5           # N blank panes (no ip.txt), numbered 1..5
#   gtmux open -n 5 -p dut-   # N panes labelled dut-1 .. dut-5
#   gtmux open -l /tmp/logs   # log dir (default: ./)
#   gtmux attach              # re-enter
#   gtmux kill                # destroy the session
#   gtmux help                # this help
#
# Env: GTMUX_SESSION=gtmux  GTMUX_KEY=Space  IPS_FILE=./ip.txt  LOGROOT=.
#      GTMUX_SIDEBAR_W=20%   GTMUX_MON_FRESH=3   GTMUX_LANG=zh|en|auto
set -u

SESSION="${GTMUX_SESSION:-gtmux}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$DIR/$(basename "${BASH_SOURCE[0]}")" # absolute + rename-proof
IPS_FILE="${IPS_FILE:-$DIR/ip.txt}"
LOGROOT="${LOGROOT:-.}"
MENU_KEY="${GTMUX_KEY:-Space}"
SIDEBAR_W="${GTMUX_SIDEBAR_W:-20%}" # % scales with the screen; or fixed cols e.g. 30
MON_FRESH="${GTMUX_MON_FRESH:-3}"   # monitor: log mtime within N s counts as ●live
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# ---- i18n -------------------------------------------------------------------
# All user-facing strings live in one table per language. Default is zh;
# set GTMUX_LANG=en to force English, or GTMUX_LANG=auto to detect from $LANG.
GTMUX_LANG="${GTMUX_LANG:-zh}"
if [[ "$GTMUX_LANG" == auto ]]; then
  case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
  zh* | *[._]zh* | *ZH*) GTMUX_LANG=zh ;;
  *) GTMUX_LANG=en ;;
  esac
fi

declare -A T
load_lang() {
  if [[ "$GTMUX_LANG" == zh ]]; then
    T=(
    [hosts]="台" [monitors]="監視器" [no_ipfile_short]="(無ip.txt)"
    [h_jump]="Pfx 1-9 跳台" [h_jumpn]="Pfx ' 編號跳" [h_updown]="Pfx ↑↓ 換台"
    [h_collapse]="Pfx e/E 收左欄" [h_mon]="Pfx m 監視/M 關"
    [h_bcast]="Pfx b 廣播/B 不送" [h_enter]="Pfx Enter 全送出" [h_menu]="Pfx Spc 選單"
    [mon_live]="●live" [mon_stop]="⏸停%ds" [mon_nolog]="(無log)"
    [m_bcast_send]="廣播+送出({}台 {n}號)" [m_bcast_nosend]="廣播不送出(待確認)"
    [m_enterall]="對全部送出 Enter(執行)" [m_ssh]="全部 ssh 連線"
    [m_collapse_one]="收合/展開左欄(此台)" [m_collapse_all]="收合/展開左欄(全部)"
    [m_monitor]="監視器:挑幾台一起看" [m_monitor_close]="關閉監視器(此/全部)"
    [m_log_start]="開始全機 log" [m_log_stop]="停止全機 log"
    [m_logpath]="改 log 路徑" [m_clean]="清 log 雜訊"
    [m_prev]="上一台" [m_next]="下一台"
    [m_lang]="切換語言(中/英)" [lang_set]="語言:%s"
    [m_detach]="離開(保留 session,可 attach 回來)" [m_kill]="關閉並刪除 session"
    [p_bcast_send]="廣播+送出:" [p_bcast_nosend]="廣播不送出:"
    [p_monitor]="監視:" [p_logpath]="log 路徑:" [p_bcastkey]="按鍵(如 C-c):"
    [m_ctrlc]="送 Ctrl-C 給全部" [m_bcastkey]="廣播按鍵(C-c/Esc/F5…)"
    [key_sent]="已對 %d 台送按鍵:%s"
    [bcast_sent]="已廣播並送出 → %d 台"
    [bcast_typed]="已打入(未送出)→ %d 台;Prefix Enter 一起送出"
    [enter_sent]="已對 %d 台送出 Enter" [ssh_sent]="已對 %d 台送出 ssh"
    [log_started]="全機 log 開始(%d 台)→ %s" [log_stopped]="全機 log 已停止(%d 台)"
    [no_logdir]="找不到 log 目錄" [cleaned]="清好 %d 檔 → %s/*.clean.txt"
    [mon_need_open]="監視器需要已 open 的 session"
    [mon_badsel]="沒有有效選擇(1-4 / 1,3,5 / all)"
    [mon_opened]="監視器 [%s]:%d 台 — Prefix M 關閉"
    [mon_closed_one]="已關閉 %s" [mon_closed_n]="關閉 %d 個監視器"
    [mon_none]="沒有開著的監視器"
    [logpath_changed]="log 路徑改為 %s(%d 台已重指)" [mkdir_fail]="無法建立: %s"
    [err_no_ipfile]="找不到 %s" [err_empty_ipfile]="%s 沒有任何主機"
    [err_count]="-n 需要正整數: %s"
    [setup_prompt]="沒有 ip.txt — 輸入主機數量,或清單檔路徑(空白取消):"
    [setup_cancel]="已取消" [setup_badfile]="不是數字也不是可讀檔: %s"
    [note_prefix]="註:-p 只在 -n 模式有效,ip.txt 模式忽略"
    [err_session_exists]="session '%s' 已存在 → '%s attach' 或 '%s kill'"
    [err_mkdir_log]="無法建立 log 目錄: %s"
    [opened]="已開 %d 台(焦點模式,純 shell 未 ssh)。log → %s/<host>.log"
    [opened_hint]="進入後:Prefix ↑↓ 換台 · Prefix+%s 選單 · Prefix b 廣播"
    [no_session]="session 不存在" [rebound]="已重新綁定快捷鍵"
    [status_right]="Prefix+%s 選單 · Prefix ↑↓ 換台 · Prefix b 廣播"
  )
else
  T=(
    [hosts]="hosts" [monitors]="Monitors" [no_ipfile_short]="(no ip.txt)"
    [h_jump]="Pfx 1-9 jump" [h_jumpn]="Pfx ' by num" [h_updown]="Pfx ↑↓ switch"
    [h_collapse]="Pfx e/E collapse" [h_mon]="Pfx m mon/M close"
    [h_bcast]="Pfx b cast/B hold" [h_enter]="Pfx Enter run all" [h_menu]="Pfx Spc menu"
    [mon_live]="●live" [mon_stop]="⏸%ds idle" [mon_nolog]="(no log)"
    [m_bcast_send]="broadcast + send ({}=host {n}=num)" [m_bcast_nosend]="broadcast, no send (review)"
    [m_enterall]="send Enter to all (run)" [m_ssh]="ssh all hosts"
    [m_collapse_one]="collapse sidebar (this)" [m_collapse_all]="collapse sidebar (all)"
    [m_monitor]="monitor: watch several" [m_monitor_close]="close monitor (this/all)"
    [m_log_start]="start logging (all)" [m_log_stop]="stop logging (all)"
    [m_logpath]="change log path" [m_clean]="clean log ANSI"
    [m_prev]="previous host" [m_next]="next host"
    [m_lang]="Language (zh / en)" [lang_set]="language: %s"
    [m_detach]="detach (keep session, attach later)" [m_kill]="kill session"
    [p_bcast_send]="broadcast+send:" [p_bcast_nosend]="broadcast, no send:"
    [p_monitor]="monitor:" [p_logpath]="log path:" [p_bcastkey]="key (e.g. C-c):"
    [m_ctrlc]="send Ctrl-C to all" [m_bcastkey]="broadcast a key (C-c/Esc/F5…)"
    [key_sent]="sent key to %d hosts: %s"
    [bcast_sent]="broadcast + sent → %d hosts"
    [bcast_typed]="typed (not sent) → %d hosts; Prefix Enter to run"
    [enter_sent]="sent Enter to %d hosts" [ssh_sent]="sent ssh to %d hosts"
    [log_started]="logging on (%d hosts) → %s" [log_stopped]="logging off (%d hosts)"
    [no_logdir]="no log dir" [cleaned]="cleaned %d files → %s/*.clean.txt"
    [mon_need_open]="monitor needs an open session"
    [mon_badsel]="no valid selection (1-4 / 1,3,5 / all)"
    [mon_opened]="monitor [%s]: %d hosts — Prefix M to close"
    [mon_closed_one]="closed %s" [mon_closed_n]="closed %d monitors"
    [mon_none]="no open monitor"
    [logpath_changed]="log path → %s (%d hosts repointed)" [mkdir_fail]="cannot create: %s"
    [err_no_ipfile]="not found: %s" [err_empty_ipfile]="%s has no hosts"
    [err_count]="-n needs a positive integer: %s"
    [setup_prompt]="No ip.txt — number of hosts, or a host-file path (blank cancels):"
    [setup_cancel]="cancelled" [setup_badfile]="not a number or a readable file: %s"
    [note_prefix]="note: -p only applies with -n; ignored for ip.txt"
    [err_session_exists]="session '%s' exists → '%s attach' or '%s kill'"
    [err_mkdir_log]="cannot create log dir: %s"
    [opened]="opened %d hosts (focus mode, plain shells, no ssh). log → %s/<host>.log"
    [opened_hint]="inside: Prefix ↑↓ switch · Prefix+%s menu · Prefix b broadcast"
    [no_session]="no such session" [rebound]="keys rebound"
    [status_right]="Prefix+%s menu · Prefix ↑↓ switch · Prefix b broadcast"
  )
  fi
}
# t  KEY        → plain string (direct, no fork in hot paths use ${T[KEY]})
# tf KEY args.. → printf the template with args (for %d/%s messages)
t() { printf '%s' "${T[$1]:-$1}"; }
tf() { printf "${T[$1]:-$1}" "${@:2}"; }

# A running session's chosen language (set by open / the live switch) wins over
# the env, so subprocesses follow the session.
_sl="$(tmux show-option -t "$SESSION" -qv @gtmux_lang 2>/dev/null)"
[[ -n "$_sl" ]] && GTMUX_LANG="$_sl"
unset _sl
load_lang

# Re-pick the session language; reload the table if it changed. Used by the
# long-running sidebar / monitor loops so a live switch reaches them.
sync_lang() {
  local l
  l="$(tmux show-option -t "$SESSION" -qv @gtmux_lang 2>/dev/null)"
  [[ -n "$l" && "$l" != "$GTMUX_LANG" ]] || return 1
  GTMUX_LANG="$l"
  load_lang
  return 0
}

# ---- helpers ----------------------------------------------------------------

read_ips() {
  [[ -r "$IPS_FILE" ]] || {
    tf err_no_ipfile "$IPS_FILE" >&2
    echo >&2
    return 1
  }
  mapfile -t IPS < <(sed 's/#.*//' "$IPS_FILE" | tr -d '[:blank:]' | grep -vE '^$')
  ((${#IPS[@]})) || {
    tf err_empty_ipfile "$IPS_FILE" >&2
    echo >&2
    return 1
  }
}

has_session() { tmux has-session -t "$SESSION" 2>/dev/null; }
log_dir() { tmux show-option -t "$SESSION" -qv @gtmux_logdir 2>/dev/null; }
set_log_dir() { tmux set-option -t "$SESSION" @gtmux_logdir "$1"; }

# Sidebar width in cells for a window of width $1 (handles % or fixed, clamped
# so it never vanishes and always leaves room for the host pane). Absolute cells
# work on every tmux version, unlike split-window -l <pct>% (needs ≥3.1).
_sidebar_cols() {
  local w="$1" c
  if [[ "$SIDEBAR_W" == *% ]]; then c=$((w * ${SIDEBAR_W%\%} / 100)); else c="$SIDEBAR_W"; fi
  ((c < 8)) && c=8
  ((c > w - 12)) && c=$((w - 12))
  ((c < 1)) && c=1
  echo "$c"
}

# Expand a selection (1-4 / 1,3,5 / 1-3,7 / all) to 1-based positions in 1..max.
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

# All host panes (excludes the sidebar): "pane_id|label|window_index" per line.
dev_panes() {
  tmux list-panes -s -t "$SESSION" -F '#{pane_id}|#{@gtmux}|#{pane_title}|#{window_index}' 2>/dev/null |
    awk -F'|' '$2=="dev"{print $1"|"$3"|"$4}'
}

# foreach_dev FN — run FN(pane_id, label, window_index) for every host pane.
# Sets DEV_N to the count. (One place that knows how to iterate hosts.)
DEV_N=0
foreach_dev() {
  local fn="$1" p ip widx
  DEV_N=0
  while IFS='|' read -r p ip widx; do
    [[ -n "$p" ]] || continue
    "$fn" "$p" "$ip" "$widx"
    DEV_N=$((DEV_N + 1))
  done < <(dev_panes)
}

# ---- open (focus mode) ------------------------------------------------------

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
  # left sidebar pane; pass idx(highlight) base(number) ipfile session(monitor list)
  side="$(tmux split-window -h -b -l "${_SBW:-$SIDEBAR_W}" -t "$dev" -P -F '#{pane_id}' \
    "exec '$SELF' _sidebar '$idx' '$base' '$IPS_FILE' '$SESSION'")"
  tmux set -p -t "$side" @gtmux side
  tmux set -p -t "$dev" @gtmux dev
  tmux select-pane -t "$dev" -T "$ip"
  tmux pipe-pane -t "$dev" "cat >> '$d/${ip}.log'" # logging on from start
  tmux select-pane -t "$dev"                       # focus the host shell, not sidebar
}

action_open() {
  # -n N manual N panes   -p PREFIX label prefix (dut- → dut-1)   -l PATH log dir
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

  # Decide the host list: -n N (manual) / ip.txt / interactive setup if neither.
  if [[ -n "$count" ]]; then
    : # validated + generated below
  elif read_ips 2>/dev/null; then
    [[ -n "$prefix" ]] && {
      t note_prefix >&2
      echo >&2
    }
  elif [[ -t 0 ]]; then
    # no usable ip.txt and no -n, but we have a terminal → ask
    tf err_no_ipfile "$IPS_FILE" >&2
    echo >&2
    local ans
    read -rp "$(t setup_prompt) " ans
    if [[ -z "$ans" ]]; then
      t setup_cancel >&2
      echo >&2
      return 1
    elif [[ "$ans" =~ ^[0-9]+$ ]]; then
      count="$ans"
    elif [[ -r "$ans" ]]; then
      IPS_FILE="$ans"
      read_ips || return 1
    else
      tf setup_badfile "$ans" >&2
      echo >&2
      return 1
    fi
  else
    read_ips || return 1 # non-interactive: surface the real error
  fi

  # Generate labels from a count (set by -n or by interactive setup).
  if [[ -n "$count" ]]; then
    if ! [[ "$count" =~ ^[0-9]+$ ]] || ((count < 1)); then
      tf err_count "$count" >&2
      echo >&2
      return 1
    fi
    IPS=()
    local k
    for ((k = 1; k <= count; k++)); do IPS+=("${prefix}${k}"); done
  fi

  if has_session; then
    tf err_session_exists "$SESSION" "$0" "$0" >&2
    echo >&2
    return 1
  fi
  local ts d ip
  ts="$(date +%Y%m%d_%H%M%S)"
  d="$LOGROOT/$ts"
  mkdir -p "$d" || {
    tf err_mkdir_log "$d" >&2
    echo >&2
    return 1
  }
  # freeze the host list into the log dir; the sidebar reads this one copy
  printf '%s\n' "${IPS[@]}" >"$d/.devices"
  IPS_FILE="$d/.devices"

  # Build the session at the REAL terminal size so the sidebar isn't squeezed
  # when attaching to a narrow window (don't build wide then shrink).
  local cols lines
  cols="$(tput cols 2>/dev/null)"
  [[ "$cols" =~ ^[0-9]+$ ]] && ((cols >= 40)) || cols=200
  lines="$(tput lines 2>/dev/null)"
  [[ "$lines" =~ ^[0-9]+$ ]] && ((lines >= 10)) || lines=50
  local _SBW
  _SBW="$(_sidebar_cols "$cols")"

  tmux new-session -d -s "$SESSION" -x "$cols" -y "$lines"
  set_log_dir "$d"
  tmux set-environment -t "$SESSION" GTMUX_LANG "$GTMUX_LANG" # children inherit language
  # keep the sidebar proportional when the terminal is resized later
  tmux set-hook -t "$SESSION" client-resized "run-shell -b '$SELF _relayout'" 2>/dev/null || true
  # 1-based windows so Prefix+1 = first host
  tmux set -t "$SESSION" base-index 1 2>/dev/null || true
  tmux set -t "$SESSION" pane-base-index 1 2>/dev/null || true
  tmux move-window -r -t "$SESSION" 2>/dev/null || true
  tmux set -t "$SESSION" mouse on 2>/dev/null || true
  tmux set -t "$SESSION" pane-border-status off 2>/dev/null || true

  local i base
  base="$(tmux list-windows -t "$SESSION" -F '#{window_index}' | head -1)"
  for i in "${!IPS[@]}"; do build_window "$i" "${IPS[$i]}" "$d" "$base"; done

  bind_keys
  tmux select-window -t "${SESSION}:${base}"
  tmux set -t "$SESSION" status-left "#[bold] gtmux #[default]"
  tmux set -t "$SESSION" status-right "$(tf status_right "$MENU_KEY")"

  tf opened "${#IPS[@]}" "$d"
  echo
  tf opened_hint "$MENU_KEY"
  echo
  [[ -z "${TMUX:-}" ]] && tmux attach -t "$SESSION"
}

# ---- sidebar (runs as the left pane's own process) --------------------------

action_sidebar() {
  local cur="$1" base="${2:-0}" ipf="${3:-}" sess="${4:-}"
  [[ -n "$ipf" ]] && IPS_FILE="$ipf"
  [[ -n "$sess" ]] && SESSION="$sess"
  sync_lang || true # follow the session language now that SESSION is known
  read_ips 2>/dev/null || IPS=("${T[no_ipfile_short]}")
  render_sidebar() {
    printf '\033[H\033[2J'
    printf ' \033[1mgtmux\033[0m\n'
    printf ' \033[2m%s %s\033[0m\n' "${#IPS[@]}" "${T[hosts]}"
    printf ' ────────────────\n'
    # width of this sidebar pane → truncate labels so each host is one line
    local sw avail i num lbl
    sw="$(tmux display -p -t "${TMUX_PANE:-}" '#{pane_width}' 2>/dev/null)"
    [[ "$sw" =~ ^[0-9]+$ ]] || sw=20
    avail=$((sw - 9)) # widest line is the reverse-video current row
    ((avail < 0)) && avail=0
    for i in "${!IPS[@]}"; do
      num=$((base + i)) # = tmux window number = the Prefix+N to press
      lbl="${IPS[$i]}"
      ((${#lbl} > avail)) && lbl="${lbl:0:avail}"
      if ((i == cur)); then
        printf ' \033[7m %02d ▸ %s \033[0m\n' "$num" "$lbl"
      else
        printf ' \033[36m%02d\033[0m   \033[2m%s\033[0m\n' "$num" "$lbl"
      fi
    done
    # monitors (dynamic): windows named mon-*, jump with Prefix+their number
    local mons widx wname
    mons="$(tmux list-windows -t "$SESSION" -F '#{window_index}|#{window_name}' 2>/dev/null |
      awk -F'|' '$2 ~ /^mon-/')"
    if [[ -n "$mons" ]]; then
      printf ' ────────────────\n'
      printf ' \033[1m%s\033[0m\n' "${T[monitors]}"
      while IFS='|' read -r widx wname; do
        [[ -n "$widx" ]] || continue
        printf ' \033[33m%02d\033[0m \033[2m%s\033[0m\n' "$widx" "${wname#mon-}"
      done <<<"$mons"
    fi
    # Only show the key hints if the sidebar is wide enough; on a narrow pane
    # they would wrap one char per line, so drop them and keep the host list.
    if ((sw >= 15)); then
      printf ' ────────────────\n'
      printf ' \033[2m%s\033[0m\n' "${T[h_jump]}"
      printf ' \033[2m%s\033[0m\n' "${T[h_jumpn]}"
      printf ' \033[2m%s\033[0m\n' "${T[h_updown]}"
      printf ' \033[2m%s\033[0m\n' "${T[h_collapse]}"
      printf ' \033[2m%s\033[0m\n' "${T[h_mon]}"
      printf ' \033[2m%s\033[0m\n' "${T[h_bcast]}"
      printf ' \033[2m%s\033[0m\n' "${T[h_enter]}"
      printf ' \033[2m%s\033[0m\n' "${T[h_menu]}"
    fi
  }
  # redraw every 2s but only repaint when content changed (no flicker)
  local _last=""
  trap '_last=' WINCH
  while :; do
    sync_lang && _last="" # language switched live → force a repaint
    local c
    c="$(render_sidebar)"
    if [[ "$c" != "$_last" ]]; then
      printf '%s' "$c"
      _last="$c"
    fi
    sleep 2
  done
}

# ---- actions over all host panes (foreach_dev callbacks) --------------------

# Broadcast one command to all hosts. Placeholders substituted per host before
# sending:  {} → that host's label   {n} → that host's number
_BC_ENTER=1
_BC_TMPL=""
_cb_bcast() {
  local cmd="$_BC_TMPL"
  cmd="${cmd//\{\}/$2}"
  cmd="${cmd//\{n\}/$3}"
  if [[ "$_BC_ENTER" == 1 ]]; then
    tmux send-keys -t "$1" "$cmd" Enter
  else
    tmux send-keys -t "$1" "$cmd"
  fi
}
action_bcast() {
  _BC_ENTER="$1"
  shift
  _BC_TMPL="$*"
  [[ -n "$_BC_TMPL" ]] || return 0
  foreach_dev _cb_bcast
  if [[ "$_BC_ENTER" == 1 ]]; then
    tmux display-message "$(tf bcast_sent "$DEV_N")"
  else
    tmux display-message "$(tf bcast_typed "$DEV_N")"
  fi
}

_cb_enter() { tmux send-keys -t "$1" Enter; }
action_enterall() {
  foreach_dev _cb_enter
  tmux display-message "$(tf enter_sent "$DEV_N")"
}

# Broadcast a key (not literal text) to all hosts, e.g. C-c, C-d, Escape, Up, F5.
# Space-separated keys are sent in order (tmux send-keys key syntax).
_BK_KEYS=()
_cb_bkey() { tmux send-keys -t "$1" "${_BK_KEYS[@]}"; }
action_bcastkey() {
  # shellcheck disable=SC2206  # intentional word-split: each token is a key name
  _BK_KEYS=($*)
  ((${#_BK_KEYS[@]})) || return 0
  foreach_dev _cb_bkey
  tmux display-message "$(tf key_sent "$DEV_N" "${_BK_KEYS[*]}")"
}

_cb_ssh() { tmux send-keys -t "$1" "ssh $SSH_OPTS $2" Enter; }
action_ssh_all() {
  foreach_dev _cb_ssh
  tmux display-message "$(tf ssh_sent "$DEV_N")"
}

_LOGD=""
_cb_logon() { tmux pipe-pane -t "$1" "cat >> '$_LOGD/${2}.log'"; }
_cb_logoff() { tmux pipe-pane -t "$1"; }
action_log_start() {
  _LOGD="$(log_dir)"
  [[ -d "$_LOGD" ]] || {
    _LOGD="$LOGROOT/manual_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$_LOGD"
    set_log_dir "$_LOGD"
  }
  foreach_dev _cb_logon
  tmux display-message "$(tf log_started "$DEV_N" "$_LOGD")"
}
action_log_stop() {
  foreach_dev _cb_logoff
  tmux display-message "$(tf log_stopped "$DEV_N")"
}

action_clean() {
  local d f out n=0
  d="$(log_dir)"
  [[ -d "$d" ]] || {
    tmux display-message "$(t no_logdir)"
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
  tmux display-message "$(tf cleaned "$n" "$d")"
}

# ---- monitor ----------------------------------------------------------------

# One monitor pane: tail the log in the background, and every 2s reflect log
# freshness in the pane's border title (●live / idle Ns / no log).
action_montail() {
  local title="$1" file="$2" pane="${TMUX_PANE:-}" tpid mtime now age
  tail -n 200 -F "$file" 2>/dev/null &
  tpid=$!
  trap 'kill "$tpid" 2>/dev/null' EXIT INT TERM
  while :; do
    sync_lang || true # keep freshness labels in the session language
    if [[ -f "$file" ]]; then
      mtime="$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null)"
      now="$(date +%s)"
      if [[ -n "$mtime" ]]; then
        age=$((now - mtime))
        if ((age <= MON_FRESH)); then
          tmux select-pane -t "$pane" -T "$title  ${T[mon_live]}" 2>/dev/null
        else
          tmux select-pane -t "$pane" -T "$title  $(tf mon_stop "$age")" 2>/dev/null
        fi
      fi
    else
      tmux select-pane -t "$pane" -T "$title  ${T[mon_nolog]}" 2>/dev/null
    fi
    sleep 2
  done
}

# Pick several hosts, tile them in one 'mon-<sel>' window (tail -F each log).
# Non-destructive — the real host windows are untouched. Multiple can coexist.
action_monitor() {
  local sel="$*" logd label p win i first
  logd="$(log_dir)"
  [[ -n "$logd" && -f "$logd/.devices" ]] || {
    tmux display-message "$(t mon_need_open)"
    return
  }
  local DEVS=()
  mapfile -t DEVS <"$logd/.devices"
  local max=${#DEVS[@]} pos=()
  mapfile -t pos < <(expand_selection "$sel" "$max")
  ((${#pos[@]})) || {
    tmux display-message "$(t mon_badsel)"
    return
  }
  local mname="mon-${sel// /}"                      # name carries the selection
  tmux kill-window -t "$SESSION:$mname" 2>/dev/null # same selection replaces, others coexist
  local title
  first="${pos[0]}"
  label="${DEVS[first - 1]}"
  printf -v title '%02d  %s' "$first" "$label"
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
  tmux display-message "$(tf mon_opened "$mname" "${#pos[@]}")"
}

# In a monitor → close just it; in a host window → close every monitor.
action_monitor_close() {
  local winid="$1" winname="${2:-}"
  if [[ "$winname" == mon-* ]]; then
    tmux kill-window -t "$winid" 2>/dev/null && tmux display-message "$(tf mon_closed_one "$winname")"
    return
  fi
  local id name n=0
  while IFS='|' read -r id name; do
    [[ "$name" == mon-* ]] || continue
    tmux kill-window -t "$id" 2>/dev/null && n=$((n + 1))
  done < <(tmux list-windows -t "$SESSION" -F '#{window_id}|#{window_name}')
  ((n)) && tmux display-message "$(tf mon_closed_n "$n")" || tmux display-message "$(t mon_none)"
}

# ---- sidebar collapse -------------------------------------------------------

# Collapse/expand the sidebar by zooming this window's host pane.
action_toggle_side() {
  local win="$1" dev
  dev="$(tmux list-panes -t "$win" -F '#{pane_id}|#{@gtmux}' 2>/dev/null |
    awk -F'|' '$2=="dev"{print $1}')"
  [[ -n "$dev" ]] && tmux resize-pane -Z -t "$dev"
}

# All windows together: any expanded → collapse all; else expand all.
action_toggle_side_all() {
  local win dev z want=0
  while read -r win; do
    z="$(tmux display -t "$win" -p '#{window_zoomed_flag}' 2>/dev/null)"
    [[ "$z" == 1 ]] || want=1
  done < <(tmux list-windows -t "$SESSION" -F '#{window_id}')
  while read -r win; do
    z="$(tmux display -t "$win" -p '#{window_zoomed_flag}' 2>/dev/null)"
    dev="$(tmux list-panes -t "$win" -F '#{pane_id}|#{@gtmux}' | awk -F'|' '$2=="dev"{print $1}')"
    [[ -n "$dev" ]] || continue
    { [[ "$want" == 1 && "$z" != 1 ]] || [[ "$want" == 0 && "$z" == 1 ]]; } &&
      tmux resize-pane -Z -t "$dev"
  done < <(tmux list-windows -t "$SESSION" -F '#{window_id}')
}

# ---- change log path --------------------------------------------------------

action_logpath() {
  local base="$*" d
  [[ -n "$base" ]] || return 0
  base="${base/#\~/$HOME}"
  d="$base/$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$d" || {
    tmux display-message "$(tf mkdir_fail "$d")"
    return
  }
  set_log_dir "$d"
  _LOGD="$d"
  foreach_dev _cb_logon
  tmux display-message "$(tf logpath_changed "$d" "$DEV_N")"
}

# ---- key bindings -----------------------------------------------------------

# Re-fit every window's sidebar to the current terminal width (resize hook).
action_relayout() {
  local win ww side cols
  while read -r win ww; do
    [[ "$ww" =~ ^[0-9]+$ ]] || continue
    side="$(tmux list-panes -t "$win" -F '#{pane_id}|#{@gtmux}' 2>/dev/null |
      awk -F'|' '$2=="side"{print $1}')"
    [[ -n "$side" ]] || continue
    cols="$(_sidebar_cols "$ww")"
    tmux resize-pane -t "$side" -x "$cols" 2>/dev/null || true
  done < <(tmux list-windows -t "$SESSION" -F '#{window_id} #{window_width}')
}

# Live language switch from the menu. Stores the choice on the session so the
# sidebar/monitor loops pick it up, rebinds the menu, refreshes the status line.
action_setlang() {
  local mode="${1:-toggle}" sess="${2:-}" cur new
  [[ -n "$sess" ]] && SESSION="$sess"
  cur="$(tmux show-option -t "$SESSION" -qv @gtmux_lang 2>/dev/null)"
  [[ -n "$cur" ]] || cur="$GTMUX_LANG"
  case "$mode" in
  zh | en) new="$mode" ;;
  *) [[ "$cur" == zh ]] && new=en || new=zh ;;
  esac
  GTMUX_LANG="$new"
  load_lang
  tmux set-option -t "$SESSION" @gtmux_lang "$new"
  tmux set-environment -t "$SESSION" GTMUX_LANG "$new"
  bind_keys
  tmux set -t "$SESSION" status-right "$(tf status_right "$MENU_KEY")"
  tmux display-message "$(tf lang_set "$new")"
}

bind_keys() {
  tmux bind-key -T prefix Up previous-window
  tmux bind-key -T prefix Down next-window
  # broadcast ({}=host {n}=num): b send, B type-only, Enter send-all
  tmux bind-key -T prefix b command-prompt -p "$(t p_bcast_send)" \
    "run-shell -b '$SELF _bcast 1 \"%%\"'"
  tmux bind-key -T prefix B command-prompt -p "$(t p_bcast_nosend)" \
    "run-shell -b '$SELF _bcast 0 \"%%\"'"
  tmux bind-key -T prefix Enter run-shell -b "$SELF _enterall"
  # quick: Prefix C-c sends Ctrl-C to all hosts
  tmux bind-key -T prefix C-c run-shell -b "$SELF _bcastkey C-c"
  # collapse sidebar: e this window, E all
  tmux bind-key -T prefix e run-shell "$SELF _toggle_side '#{window_id}'"
  tmux bind-key -T prefix E run-shell -b "$SELF _toggle_side_all"
  # monitor: m open, M close
  tmux bind-key -T prefix m command-prompt -p "$(t p_monitor)" \
    "run-shell -b '$SELF _monitor \"%%\"'"
  tmux bind-key -T prefix M run-shell "$SELF _monitor_close '#{window_id}' '#{window_name}'"
  # menu
  tmux bind-key "$MENU_KEY" display-menu -T "#[align=centre] gtmux " \
    "$(t m_bcast_send)" b "command-prompt -p '$(t p_bcast_send)' \"run-shell -b '$SELF _bcast 1 \\\"%%\\\"'\"" \
    "$(t m_bcast_nosend)" B "command-prompt -p '$(t p_bcast_nosend)' \"run-shell -b '$SELF _bcast 0 \\\"%%\\\"'\"" \
    "$(t m_enterall)" r "run-shell -b '$SELF _enterall'" \
    "$(t m_ctrlc)" i "run-shell -b '$SELF _bcastkey C-c'" \
    "$(t m_bcastkey)" K "command-prompt -p '$(t p_bcastkey)' \"run-shell -b '$SELF _bcastkey \\\"%%\\\"'\"" \
    "$(t m_ssh)" c "run-shell -b '$SELF _ssh_all'" \
    "$(t m_collapse_one)" e "run-shell '$SELF _toggle_side \"#{window_id}\"'" \
    "$(t m_collapse_all)" E "run-shell -b '$SELF _toggle_side_all'" \
    "$(t m_monitor)" m "command-prompt -p '$(t p_monitor)' \"run-shell -b '$SELF _monitor \\\"%%\\\"'\"" \
    "$(t m_monitor_close)" M "run-shell '$SELF _monitor_close \"#{window_id}\" \"#{window_name}\"'" \
    "" \
    "$(t m_log_start)" l "run-shell -b '$SELF _log_start'" \
    "$(t m_log_stop)" k "run-shell -b '$SELF _log_stop'" \
    "$(t m_logpath)" L "command-prompt -p '$(t p_logpath)' \"run-shell -b '$SELF _logpath \\\"%%\\\"'\"" \
    "$(t m_clean)" C "run-shell -b '$SELF _clean'" \
    "$(t m_lang)" g "run-shell -b '$SELF _setlang toggle \"#{session_name}\"'" \
    "" \
    "$(t m_prev)" p "previous-window" \
    "$(t m_next)" n "next-window" \
    "" \
    "$(t m_detach)" d "detach-client" \
    "$(t m_kill)" x "kill-session -t $SESSION"
}

# ---- dispatch ---------------------------------------------------------------

case "${1:-open}" in
open)
  shift
  action_open "$@"
  ;;
attach) tmux attach -t "$SESSION" ;;
kill) tmux kill-session -t "$SESSION" 2>/dev/null && echo killed || t no_session ;;
rebind) bind_keys && t rebound && echo ;;
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
_bcastkey)
  shift
  action_bcastkey "$@"
  ;;
_ssh_all) action_ssh_all ;;
_log_start) action_log_start ;;
_log_stop) action_log_stop ;;
_clean) action_clean ;;
_toggle_side)
  shift
  action_toggle_side "$@"
  ;;
_toggle_side_all) action_toggle_side_all ;;
_relayout) action_relayout ;;
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
_setlang)
  shift
  action_setlang "$@"
  ;;
*)
  echo "usage: $0 [open [-n N] [-p PREFIX] [-l LOGPATH] | attach | kill | help]" >&2
  exit 2
  ;;
esac
