# Control D panel for Omarchy

Bar widget for the Omarchy shell reporting what [Control D](https://controld.com) is doing on
**this machine**: the endpoint it resolves through, the profile that endpoint enforces, and that
profile's statistics, recent lookups and custom rules. Backed by
[`cdctl`](https://github.com/joaodrp/controld-cli), the Control D CLI.

Mostly a reader. It writes three things, each through `cdctl`, which verifies the write by reading
the account back:

| Write | From |
| --- | --- |
| Custom rules: add, delete, switch off, override a lookup | Rules section, activity rows |
| The profile this endpoint enforces | Hero caret |
| This device's on/off state | Hero switch |

## What it shows

Left click opens the panel, middle click refreshes. Every section needs an identified endpoint;
without one the panel shows only the reason -- no Control D resolver here, a resolver whose
endpoint is not in this account, or a failed device lookup.

| Area | Contents |
| --- | --- |
| Bar icon | Account state: dimmed when unavailable, badged when `cdctl` needs a login, crossed when `cdctl` is missing or nothing here is protected |
| Hero | The endpoint and the profile it enforces, or the signed-in account when there is no endpoint. The mark opens the Control D dashboard, which is where everything the panel cannot do lives |
| MACHINE | Endpoint ID (click to copy), protocol, resolver, unmatched action. The resolver is probed on the machine, never taken from the account, so it names `ctrld` and its version whenever `ctrld` holds the endpoint |
| STATISTICS | Queries over time with the blocked share shaded under it, totals, and top domains, filters and destinations as meter rows. Fetched only while the panel is open |
| ACTIVITY | The endpoint's most recent lookups, refreshed every 15s while the panel is open |
| RULES | The enforced profile's custom rules, root first then one group per folder, with action, spoof or redirect target, and disabled state. Capped; the caption says how many are hidden |

### Statistics

Pick the window (1h/24h/7d/30d) and the verdict (blocked/bypassed/redirected); destinations switch
between networks and countries, spelled out from ISO 3166-1. The verdict governs domains and
filters, not destinations: a blocked query never reaches one, so destinations are the traffic that
was allowed. Domain rows copy the hostname; filter, network and country rows are inert, since
nothing takes those as input.

### Activity

- Filtered to **blocked** by default, the verdict worth acting on when a site will not load.
  `Bypassed` and `Others` are the rest, the last being where a redirect or a spoof shows at all.
  Filtering happens server side, so a blocked list is a full list.
- `Grouped`, on by default, folds every row for a host into the newest with an `xN` tally, so a
  chatty telemetry endpoint cannot fill the section. Off keeps each lookup, in sequence.
- Bypass a blocked host, or block a bypassed one, from the row itself: the verdict glyph turns
  into the action on hover, `b` and `B` do the same from the keyboard. Pressing again removes the
  rule. The list is drawn short with a `+N` expander that costs no extra request.

### Rules

`Add` creates a rule, `x` switches the one under the cursor off without deleting it, delete sits
behind an inline confirmation, and `y` copies the hostname.

### Pause switch

The hero switch stands Control D down and brings it back.

- With `pauseCommand` and `resumeCommand` set, the panel runs those; empty, it pauses the device
  through the account instead, so the switch works with no setup. The two are not equivalent: a
  host command changes what this machine resolves through, the account changes what Control D does
  with what it is asked. There is no one right host command -- `ctrld` has a service, a
  systemd-resolved setup has a drop-in -- so the panel runs what you give it.
- `statusCommand` answers whether it is on, inheriting any check the panel cannot make, such as a
  link carrying its own DNS. Without one the switch falls back to the identified device, or to
  Control D on the live resolver.
- Paused, the panel says so instead of reporting a missing resolver.

## Keyboard shortcuts

| Key | Does |
| --- | --- |
| `?` | Show or hide the key legend |
| `o` | Open the Control D dashboard |
| `m` / `s` / `a` / `r` | Jump to machine, statistics, activity, rules |
| `g` / `G` | Jump to the top or the bottom |
| `j` / `k` or arrows | Move the cursor through every actionable row |
| `enter` / `space` | Activate the cursor row |
| `y` | Yank what the cursor is on, or the endpoint ID when it is on nothing |
| `p` | Open the profile picker |
| `b` / `B` | Bypass or block the host the cursor is on, or undo the rule for it |
| `x` | Switch the rule under the cursor on or off |
| `A` | Hand the panel to Omarchy's default agent, pointed at `cdctl` and the plugin rather than a dump of the account |
| `R` | Refresh (`r` names the rules section, so refresh takes the shift) |
| `esc` | Close |

## Endpoint detection

Each device publishes itself four ways -- DoT hostname, DoH URL, its own IPv6 and legacy IPv4
addresses -- and all four carry the device id. The panel reads the local DNS config and looks for
any of them in `cdctl api /devices`. Matching the device list rather than a hostname pattern is
what lets a plain IPv6 resolver identify the endpoint with no proxy at all.

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

The first config that names the endpoint wins, so a manager gets credit over what it generates
downstream. `ctrld` is confirmed with `systemctl is-active`, because the account keeps a `ctrld`
block on a device long after the daemon is gone.

An endpoint found only in `/etc/resolv.conf` means something set it that this list does not cover:
the row reads `unknown` and links to the issue tracker. **If that is your setup, please open an
issue or a PR** so it can be added. Filtering on a router or upstream is invisible from the
machine, and no local probe changes that.

## Analytics and the API token

Statistics and activity come from Control D's analytics origin (`<region>.analytics.controld.com`),
a different host than the REST API and so out of reach of `cdctl api`. `scripts/stats.py` and
`scripts/activity.py` call it through `scripts/controld_api.py`, which:

- Resolves the token as `cdctl` does: `CONTROLD_API_TOKEN`, else the token for the current context
  in `cdctl`'s config (honouring `XDG_CONFIG_HOME`).
- Sends it in a request header only. Never a process argument, which is world readable on Linux,
  and never in output.
- Takes the region from `cdctl auth status` rather than guessing it.

Analytics has to be enabled for the endpoint; the section says so when it is off.

## Requirements

- `cdctl`, installed and authenticated (`cdctl auth login --token-stdin`). The panel looks on
  `PATH`, then in `~/.cargo/bin`, `~/.local/bin`, `/usr/local/bin`, `/usr/bin`
- `wl-copy` for clipboard actions
- `python3` for the analytics helpers, standard library only
- `omarchy-launch-browser` to open the dashboard, `omarchy-agent` for the `A` key. Both ship with
  Omarchy

The panel always passes `--profile <id>` explicitly, so `cdctl`'s `default_profile` need not be
set. Installed but not signed in, the panel shows what to do and a link to this guide.

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

## Install

```sh
omarchy plugin add https://github.com/joaodrp/omarchy-controld-panel.git --enable
omarchy bar move io.github.joaodrp.controld --section right   # optional
omarchy plugin remove io.github.joaodrp.controld              # to uninstall
```

## IPC

```sh
omarchy-shell io.github.joaodrp.controld toggle
omarchy-shell io.github.joaodrp.controld refresh
omarchy-shell io.github.joaodrp.controld profile   # enforced profile name
omarchy-shell io.github.joaodrp.controld status    # account line
```

## Develop

```sh
ln -s "$PWD" ~/.config/omarchy/plugins/io.github.joaodrp.controld
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.joaodrp.controld
```

Hot reload watches the plugins dir with `inotifywait -r`, which does not follow a symlinked
checkout, so reload after edits with `omarchy-restart-shell`. Check before sharing:

```sh
node test/model.test.js
omarchy plugin validate "$PWD"
/usr/lib/qt6/bin/qmllint -I <dir-with-qs-symlink> Panel.qml Service.qml ControldIcon.qml
```

The Qt 6 linter needs an import dir holding a `qs` symlink to `$OMARCHY_PATH/shell`. The `qmllint`
on `PATH` is Qt 5 and cannot parse the typed IPC functions Quickshell requires; it fails on the
built-in panels too.

## Icons

The bar and hero mark is the Control D logo, drawn natively from its paths in `ControldIcon.qml`.
The artwork belongs to Control D; this project is not affiliated with them.

## License

MIT, see [LICENSE](LICENSE).
