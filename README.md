# gtmux

A keyboard-light **tmux multi-host manager**. One window per host with a
persistent left sidebar, one-key menu, broadcast, per-host logging, and a
read-only monitor wall — all in pure tmux, **no plugins, no extra binaries**.

Built for driving a fleet of machines (test rigs, DUTs, servers) from one
terminal without memorizing tmux commands.

```
┌──────────────┬──────────────────────────────────────┐
│ gtmux        │  host 03 shell (full width)           │
│ 30 hosts     │                                       │
│ ───────────  │  $ _                                  │
│ 01  10.0.0.2 │                                       │
│ 02  10.0.0.3 │                                       │
│▸03  10.0.0.4 │  ← reverse-video = current            │
│ 04  10.0.0.5 │                                       │
│ ...          │                                       │
│ ───────────  │                                       │
│ Pfx 1-9 jump │                                       │
│ Pfx Spc menu │                                       │
└──────────────┴──────────────────────────────────────┘
```

## Requirements

| Need | Version | Why |
|------|---------|-----|
| **tmux** | **≥ 3.0** | `display-menu` (the pop-up menu). 3.2+ recommended. |
| **bash** | **≥ 4.0** | `mapfile`, associative-friendly arrays. macOS ships 3.2 — `brew install bash`. |
| terminal | any UTF-8 + 256/truecolor | renders `▸ ● ⏸` and colors |
| optional | `ansi2txt` (`colorized-logs`) | clean log export; falls back to `sed` |

**Terminal emulator doesn't matter.** gtmux runs *inside* tmux, which abstracts
the terminal away. Ghostty, iTerm2, Terminal.app, Alacritty, kitty, WezTerm,
Windows Terminal — all work. You only need UTF-8 + truecolor + a font with the
glyphs. (Tested: bash 5.3, tmux 3.6a, Ghostty.)

## Install

```bash
git clone <this-repo> ~/gtmux
chmod +x ~/gtmux/gtmux.sh
# optionally: ln -s ~/gtmux/gtmux.sh ~/bin/gtmux
```

## Quick start

```bash
# from a directory containing ip.txt (one host per line):
./gtmux.sh open

./gtmux.sh open -f hosts.txt     # use a specific host-list file
./gtmux.sh open -n 5             # no host file — just N blank panes
./gtmux.sh open -n 5 -p dut-     # labels dut-1 .. dut-5
./gtmux.sh open -l /tmp/logs     # set log dir AND start logging (default dir: ./)
```

(Or set `IPS_FILE=/path/hosts.txt`. With no host file and no `-n`, `open`
prompts interactively for a count/file, prefix and log path.)

`open` only lays out the panes (plain shells, **no auto-ssh**). Connect via the
menu (`c` = ssh all) or type into a host yourself.

## Keys (Prefix = `Ctrl+B`)

| Key | Action |
|-----|--------|
| `Prefix 1-9` / `Prefix '` | jump to host by number (sidebar number = window index) |
| `Prefix ↑ / ↓` | previous / next host |
| `Prefix Space` | **menu** (everything, labelled — nothing to memorize) |
| `Prefix b` | broadcast a command to **all** hosts (+ Enter) |
| `Prefix B` | broadcast **without** Enter (review, then…) |
| `Prefix Enter` | send Enter to all (run the pending broadcast) |
| `Prefix C-c` | send Ctrl-C to all hosts |
| `Prefix k` | quick key palette — pick a key (C-c, Esc, arrows, F-keys…) |
| `Prefix m` / `Prefix M` | open monitor (pick hosts) / close monitor |
| `Prefix e` / `Prefix E` | collapse sidebar (this host / all) |
| `Prefix d` | detach (session keeps running; `gtmux attach` to return) |
| `Prefix g` | **GTMUX mode** — sticky, keys work *without* prefix until `Esc`/`q` |

### GTMUX mode (less prefix-typing)

Like Vim's normal mode: press `Prefix g` once, then drive everything **without
the prefix** — `1`-`9` jump, `b` broadcast, `m` monitor, `e` collapse, `l`/`s`
log, `c` ssh-all, `C-c` Ctrl-C, `↑`/`↓` or `p`/`n` switch. The status bar shows
a `●MODE` badge. Press `Esc` or `q` to return to normal typing. Great for doing
several fleet actions in a row.

