# Control D panel for Omarchy

Bar widget for the Omarchy shell that shows your [Control D](https://controld.com) account:
profiles, their rule/filter/service counts, and each profile's custom DNS rules, grouped by
folder. Backed by [`cdctl`](https://github.com/joaodrp/controld-cli), the Control D CLI.

Read-only for now: it lists, it does not write.

## Features

- Hero names this machine's endpoint and the profile it enforces, identified from the DNS
  resolver actually in use rather than the hostname; the account line is on hover
- Bar icon shows account state: dimmed when unavailable, badge when `cdctl` needs a login
- Left click opens a keyboard-friendly panel; middle click refreshes; right click cycles profiles
- Machine facts under the hero, in the built-in panels' key/value idiom: profile, unmatched
  action, protocol, ctrld version, filter and service counts, and the endpoint ID (click to copy)
- PROFILES: the browse-mode fallback for a machine that is not on Control D DNS — every profile
  with its enabled rules, filters, and services; click one to browse it
- STATISTICS for this endpoint: a queries-over-time chart with the blocked share shaded under
  it, totals, and top domains, filters and destinations as meter rows. Pick the window
  (1h/24h/7d/30d) and the verdict (blocked/bypassed/redirected); destinations switch between
  networks and countries, spelled out from ISO 3166-1. Domain rows copy the hostname; filter,
  network and country rows are inert, since nothing takes those as input. Fetched only while
  the panel is open.
  The verdict governs domains and filters, not destinations: a blocked query never reaches
  one, so destinations are the traffic that was allowed
- ACTIVITY: this endpoint's most recent lookups, refreshed every 15s while the panel is open.
  The A/AAAA pair of one lookup collapses into a single row
- RULES: the enforced profile's custom rules, root first, then one group per folder, with
  action, spoof/redirect target, and disabled state
- Copy a rule's hostname to the clipboard
- The selected profile persists across restarts (stored on the widget's `shell.json` entry)

## Keyboard shortcuts

Inside the panel:

| Key | Does |
| --- | --- |
| `?` | Show or hide the key legend |
| `m` / `s` / `a` / `r` | Jump to machine, statistics, activity, rules |
| `g` / `G` | Jump to the top or the bottom |
| `j` / `k` or arrows | Move the cursor |
| `enter` / `space` | Select profile, or copy the selected rule's hostname |
| `c` | Copy the selected rule's hostname |
| `y` | Copy the endpoint ID |
| `p` | Next profile (browse mode only) |
| `R` | Refresh |
| `esc` | Close |

`r` names the rules section, so refresh takes the shifted `R`.

Endpoint detection reads `resolvectl status`, then `/etc/resolv.conf`, then a local `ctrld`
config, looking for `<uid>.dns.controld.com` or `dns.controld.com/<uid>`: that id is the
device id, so the match is exact. Legacy shared resolvers carry no id and fall back to the
account line. Naming the endpoint needs `cdctl api /devices`, the escape hatch, so that one
call reads raw upstream fields rather than the CLI's normalized schema.

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

The panel uses the Control D dashboard's own icons, kept as single-color SVGs under `assets/`
and tinted to the active Omarchy theme at runtime (`DashIcon.qml`), so one file serves every
theme. Available names: `profiles`, `endpoints`, `analytics`, `statistics`, `activity`,
`domain-test`, `preferences`, `rules`, `filters`, `services`, `options`. The bar and hero mark
is the Control D logo, drawn natively from its paths in `ControldIcon.qml`.

The artwork belongs to Control D; this project is not affiliated with them.

## Settings

Set through the bar's widget settings, or inline on the widget's `shell.json` entry:

| Key | Default | Meaning |
| --- | --- | --- |
| `refreshIntervalSec` | `120` | Poll interval, 15-3600 seconds |
| `profile` | `""` | Profile id (or name) to show; empty picks the first profile |
| `showStatistics` | `true` | Whether to query analytics at all |
| `showActivity` | `true` | Whether to poll the activity log while open |
| `activityRows` | `8` | Rows in the activity list, 3-25 |
| `statsWindowHours` | `24` | Statistics window the panel opens on, 1-720 hours |

## IPC

```sh
omarchy-shell io.github.joaodrp.controld toggle
omarchy-shell io.github.joaodrp.controld refresh
omarchy-shell io.github.joaodrp.controld profile              # selected profile name
omarchy-shell io.github.joaodrp.controld selectProfile <id>
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
