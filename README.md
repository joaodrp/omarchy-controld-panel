# Control D panel for Omarchy

Bar widget for the Omarchy shell that shows your [Control D](https://controld.com) account:
profiles, their rule/filter/service counts, and each profile's custom DNS rules, grouped by
folder. Backed by [`cdctl`](https://github.com/joaodrp/controld-cli), the Control D CLI.

Read-only for now: it lists, it does not write.

## Features

- Bar icon shows account state: dimmed when unavailable, badge when `cdctl` needs a login
- Left click opens a keyboard-friendly panel; middle click refreshes; right click cycles profiles
- PROFILES: every profile with enabled rules, filters, and services; click one to browse it
- RULES: the selected profile's custom rules, root first, then one group per folder, with
  action, spoof/redirect target, and disabled state
- Copy a rule's hostname to the clipboard
- The selected profile persists across restarts (stored on the widget's `shell.json` entry)

## Keyboard shortcuts

Inside the panel:

- `j` / `k` or arrows: move cursor
- `enter` / `space`: select profile, or copy the selected rule's hostname
- `c`: copy selected rule hostname
- `p`: next profile
- `r`: refresh
- `esc`: close

## Requirements

- `cdctl` installed and authenticated (`cdctl auth login --token-stdin`). The panel looks on
  `PATH`, then in `~/.cargo/bin`, `~/.local/bin`, `/usr/local/bin`, `/usr/bin`
- `wl-copy` for clipboard copy actions

The panel always passes `--profile <id>` explicitly, so `cdctl`'s `default_profile` does not
have to be set.

## Install

```sh
omarchy plugin add https://github.com/joaodrp/omarchy-controld-panel.git --enable
```

Move it with `omarchy bar move io.github.joaodrp.controld --section right`.

## Settings

Set through the bar's widget settings, or inline on the widget's `shell.json` entry:

| Key | Default | Meaning |
| --- | --- | --- |
| `refreshIntervalSec` | `120` | Poll interval, 15-3600 seconds |
| `profile` | `""` | Profile id (or name) to show; empty picks the first profile |

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
