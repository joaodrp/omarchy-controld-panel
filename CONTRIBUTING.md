# Contributing

Bug reports, resolver setups the panel cannot attribute, and pull requests are all welcome.

If the panel reads `unknown` in its resolver row, that is a setup worth an issue: say which
program holds your Control D endpoint and how it is configured.

## Layout

| File | |
| --- | --- |
| `manifest.json` | Plugin contract: kind, entry point, settings schema and defaults |
| `Panel.qml` | Everything on screen, plus the cursor and key handling |
| `Service.qml` | Every process the panel runs, and the state they produce |
| `Model.js` | Pure parsing and shaping, Qt-free, so `node` can test it |
| `ControldIcon.qml` | The Control D mark, drawn from its SVG paths |
| `scripts/` | The analytics helpers; see [docs/how-it-works.md](docs/how-it-works.md) |
| `test/model.test.js` | Unit tests for `Model.js` |
| `agent/SKILL.md` | What the `A` key hands an agent |

Logic that can live in `Model.js` belongs there rather than in QML: it is the only part with
tests. QML owns rendering and process orchestration.

## Running it

```sh
ln -s "$PWD" ~/.config/omarchy/plugins/io.github.joaodrp.controld
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.joaodrp.controld
```

Hot reload watches the plugins directory with `inotifywait -r`, which ignores a symlinked
checkout. Working from a symlink means restarting the shell for every change:

```sh
omarchy-restart-shell
qs log -p "$OMARCHY_PATH/shell" --tail 60   # QML errors land here, and only with -p
```

## Checks

```sh
node test/model.test.js
omarchy plugin validate "$PWD"
python3 -m py_compile scripts/*.py

# QML lint needs an import dir holding a `qs` symlink to the shell
mkdir -p /tmp/qslint && ln -sfn "$OMARCHY_PATH/shell" /tmp/qslint/qs
/usr/lib/qt6/bin/qmllint -I /tmp/qslint Panel.qml Service.qml ControldIcon.qml
```

Two things about the linter. The `qmllint` on `PATH` is Qt 5: it cannot parse the typed IPC
functions Quickshell requires and fails on the built-in panels too, so use the Qt 6 path above.
And it warns `unqualified`, `missing-property` and `signal-handler-parameters` on this plugin and
every first-party panel alike -- Quickshell typing gaps, not defects. Compare the warning set
before and after a change rather than aiming for silence.

A test must fail before it passes: when fixing a bug, write the failing test first and confirm it
fails against the unfixed code.

## Conventions

Native to Omarchy first. Before inventing a component, look for the built-in that solves it in
`$OMARCHY_PATH/shell/Ui/` or in a first-party panel under `$OMARCHY_PATH/shell/plugins/`.
Precedents this panel follows:

- Section headers are text, never icons. Facts are `InfoLabel`/`DetailValue` in a shared grid (the
  network panel). Meter rows are label, bar, value on one line (the agents panel).
- A row that names something is `Style.font.body`; its detail line is `caption`; a facts grid is
  `bodySmall`.
- `urgent` means something is wrong. Blocked queries are not wrong, so they get foreground tints.
- An affordance is a promise: pointer cursor, tooltip and hover highlight belong only on something
  that acts. The keyboard cursor is a reading position and may go anywhere.
- Pointer selection goes through `PointerMoveGate`, so scrolling under a still mouse leaves the
  cursor in place.

Comments carry what the code cannot: why an obvious alternative was rejected. They describe the
current state, never the change -- git history holds that.

## Gotchas

- **`cdctl api` rejects `--json`** and emits the upstream body verbatim, so it needs its own
  command builder. Its field names are upstream's, not the CLI's normalized schema.
- **`Shape` with `layer.enabled` loses its antialiasing** when scaled down: the layer caches at the
  path's own size, and Qt skips mipmapping it.
- **A Repeater shares its parent with its delegates**, so you cannot find rows by counting
  children. They carry their own key.
- **The panel writes to a real Control D account.** Rule, profile and pause actions are live. Read
  the state back before and after, and put back whatever you change while testing.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/), one logical change each. Describe
what the change does and why, in the body, with backticks around identifiers.

## Scope

The panel describes one machine. Account-wide browsing belongs in the Control D dashboard or in
`cdctl`. When a capability lands in `cdctl`, prefer it over reaching for the API directly.
