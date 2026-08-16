# AGENTS.md

Instructions for any coding agent working in this repository (see [agents.md](https://agents.md)).

## What this repo is

An [Omarchy 4](https://omarchy.org/manual/shell-plugins/) shell plugin: a `bar-widget` for the
Quattro Quickshell shell, id `io.github.joaodrp.controld`. It reports what Control D is doing on
**this machine** — the endpoint, its profile, its statistics, its recent lookups, its rules.

Read-only today. Every write is still done through `cdctl` or the dashboard.

Two backends, because Control D has two origins:

| Origin | Reached by | Carries |
| --- | --- | --- |
| `api.controld.com` | [`cdctl`](https://github.com/joaodrp/controld-cli) | auth, profiles, rules, folders, devices |
| `<region>.analytics.controld.com` | `scripts/*.py` | statistics, activity log |

`cdctl api` cannot reach the analytics origin, which is the whole reason the Python helpers
exist. They resolve the token exactly as `cdctl` does — `CONTROLD_API_TOKEN`, else the current
context in `cdctl`'s config — and send it in a request header only. **Never put the token in a
process argument**: `/proc/*/cmdline` is world readable.

## Layout

| File | |
| --- | --- |
| `manifest.json` | Plugin contract: kind, entry point, settings schema and defaults |
| `Panel.qml` | Everything on screen, plus the cursor and key handling |
| `Service.qml` | Every process the panel runs, and the state they produce |
| `Model.js` | Pure parsing and shaping. Qt-free, so `node` can test it |
| `ControldIcon.qml` | The Control D mark, drawn from its SVG paths |
| `scripts/controld_api.py` | Token resolution and HTTP for the analytics origin |
| `scripts/stats.py` | One (window, verdict) pair of statistics, nine requests folded into one document |
| `scripts/activity.py` | Recent lookups, one row per host with a repeat count. Returns a whole page; the panel draws a slice and expands into the rest |
| `test/model.test.js` | Unit tests for `Model.js` |

Logic that can live in `Model.js` belongs there rather than in QML: it is the only part with
tests. QML owns rendering and process orchestration.

## Build and test

```bash
node test/model.test.js
omarchy plugin validate "$PWD"
python3 -m py_compile scripts/*.py && rm -rf scripts/__pycache__

# QML lint needs an import dir holding a `qs` symlink to the shell
mkdir -p /tmp/qslint && ln -sfn "$OMARCHY_PATH/shell" /tmp/qslint/qs
/usr/lib/qt6/bin/qmllint -I /tmp/qslint Panel.qml Service.qml ControldIcon.qml
```

`qmllint` reports `unqualified`, `missing-property` and `signal-handler-parameters` warnings for
this plugin and for every first-party panel alike; they are Quickshell typing gaps, not defects.
The `qmllint` on `PATH` is Qt 5 and cannot parse the typed IPC functions Quickshell requires —
it fails on the built-in panels too.

## Running it

```bash
ln -s "$PWD" ~/.config/omarchy/plugins/io.github.joaodrp.controld
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.joaodrp.controld

omarchy-restart-shell                                            # after every edit
omarchy-shell shell summon io.github.joaodrp.controld '{}'
omarchy-shell io.github.joaodrp.controld status                  # plugin's own IPC
qs log -p "$OMARCHY_PATH/shell" --tail 60                        # QML errors land here
```

The shell hot-reloads files under `~/.config/omarchy/plugins/`, but its watcher is
`inotifywait -r`, which does not follow a symlinked checkout. Working from a symlink means
restarting the shell to see a change.

Screenshots are how you check the work: `grim` plus `wtype` can drive and capture the panel. Do
not kill `grim` mid-capture — it wedges the compositor's screencopy until it clears itself, and
until then every capture with a panel open hangs.

## Conventions

Native to Omarchy first. Before inventing a component, find the built-in that already solves it
in `$OMARCHY_PATH/shell/Ui/` or a first-party panel in `$OMARCHY_PATH/shell/plugins/`. Settled
precedents this panel follows:

- Section headers are text, never icons. Facts are `InfoLabel`/`DetailValue` in a shared grid
  (the network panel). Meter rows are label, bar, value on one line (the agents panel)
- A row that names something is `Style.font.body`; its detail line is `caption`; a facts grid is
  `bodySmall`
- `urgent` means something is wrong. Blocked queries are not wrong, so they are drawn in
  foreground tints
- An affordance is a promise: a pointer cursor, a tooltip or a hover highlight belongs only on
  something that acts. The keyboard cursor is a reading position and may go anywhere
- Pointer selection goes through `PointerMoveGate`, so scrolling under a still mouse does not
  steal the cursor

## Hazards

- **Analytics region.** `<region>.analytics.controld.com` comes from `cdctl auth status`. The
  helpers refuse to guess it: a wrong region is a host that does not exist or is not yours
- **`cdctl api` rejects `--json`** and emits the upstream body verbatim, so it needs its own
  command builder and its field names are upstream's, not the CLI's normalized schema
- **The endpoint is identified by resolver, not hostname.** A device publishes itself four ways
  (DoT host, DoH URL, its own v6 and legacy v4 addresses), all carrying the device id. Matching
  is done against the device list, not a hostname pattern, so the address forms work too. Adding
  a resolver means one more section in the probe and one more entry in `RESOLVERS`
- **`Shape` with `layer.enabled` loses its antialiasing** when scaled down: the layer caches at
  the path's own size and Qt does not mipmap it
- **A Repeater shares its parent with its delegates**, so rows cannot be found by counting
  children. They carry their own key
- **Analytics verdicts**: 0 blocked, 1 bypassed, 2 redirected, and -1 in the timeseries for
  queries that matched nothing. Destinations exist only for traffic that was allowed

## Scope

The panel describes this machine. Account-wide browsing belongs in the dashboard, which the
header links to, or in `cdctl`. When a capability lands in `cdctl`, prefer it over reaching for
the API directly.
