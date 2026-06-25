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

# or no host file — just N blank panes:
./gtmux.sh open -n 5
./gtmux.sh open -n 5 -p dut-     # labels dut-1 .. dut-5
./gtmux.sh open -l /tmp/logs     # custom log dir (default: ./)
```

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
| `Prefix m` / `Prefix M` | open monitor (pick hosts) / close monitor |
| `Prefix e` / `Prefix E` | collapse sidebar (this host / all) |
| `Prefix d` | detach (session keeps running; `gtmux attach` to return) |

### Broadcast placeholders

In any broadcast, these are substituted **per host** before sending:

| Token | Becomes |
|-------|---------|
| `{}` | that host's label (IP or name) |
| `{n}` | that host's number |

```
./download {} 100          → ./download 10.0.0.4 100   (per host)
./download 10.0.0.{n} 100  → ./download 10.0.0.3 100   (per host)
```

### Monitor

`Prefix m` → enter a selection (`1-4`, `1,3,5`, `1-3,7`, `all`) → opens a tiled
window that `tail -F`s each chosen host's log. Multiple monitors can coexist;
they're listed in the sidebar. Each pane's border shows freshness:
`●live` / `⏸stopped Ns` / `(no log)`. Monitors are **read-only** — to type, jump
to the host's own window or broadcast.

## Configuration (env vars)

| Var | Default | Meaning |
|-----|---------|---------|
| `GTMUX_SESSION` | `gtmux` | tmux session name |
| `GTMUX_KEY` | `Space` | key that opens the menu |
| `IPS_FILE` | `./ip.txt` | host list |
| `LOGROOT` | `.` | log root (a timestamped subdir is created under it) |
| `GTMUX_SIDEBAR_W` | `20%` | sidebar width (`%` or fixed cols) |
| `GTMUX_MON_FRESH` | `3` | seconds within which a monitored log counts as `●live` |

## How it works

- Each host = a tmux **window**, split `[ sidebar | host shell ]`.
- The sidebar is a tiny `gtmux _sidebar` process per window; it highlights its
  own position (so duplicate IPs stay distinguishable) and lists live monitors.
- Broadcast / ssh-all / logging iterate the host panes via `send-keys` /
  `pipe-pane` across all windows — no `synchronize-panes` needed.
- Monitors are non-destructive: separate windows that `tail -F` the per-host
  logs; the real host panes are never moved.

## License

MIT — see [LICENSE](LICENSE).
