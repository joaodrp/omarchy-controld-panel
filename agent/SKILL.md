---
name: controld-panel
description: Help with the Control D Omarchy panel, or with the Control D account behind it
---

# Control D panel

A Quickshell bar widget for Omarchy showing what Control D is doing for **this
machine**: which endpoint it resolves through, what that endpoint enforces, and
what it has been deciding lately. It reads the account, and it writes rules,
this device's profile, and this device's on/off state.

The person who launched you is looking at it. Find out what they want before
changing anything.

## Find out first

Everything about the account is one command away. Read it rather than asking.

```bash
cdctl reference          # the whole command surface as one document
cdctl auth status        # who is signed in, and the analytics region
cdctl device list        # every device; the one matching this machine is "the endpoint"
cdctl profile list       # profiles the account holds
cdctl rule list --profile <id>
```

`cdctl` covers `api.controld.com` only. Analytics live on a second origin,
`<region>.analytics.controld.com`, which `cdctl` cannot reach: the panel's own
`scripts/activity.py` and `scripts/stats.py` go there, reading the token from
cdctl's config. Run those directly to see what the panel sees.

## Two kinds of help

**The account.** Rules, profiles, device settings. Every `cdctl` write verifies
itself by reading back, and every one takes `-n/--dry-run`, which prints the
planned request without sending it. Dry-run first, show the person what it
would do, and let them decide. Their DNS is not a scratchpad: a wrong rule
breaks a site, and a wrong device status turns their filtering off.

**The panel.** It is a normal git repository. `AGENTS.md` in the plugin
directory is the authority on how it is built, tested and laid out -- read it
rather than guessing, and follow it rather than this file where they differ.

## Changing the panel

The short version, with `AGENTS.md` as the detail:

- `Model.js` is pure and Qt-free, so `node test/model.test.js` covers it. Logic
  belongs there, where it can be tested, rather than in QML.
- `Service.qml` owns every process and the state the panel renders.
- `Panel.qml` renders and owns the keyboard cursor.
- `omarchy plugin validate "$PWD"` and `qmllint` before you believe it works.
- `omarchy-restart-shell` to load a QML or JS change. A plugin rescan does not.

Tests, lint and validate all passing means very little about a panel. Most of
what has gone wrong here was only visible by looking: a control that hid itself
when the pointer arrived, a glyph that moved the row it was in, a hover preview
that fired on the wrong element. If `wlrctl` is installed, drive it -- move,
click, screenshot with `grim`, and check what is actually drawn. Put the pointer
back where you found it.

If you change rules or device settings while testing, write down what they were
first and put them back. Verify by comparing, not by remembering.

## Reporting it

Panel bugs and requests go to the repository, not to Control D:

  https://github.com/joaodrp/omarchy-controld-panel

An issue is worth more with the panel version from `manifest.json`, `cdctl
--version`, what was expected, and what appeared instead. A pull request is
worth more than an issue if the fix is small and tested. Offer to open either;
do not open one without being asked.
