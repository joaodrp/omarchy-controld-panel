# AGENTS.md

Instructions for coding agents working in this repository (see [agents.md](https://agents.md)).

An [Omarchy 4](https://omarchy.org/manual/shell-plugins/) shell plugin: a `bar-widget` for the
Quattro Quickshell shell, id `io.github.joaodrp.controld`.

Read these first, and do not restate them here:

| Doc | Holds |
| --- | --- |
| [README.md](README.md) | What the panel does, its settings and its keys |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Layout, how to run it, the checks, conventions, gotchas |
| [docs/how-it-works.md](docs/how-it-works.md) | Endpoint detection, the two origins, token handling |

## Working here

**The account is real.** Rule, profile and pause actions write to a live Control D account. Read
the state back before and after each action rather than trusting a sequence, and restore whatever
you changed.

**Green tests prove very little.** `Model.js` is covered; `Panel.qml` and `Service.qml` are not,
and cannot be without a running shell. A passing suite says the parsing is right, not that the
panel draws or behaves correctly. Look at it.

**Look at it properly.** `grim` captures, `wlrctl pointer` and `wtype` drive. Never kill `grim`
mid-capture: it wedges the compositor's screencopy, and every later capture hangs until that
clears. The display is scale 2, so captured pixels are twice the logical size.

**Check the log with `-p`.** `qs log` without `-p "$OMARCHY_PATH/shell"` prints nothing useful, so
an empty result is not evidence of a clean load.

Report what you verified and what you could not. A claim you did not check is worth less than
saying you did not check it.
