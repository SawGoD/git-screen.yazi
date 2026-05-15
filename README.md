# git-screen.yazi

A [yazi](https://yazi-rs.github.io) plugin that turns the file manager into a
lightweight git client:

- **footer indicator** — current branch + `↑ahead ↓behind`, colored by state
  (green clean / yellow dirty / red conflict);
- **`o g` menu** — branch ops, stash, commit (selected / all / amend), history
  graph, fetch / push / pull, diff, init, and a full `.gitignore` / local
  exclude editor;
- **selection-aware** — `c` commits / `i` adds to .gitignore for the files
  marked with `<Space>` in yazi; falls back to the hovered file if nothing
  is selected;
- **auto-prompts** — when `git push` / `git pull` need a remote or upstream
  that isn't configured, an input popup asks for it instead of dumping git's
  hint text;
- **safe-by-default gitignore** — refuses to ignore `.git/` or `.gitignore`
  itself; warns before ignoring VCS metadata (`.gitattributes`, `.mailmap`,
  `.github`, `.gitlab`, `.gitmodules`); reconciles contradictions instead of
  appending them.

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

Open with `o g`. In any submenu, `←` returns to the parent. `Esc` closes
the menu entirely. Toasts only fire on explicit actions; navigation through
directories silently refreshes the footer indicator.

### Top-level menu (`o g`)

When the current directory is **not** a git repo:

| Key | Action                              |
| --- | ----------------------------------- |
| `i` | init repo here                      |
| `c` | clone repo here (input URL)         |

When inside a git repo, the full menu (with submenus) is shown below. `←`
always returns to the parent menu.

| Trigger | Sub             | Key | Action                                              |
| ------- | --------------- | --- | --------------------------------------------------- |
| `o g`   | `b · branches`  | `s` | switch branch (picker)                              |
|         |                 | `c` | create branch from current (input name)             |
|         |                 | `d` | delete local branch (-d)                            |
|         |                 | `D` | force-delete local branch (-D; unmerged)            |
|         |                 | `r` | delete REMOTE branch (push --delete)                |
|         |                 | `←` | back                                                |
|         | `s · stash`     | `s` | stash push -u (optional message)                    |
|         |                 | `p` | pop (latest, or pick if many)                       |
|         |                 | `a` | apply (latest, or pick if many)                     |
|         |                 | `l` | list (compact, in pager)                            |
|         |                 | `S` | show (diff of picked stash)                         |
|         |                 | `d` | drop (pick + confirm)                               |
|         |                 | `c` | clear ALL stashes (confirm; shows count)            |
|         |                 | `b` | branch from stash (pick + name input)               |
|         |                 | `←` | back                                                |
|         | `c · commit`    | `c` | commit SELECTED (Space-marked) or hovered           |
|         |                 | `C` | commit ALL (add -A)                                 |
|         |                 | `a` | amend last commit (msg pre-filled)                  |
|         |                 | `h` | commit-graph history (in pager)                     |
|         |                 | `l` | last 10 commits (compact table, in pager)           |
|         |                 | `←` | back                                                |
|         | `i · gitignore` | `i` | ignore SELECTED (Space-marked) or hovered           |
|         |                 | `t` | track (negate `!rule`) selected/hovered             |
|         |                 | `p` | pattern input (e.g. `*.log`, `build/`)              |
|         |                 | `l` | list .gitignore rules (in pager)                    |
|         |                 | `r` | remove rule (picker)                                |
|         |                 | `T` | open **templates** submenu (see below)              |
|         |                 | `x` | open **local exclude** submenu (see below)          |
|         |                 | `←` | back                                                |
|         | `f · fetch`     |     | git fetch --all --prune (silent + refresh)          |
|         | `p · push`      |     | auto-prompts remote/upstream; handles rejected push |
|         | `P · pull`      |     | auto-prompts upstream; surfaces merge conflicts     |
|         | `d · diff`      |     | git diff of hovered file (delta or $PAGER)          |
|         | `r · refresh`   |     | force-refresh footer indicator                      |

### Templates submenu (`o g i T`)

Appends a curated `.gitignore` template to the current file. Rules already
present in the file are skipped — only missing ones are added, under a
clearly marked `# --- <name> (git-screen template) ---` header. Section
comments come along only when at least one rule from the section is new
(no orphan headers).

| Key | Template                                                  |
| --- | --------------------------------------------------------- |
| `b` | Basic — env / IDE / OS / logs / archives                  |
| `n` | Node.js — node_modules / dist / .next / coverage / …      |
| `p` | Python — venv / __pycache__ / dist / pytest / mypy / …    |
| `r` | Rust — target / coverage / profraw / …                    |
| `g` | Go — bin / dist / coverage / .test / …                    |
| `←` | back to gitignore submenu                                 |

### Local exclude submenu (`o g i x`)

Operates on `.git/info/exclude` instead of `.gitignore`. Rules added here
never leave your machine — perfect for personal mess (editor swap files,
local scratch dirs, etc.) without committing them to the team's ignore
list. Same set of actions as the parent submenu:

| Key | Action                                                |
| --- | ----------------------------------------------------- |
| `i` | local ignore SELECTED/hovered                         |
| `t` | local track (negate `!rule`)                          |
| `p` | local pattern input                                   |
| `l` | list current local rules (in pager)                   |
| `r` | remove local rule (picker)                            |
| `←` | back to gitignore submenu                             |

### Confirmation prompts

Several actions follow up with a small `y` / `←` picker before doing
anything destructive or otherwise surprising:

| Where it fires                                              | Choices                                                              |
| ----------------------------------------------------------- | -------------------------------------------------------------------- |
| `o g s d` (drop stash)                                      | `y` drop · `←` cancel                                                |
| `o g s c` (clear ALL stashes)                               | `y` clear · `←` cancel                                               |
| ignore a tracked file                                       | `y` `git rm --cached` + add ignore · `←` skip                        |
| ignore VCS metadata (`.gitattributes`, `.mailmap`, `.github`, `.gitlab`, `.gitmodules`) | `y` yes anyway · `←` cancel |
| `o g i p` / `o g i x p` (pattern entered)                   | `i` add as ignore · `t` add as track (negate) · `←` cancel           |
| **push rejected (non-fast-forward)**                        | `p` `pull --rebase` + retry · `f` `push --force-with-lease` · `←` cancel |
| **pull → merge conflict**                                   | `a` `git merge --abort` · `←` keep conflicts to resolve manually     |

A few paths/patterns are hard-blocked from `.gitignore` and
`.git/info/exclude` with no override: `.git/` and anything under it, and
`.gitignore` itself. Toast: *refusing to touch ... in .gitignore*.

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
├── main.lua        setup, entry router, menus (top + 5 submenus)
├── util.lua        state, helpers, footer renderer, ensure_remote
├── commands.lua    all git operations (init / branches / stash / commit / gitignore / sync)
└── README.md       this file
```

`main.lua` is the entry point yazi loads via `require("git-screen"):setup()`.
It pulls in the other two via `require("git-screen.util")` and
`require("git-screen.commands")`. Yazi's plugin loader maps dotted module
names to sibling files inside the plugin directory.

Both `util.lua` and `commands.lua` return plain tables — **not factories.**
Yazi rejects modules that return a function with `error converting Lua
function to table`. `commands.lua` imports util itself instead of receiving
it as an argument.
