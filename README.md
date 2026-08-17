# Control D panel for Omarchy

Bar widget for the Omarchy shell that reports what [Control D](https://controld.com) is doing
on **this machine**: the endpoint it resolves through, the profile that endpoint enforces, and
that profile's statistics, recent lookups and custom DNS rules. Backed by
[`cdctl`](https://github.com/joaodrp/controld-cli), the Control D CLI.

Read-only, with one exception: if the host has a way to stand Control D down, the hero gets a
switch for it (see `pauseCommand` below). Nothing else in the panel writes.

## Features

- Hero names this machine's endpoint and the profile it enforces, and links to the Control D
  dashboard for everything the panel does not do, identified from the DNS
  resolver actually in use rather than the hostname; the account line is on hover
- Bar icon shows account state: dimmed when unavailable, badge when `cdctl` needs a login
- The hero mark opens the Control D dashboard, which is where everything the panel cannot do
  lives. `o` does the same, `R` refreshes
- Hero switch pauses and resumes Control D, if `pauseCommand` and `resumeCommand` say how. There
  is no one way to do it: `ctrld` has a service, a systemd-resolved setup has a drop-in, so the
  panel runs what the host tells it rather than guessing. Paused, the panel says so instead of
  reporting a missing resolver. `statusCommand` answers whether it is on, which also inherits
  any check the panel cannot make, such as a link carrying its own DNS. Without one the switch
  falls back to the identified device or Control D on the live resolver
- Left click opens a keyboard-friendly panel; middle click refreshes
- Machine facts under the hero, in the built-in panels' key/value idiom: profile, unmatched
  action, protocol, resolver, filter and service counts, and the endpoint ID (click to copy).
  The resolver row is probed on the machine, never taken from the account, so it says
  `ctrld v1.5.5` only when a daemon is actually running
- STATISTICS for this endpoint: a queries-over-time chart with the blocked share shaded under
  it, totals, and top domains, filters and destinations as meter rows. Pick the window
  (1h/24h/7d/30d) and the verdict (blocked/bypassed/redirected); destinations switch between
  networks and countries, spelled out from ISO 3166-1. Domain rows copy the hostname; filter,
  network and country rows are inert, since nothing takes those as input. Fetched only while
  the panel is open.
  The verdict governs domains and filters, not destinations: a blocked query never reaches
  one, so destinations are the traffic that was allowed
- ACTIVITY: this endpoint's most recent lookups, refreshed every 15s while the panel is open.
  Filtered to **blocked** by default, which is the verdict worth acting on when a site will not
  load; `All` shows every verdict. Filtering happens server side, so a blocked list is a full
  list. `Grouped`, on by default, folds every row for a host into the newest one with an `xN`
  tally, which is what keeps a chatty telemetry endpoint from filling the section; turn it off
  to keep each lookup and read the sequence. Drawn short with a
  `+N` at the foot: one poll already holds up to 20, so expanding costs no extra request
- RULES: the enforced profile's custom rules, root first, then one group per folder, with
  action, spoof/redirect target, and disabled state. Capped like every other list; the caption
  says how many are hidden
- Copy a rule's hostname to the clipboard
- Every section needs an identified endpoint. Without one the panel shows nothing but the
  reason: no Control D resolver here, a resolver whose endpoint is not in this account, or a
  device lookup that failed

## Keyboard shortcuts

Inside the panel:

| Key | Does |
| --- | --- |
| `?` | Show or hide the key legend |
| `o` | Open the Control D dashboard |
| `m` / `s` / `a` / `r` | Jump to machine, statistics, activity, rules |
| `g` / `G` | Jump to the top or the bottom |
| `j` / `k` or arrows | Move the cursor through every actionable row, top to bottom |
| `enter` / `space` | Activate the cursor row |
| `y` | Yank what the cursor is on, or the endpoint ID when it is on nothing |
| `R` | Refresh |
| `esc` | Close |

`r` names the rules section, so refresh takes the shifted `R`.

## Endpoint detection

Each device publishes itself four ways: a DoT hostname, a DoH URL, and its own IPv6 and legacy
IPv4 addresses. All four carry the device id, so the panel reads the local DNS config and looks
for any of them in `cdctl api /devices` (the escape hatch, so it reads raw upstream fields
rather than the CLI's normalized schema). Matching against the device list rather than a
hostname pattern is what lets a plain IPv6 resolver identify the endpoint with no proxy at all.

The configs it reads, and the resolver each one implies:

| Config | Resolver |
| --- | --- |
| `/etc/controld/ctrld.toml`, `/etc/ctrld.toml` | `ctrld` |
| `/etc/stubby/stubby.yml` | `stubby` |
| `/etc/dnscrypt-proxy/dnscrypt-proxy.toml` | `dnscrypt-proxy` |
| `/etc/unbound/unbound.conf`, `unbound.conf.d/*.conf` | `unbound` |
| `/etc/dnsmasq.conf`, `/etc/dnsmasq.d/*` | `dnsmasq` |
| `/etc/NetworkManager/NetworkManager.conf`, `conf.d/*.conf` | `NetworkManager` |
| `resolvectl status` | `systemd-resolved` |
| `/etc/resolv.conf` | `unknown` |

The first config that names the endpoint wins, so a manager gets credit over whatever it
generates downstream. `ctrld` is also confirmed with `systemctl is-active`, because the account
keeps a `ctrld` block on a device long after the daemon is gone.

An endpoint found only in `/etc/resolv.conf` means something set it that this list does not
cover: the row reads `unknown` and links to the issue tracker. **If that is your setup, please
open an issue or a PR** so it can be added. A router or network filtering upstream is not
visible from the machine at all, and no local probe can change that.

Statistics and activity come from Control D's analytics origin
(`<region>.analytics.controld.com`), a different host than the REST API and so out of reach of
`cdctl api`. `scripts/stats.py` and `scripts/activity.py` make those calls through
`scripts/controld_api.py`, which resolves the token the way `cdctl` does — `CONTROLD_API_TOKEN`
first, otherwise the token for the current context in `cdctl`'s own config (honouring
`XDG_CONFIG_HOME`) — and sends it in a request header. The token never reaches a process
argument, which is world readable on Linux, and never appears in output. The region comes from
`cdctl auth status`; the helpers refuse to guess it. Analytics has to be on for the endpoint
(`none` reports nothing); the section says so when it is off.

With `cdctl` installed but not signed in, the panel shows what to do and a link to this guide
rather than an empty shell.

## Requirements

- `cdctl` installed and authenticated (`cdctl auth login --token-stdin`). The panel looks on
  `PATH`, then in `~/.cargo/bin`, `~/.local/bin`, `/usr/local/bin`, `/usr/bin`
- `wl-copy` for clipboard copy actions
- `python3` for the statistics helper (standard library only)

The panel always passes `--profile <id>` explicitly, so `cdctl`'s `default_profile` does not
have to be set.

## Install

```sh
omarchy plugin add https://github.com/joaodrp/omarchy-controld-panel.git --enable
```

Move it with `omarchy bar move io.github.joaodrp.controld --section right`.

## Icons

The bar and hero mark is the Control D logo, drawn natively from its paths in
`ControldIcon.qml`.

The artwork belongs to Control D; this project is not affiliated with them.

## Settings

Set through the bar's widget settings, or inline on the widget's `shell.json` entry:

| Key | Default | Meaning |
| --- | --- | --- |
| `refreshIntervalSec` | `120` | Poll interval, 15-3600 seconds |
| `showStatistics` | `true` | Whether to query analytics at all |
| `showActivity` | `true` | Whether to poll the activity log while open |
| `activityRows` | `10` | Rows in the activity list before the expander, 3-20 |
| `statsWindowHours` | `24` | Statistics window the panel opens on, 1-720 hours |
| `statsRows` | `5` | Rows per statistics list: domains, filters, destinations, 3-20 |
| `ruleRows` | `15` | Rules shown before the list is cut, 5-100 |
| `statusCommand` | `""` | Command whose exit 0 means Control D is on. Empty falls back to what the panel can see |
| `pauseCommand` | `""` | Command that stands Control D down. Empty means no switch |
| `resumeCommand` | `""` | Command that brings it back. Both must be set for the switch to appear |

## IPC

```sh
omarchy-shell io.github.joaodrp.controld toggle
omarchy-shell io.github.joaodrp.controld refresh
omarchy-shell io.github.joaodrp.controld profile              # enforced profile name
omarchy-shell io.github.joaodrp.controld status               # account line
```

## Develop

```sh
ln -s "$PWD" ~/.config/omarchy/plugins/io.github.joaodrp.controld
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.joaodrp.controld
```

The shell's hot reload watches the plugins dir with `inotifywait -r`, which does not follow a
symlinked checkout, so reload after edits with `omarchy-restart-shell`. Check before sharing:

```sh
node test/model.test.js
omarchy plugin validate "$PWD"
/usr/lib/qt6/bin/qmllint -I <dir-with-qs-symlink> Panel.qml Service.qml ControldIcon.qml
```

The Qt 6 linter needs an import dir containing a `qs` symlink to `$OMARCHY_PATH/shell`; the
`qmllint` on `PATH` (Qt 5) cannot parse the typed IPC functions Quickshell requires and fails on
the built-in panels too.

## Remove

```sh
omarchy plugin remove io.github.joaodrp.controld
```

## License

MIT, see [LICENSE](LICENSE).
