# git-screen.yazi

A [yazi](https://yazi-rs.github.io) plugin that turns the file manager into a
lightweight git client:

- **footer indicator** — current branch + `↑ahead ↓behind`, colored by state
  (green clean / yellow dirty / red conflict);
- **`o g` menu** — branch ops, commit (selected / all / amend), history graph,
  fetch / push / pull, diff, init;
- **selection-aware commit** — `c` commits the files marked with `<Space>` in
  yazi; falls back to the hovered file if nothing is selected;
- **auto-prompts** — when `git push` / `git pull` need a remote or upstream
  that isn't configured, an input popup asks for it instead of dumping git's
  hint text.

## Requirements

| Tool          | Required        | Notes                                              |
| ------------- | --------------- | -------------------------------------------------- |
| `yazi`        | **≥ 26.1**      | Uses `ui.render`, `pos = ...`, `ps.sub` APIs.      |
| `git`         | **required**    | Any modern version (≥ 2.30 recommended).           |
| `less`        | recommended     | Used for the commit graph / `log -10` viewer. Any `$PAGER` works. |
| `delta`       | optional        | If present, `o g d` uses it for prettier diffs; otherwise falls back to `$PAGER`. |
| `bash`        | required        | The history / push / pull viewers shell out via `bash`. |

No Lua dependencies — pure plugin code.

## Installation

### 1. Drop the plugin into yazi's plugin dir

```bash
git clone <this-repo> ~/.config/yazi/plugins/git-screen.yazi
# OR copy the folder manually so the layout is:
#   ~/.config/yazi/plugins/git-screen.yazi/main.lua
```

### 2. Load the plugin from `init.lua`

Add the following line to `~/.config/yazi/init.lua` (create it if missing):

```lua
require("git-screen"):setup()
```

This is what attaches the footer indicator and subscribes to `cd` events.

### 3. Wire the hotkey in `keymap.toml`

Add one binding under `[mgr] prepend_keymap` in `~/.config/yazi/keymap.toml`:

```toml
[mgr]
prepend_keymap = [
  { on = [ "o", "g" ], run = "plugin git-screen -- menu", desc = "Open git screen" },
]
```

That's the only keymap entry needed — all sub-actions live inside the
plugin's own picker.

### 4. (Optional) Make popup borders stand out

The plugin uses yazi's standard input popup. To recolor its border, edit
`~/.config/yazi/theme.toml`:

```toml
[input]
border = { fg = "magenta" }
```

### 5. Restart yazi

After restarting, navigate into any git repo — the footer should show the
branch indicator, and `o g` should open the menu.

## Usage cheatsheet

```
o g           open git-screen menu

  in non-repo:
    i   init repo here

  in repo (top level):
    b   branches submenu  → s switch / c create / d delete / D force-delete / r remote-delete
    s   stash submenu     → s push / p pop / a apply / l list / S show / d drop / c clear / b branch
    c   commit submenu    → c commit selected / C commit all / a amend / h history graph / l log -10
    f   git fetch --all --prune
    p   git push   (in-yazi output; conflict-aware: rebase + retry or force-with-lease)
    P   git pull   (in-yazi output; merge conflicts → list files + offer merge --abort)
    d   git diff of hovered file (delta or $PAGER)
    r   refresh footer indicator

  inside any submenu:
    ←   back to parent menu
```

Toasts only fire on explicit actions; navigation through directories silently
refreshes the indicator.

## Troubleshooting

- **Indicator doesn't appear.** Check that `require("git-screen"):setup()` is
  in `init.lua` and that the directory contains a `.git`.
- **Hotkey opens, nothing happens.** Look at `/tmp/git-screen.log` — the
  plugin writes a line per invocation/event.
- **`o g c l` shows file paths instead of commit data.** Yazi expands
  `%`-placeholders in shell commands; if you fork the plugin, escape `%` with
  `%%` (see the `sh_pct` helper in `main.lua`).
- **`attempt to yield from outside a coroutine`.** Don't add `--- @sync entry`
  to the plugin — `Command:output()` requires running in a coroutine.

## Layout

```
~/.config/yazi/plugins/git-screen.yazi/
├── main.lua        plugin source
└── README.md       this file
```
