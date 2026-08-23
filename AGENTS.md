# AGENTS.md

Instructions for any coding agent working in this repository (see [agents.md](https://agents.md)).

## What this repo is

An [Omarchy 4](https://omarchy.org/manual/shell-plugins/) shell plugin: a `bar-widget` for the
Quattro Quickshell shell, id `io.github.joaodrp.controld`. It reports what Control D is doing on
**this machine** -- the endpoint, its profile, its statistics, its recent lookups, its rules -- and
writes three things: custom rules, the profile this endpoint enforces, and this device's on/off
state. Every write goes through `cdctl -y` and is verified by cdctl's own read-back. Anything else
belongs in `cdctl` or the dashboard.

Control D has two origins:

| Origin | Reached by | Carries |
| --- | --- | --- |
| `api.controld.com` | [`cdctl`](https://github.com/joaodrp/controld-cli) | auth, profiles, rules, folders, devices |
| `<region>.analytics.controld.com` | `scripts/*.py` | statistics, activity log |

`cdctl api` cannot reach the analytics origin, which is the whole reason the Python helpers exist.
They resolve the token exactly as `cdctl` does -- `CONTROLD_API_TOKEN`, else the current context in
`cdctl`'s config -- and send it in a request header only. **Never put the token in a process
argument**: `/proc/*/cmdline` is world readable.

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
| `scripts/activity.py` | Recent lookups, one row per host with a repeat count. The panel draws a slice and expands into the rest |
| `test/model.test.js` | Unit tests for `Model.js` |
| `agent/SKILL.md` | What the `A` key hands an agent |

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

`qmllint` warns `unqualified`, `missing-property` and `signal-handler-parameters` on this plugin
and every first-party panel alike: Quickshell typing gaps, not defects. The `qmllint` on `PATH` is
Qt 5 and cannot parse Quickshell's typed IPC functions at all.

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

Hot reload uses `inotifywait -r`, which does not follow a symlinked checkout, so a symlinked
working copy needs a shell restart per change.

Check the work with screenshots: `grim` captures, `wlrctl pointer` and `wtype` drive the panel.
Never kill `grim` mid-capture -- it wedges the compositor's screencopy, and every capture with a
panel open hangs until that clears itself.

The panel writes to a real account. Read the state back before and after each click rather than
trusting a sequence, and put back whatever you change.

## Conventions

Native to Omarchy first: before inventing a component, look for the built-in that solves it in
`$OMARCHY_PATH/shell/Ui/` or in a first-party panel under `$OMARCHY_PATH/shell/plugins/`.
Precedents this panel follows:

- Section headers are text, never icons. Facts are `InfoLabel`/`DetailValue` in a shared grid (the
  network panel). Meter rows are label, bar, value on one line (the agents panel)
- A row that names something is `Style.font.body`; its detail line is `caption`; a facts grid is
  `bodySmall`
- `urgent` means something is wrong. Blocked queries are not wrong, so they get foreground tints
- An affordance is a promise: pointer cursor, tooltip and hover highlight belong only on something
  that acts. The keyboard cursor is a reading position and may go anywhere
- Pointer selection goes through `PointerMoveGate`, so scrolling under a still mouse does not
  steal the cursor

## Hazards

- **Analytics region** comes from `cdctl auth status`. The helpers refuse to guess it: a wrong
  region is a host that does not exist or is not yours
- **`cdctl api` rejects `--json`** and emits the upstream body verbatim, so it needs its own
  command builder and its field names are upstream's, not the CLI's normalized schema
- **The endpoint is identified by resolver, not hostname.** A device publishes itself four ways
  (DoT host, DoH URL, its own v6 and legacy v4 addresses), all carrying the device id, and matching
  runs against the device list. Adding a resolver means one more section in the probe and one more
  entry in `RESOLVERS`
- **`Shape` with `layer.enabled` loses its antialiasing** when scaled down: the layer caches at the
  path's own size and Qt does not mipmap it
- **A Repeater shares its parent with its delegates**, so rows cannot be found by counting
  children. They carry their own key
- **Analytics verdicts**: 0 blocked, 1 bypassed, 2 redirected, 3 spoofed, -1 in the timeseries for
  queries that matched nothing. Destinations exist only for traffic that was allowed

## Scope

The panel describes this machine. Account-wide browsing belongs in the dashboard or in `cdctl`.
When a capability lands in `cdctl`, prefer it over reaching for the API directly.