### Broadcast placeholders

In any broadcast, these are substituted **per host** before sending:

| Token | Becomes | Example (host `192.168.1.101`, #5) |
|-------|---------|-------------------------------------|
| `{}` | the host's label (IP or name) | `192.168.1.101` |
| `{n}` | its list number | `5` |
| `{nn}` | the number zero-padded to 2 digits | `05` |
| `{oct}` | last octet of an IP label | `101` |

```
./download {} 100           → ./download 192.168.1.101 100   (per host)
./download 10.0.0.{n} 100   → ./download 10.0.0.5 100        (per host)
ssh root@10.0.0.{oct}       → ssh root@10.0.0.101            (per host)
```

To broadcast a **key** instead of text (Ctrl-C, Escape, arrows, F-keys): pick
from the quick palette (`Prefix k`), send Ctrl-C directly (`Prefix C-c`), or type
any key in the menu's *broadcast a key*. Key names are case-insensitive
(`c-c`, `escape`, `f5` all work). Monitor panes are never targeted by a broadcast.

### Monitor

`Prefix m` → enter a selection (`1-4`, `1,3,5`, `1-3,7`, `all`) → opens a tiled
window where each tile **mirrors a host pane live** via `capture-pane` — read
straight from tmux's memory, **no log files, no disk I/O** (so it's fast even
for many hosts, and works whether or not logging is on). Multiple monitors can
coexist; they're listed in the sidebar. Each tile's border shows freshness
(`●live` / `⏸idle Ns`). Monitors are **read-only** — to type, jump to the host's
own window or broadcast.

(Logging to files is separate and **off by default** — `GTMUX_LOG=on` or menu
*start logging* — for keeping a record/for `memparse`-style analysis. Logs are
saved as **plain text** by default (ANSI colour codes stripped on the way to
disk); set `GTMUX_LOG_FORMAT=raw` to keep the original session output, or
`both` to write a stripped `<host>.log` **and** an untouched `<host>.raw.log`.
You can also **cycle the format live** from the menu (`Prefix Space` → `f`).
Stripping only removes escape sequences (which start with the ESC byte), so it
never touches real text. While logging is on, the bottom status bar shows
` ● LOG `, the current **format**, and the log directory path.)

## Configuration (env vars)

| Var | Default | Meaning |
|-----|---------|---------|
| `GTMUX_SESSION` | `gtmux` | tmux session name |
| `GTMUX_KEY` | `Space` | key that opens the menu |
| `IPS_FILE` | `./ip.txt` | host list |
| `LOGROOT` | `.` | log root (a timestamped subdir is created under it) |
| `GTMUX_SIDEBAR_W` | `20%` | sidebar width (`%` or fixed cols) |
| `GTMUX_LANG` | `zh` | UI language: `zh`, `en`, or `auto` (detect from `$LANG`) |
| `GTMUX_LOG` | `off` | auto-start per-host logging at `open` (`off`/`on`); `-l <path>` also starts it |
| `GTMUX_LOG_FORMAT` | `plain` | saved log format: `plain` (ANSI stripped), `raw` (original), or `both` (writes `<host>.log` + `<host>.raw.log`) |

Set at `open` and stored on the session (survives detach/attach). Switch it
**live** from the menu (`Prefix Space` → *Language*) — the menu relabels and the
sidebar repaints within ~2s. To make a non-default permanent, `export
GTMUX_LANG=en` in your shell rc.

## How it works

- Each host = a tmux **window**, split `[ sidebar | host shell ]`.
- The sidebar is a tiny `gtmux _sidebar` process per window; it highlights its
  own position (so duplicate IPs stay distinguishable), scrolls to keep the
  current host visible with many hosts, and lists live monitors. The status bar
  carries the run state: the log path while logging, and a `●MODE` badge.
- Broadcast / ssh-all / logging iterate the host panes via `send-keys` /
  `pipe-pane` across all windows — no `synchronize-panes` needed.
- Monitors are non-destructive: separate windows whose tiles mirror host panes
  live via `capture-pane` (tmux memory, no files); the real host panes are
  never moved.
- The session is built at the viewing client's width (inside tmux that's
  `#{client_width}`, not `tput` — which would report a split pane's width), so
  windows never resize when shown and the sidebar keeps a stable width.

## License

MIT — see [LICENSE](LICENSE).
