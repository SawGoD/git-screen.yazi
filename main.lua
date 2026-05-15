--- git-screen: footer branch indicator + interactive git ops.
--- Layout:
---   main.lua      — setup, entry router, menus (top + submenus)
---   util.lua      — state, helpers, footer renderer
---   commands.lua  — all git operations

local M = {}

-- Tiny local logger so we can record "module loaded" before util is pulled in.
-- Windows-safe path: yazi has no portable temp dir helper, so check separator.
local LOG = (package.config:sub(1, 1) == "\\")
  and ((os.getenv("TEMP") or "C:\\Temp") .. "\\git-screen.log")
  or "/tmp/git-screen.log"
local function _dbg(...)
  local parts = { os.date("%H:%M:%S"), "git-screen:" }
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  local f = io.open(LOG, "a")
  if f then f:write(table.concat(parts, " "), "\n"); f:close() end
end
_dbg("module loaded")

-- Submodules are loaded LAZILY to avoid yazi's async-require nesting,
-- which crashes on Windows with "attempt to yield across a C-call boundary".
-- By the time setup()/entry() runs, the outer require("git-screen") has
-- already completed, so a fresh require for siblings is no longer nested.
local U, C
local function lazy_load()
  if U then return end
  U = require("git-screen.util")
  C = require("git-screen.commands")
end

------------------------------------------------------------
-- Setup (sync; runs from init.lua)
------------------------------------------------------------
function M:setup()
  lazy_load()
  U.dbg("setup")
  -- ps.sub("cd") callback runs sync (no coroutine); defer to async entry.
  ps.sub("cd", function()
    U.dbg("cd event -> emit refresh")
    ya.emit("plugin", { "git-screen", args = "refresh" })
  end)

  Status:children_add(function() return U.render_status() end, 500, Status.RIGHT)
end

------------------------------------------------------------
-- Menus (forward-decl cmd_menu so submenus' ← back works)
------------------------------------------------------------
local cmd_menu

local function cmd_branch_menu()
  if not C.require_repo() then return end
  local cands = {
    { on = "s", desc = "switch branch" },
    { on = "c", desc = "create branch (from current)" },
    { on = "d", desc = "delete local branch" },
    { on = "D", desc = "force-delete local branch (unmerged)" },
    { on = "r", desc = "delete REMOTE branch (push --delete)" },
    { on = "<Left>", desc = "← back" },
  }
  local idx = U.which_fn { cands = cands }
  if not idx then return end
  local key = cands[idx].on
  if     key == "s" then C.branch_switch()
  elseif key == "c" then C.branch_create()
  elseif key == "d" then C.branch_delete(false)
  elseif key == "D" then C.branch_delete(true)
  elseif key == "r" then C.branch_delete_remote()
  elseif key == "<Left>" then cmd_menu()
  end
end

local function cmd_stash_menu()
  if not C.require_repo() then return end
  local cands = {
    { on = "s", desc = "stash push -u (with optional message)" },
    { on = "p", desc = "pop (latest, or pick)" },
    { on = "a", desc = "apply (latest, or pick)" },
    { on = "l", desc = "list (compact, in pager)" },
    { on = "S", desc = "show diff (pick stash)" },
    { on = "d", desc = "drop (pick + confirm)" },
    { on = "c", desc = "clear ALL (confirm)" },
    { on = "b", desc = "branch from stash (pick + name)" },
    { on = "<Left>", desc = "← back" },
  }
  local idx = U.which_fn { cands = cands }
  if not idx then return end
  local key = cands[idx].on
  if     key == "s" then C.stash_push()
  elseif key == "p" then C.stash_apply_or_pop(true)
  elseif key == "a" then C.stash_apply_or_pop(false)
  elseif key == "l" then C.stash_list()
  elseif key == "S" then C.stash_show()
  elseif key == "d" then C.stash_drop()
  elseif key == "c" then C.stash_clear()
  elseif key == "b" then C.stash_branch()
  elseif key == "<Left>" then cmd_menu()
  end
end

-- forward-decl so submenus can go back to parent.
local cmd_gitignore_menu

local function cmd_gitignore_templates_menu()
  if not C.require_repo() then return end
  local cands = {
    { on = "b", desc = "Basic — env / IDE / OS / logs / archives" },
    { on = "n", desc = "Node.js — node_modules / dist / .next / coverage / …" },
    { on = "p", desc = "Python — venv / __pycache__ / dist / pytest / mypy / …" },
    { on = "r", desc = "Rust — target / coverage / profraw / …" },
    { on = "g", desc = "Go — bin / dist / coverage / .test / …" },
    { on = "<Left>", desc = "← back" },
  }
  local idx = U.which_fn { cands = cands }
  if not idx then return end
  local key = cands[idx].on
  if key == "<Left>" then cmd_gitignore_menu(); return end
  local names = { b = "basic", n = "node", p = "python", r = "rust", g = "go" }
  local name = names[key]
  if name then C.gitignore_template(name) end
end

local function cmd_local_exclude_menu()
  if not C.require_repo() then return end
  local cands = {
    { on = "i", desc = "local ignore (.git/info/exclude)" },
    { on = "t", desc = "local track (negate `!rule`)" },
    { on = "p", desc = "local pattern input" },
    { on = "l", desc = "list local rules (in pager)" },
    { on = "r", desc = "remove local rule (picker)" },
    { on = "<Left>", desc = "← back" },
  }
  local idx = U.which_fn { cands = cands }
  if not idx then return end
  local key = cands[idx].on
  if     key == "i" then C.exclude_add()
  elseif key == "t" then C.exclude_negate()
  elseif key == "p" then C.exclude_pattern()
  elseif key == "l" then C.exclude_list()
  elseif key == "r" then C.exclude_remove()
  elseif key == "<Left>" then cmd_gitignore_menu()
  end
end

cmd_gitignore_menu = function()
  if not C.require_repo() then return end
  local cands = {
    { on = "i", desc = "ignore selected/hovered" },
    { on = "t", desc = "track (negate `!rule`) selected/hovered" },
    { on = "p", desc = "pattern input (e.g. *.log, build/)" },
    { on = "l", desc = "list rules (in pager)" },
    { on = "r", desc = "remove rule (picker)" },
    { on = "T", desc = "templates submenu (basic / node / python / rust / go)" },
    { on = "x", desc = "local exclude submenu (.git/info/exclude)" },
    { on = "<Left>", desc = "← back" },
  }
  local idx = U.which_fn { cands = cands }
  if not idx then return end
  local key = cands[idx].on
  if     key == "i" then C.gitignore_add()
  elseif key == "t" then C.gitignore_negate()
  elseif key == "p" then C.gitignore_pattern()
  elseif key == "l" then C.gitignore_list()
  elseif key == "r" then C.gitignore_remove()
  elseif key == "T" then cmd_gitignore_templates_menu()
  elseif key == "x" then cmd_local_exclude_menu()
  elseif key == "<Left>" then cmd_menu()
  end
end

local function cmd_commit_menu()
  if not C.require_repo() then return end
  local cands = {
    { on = "c", desc = "commit SELECTED (or hovered if none)" },
    { on = "C", desc = "commit ALL (add -A)" },
    { on = "a", desc = "amend last commit (edit msg)" },
    { on = "h", desc = "commit history graph" },
    { on = "l", desc = "log -10 (compact table)" },
    { on = "<Left>", desc = "← back" },
  }
  local idx = U.which_fn { cands = cands }
  if not idx then return end
  local key = cands[idx].on
  if     key == "c" then C.commit_selected()
  elseif key == "C" then C.commit_all()
  elseif key == "a" then C.amend()
  elseif key == "h" then C.history()
  elseif key == "l" then C.log10()
  elseif key == "<Left>" then cmd_menu()
  end
end

cmd_menu = function()
  local cwd = U.get_cwd()
  local st = U.compute(cwd)
  U.set_state(st)

  local cands
  if not st.is_repo then
    cands = {
      { on = "i", desc = "init repo here" },
      { on = "c", desc = "clone repo here (input URL)" },
    }
  else
    cands = {
      { on = "b", desc = "branches menu (switch / create / delete / remote-delete)" },
      { on = "s", desc = "stash menu (push / pop / apply / list / show / drop / clear / branch)" },
      { on = "c", desc = "commit menu (commit / amend / history / log)" },
      { on = "i", desc = "gitignore menu (ignore / track / pattern / remove)" },
      { on = "f", desc = "fetch --all --prune" },
      { on = "p", desc = "push" },
      { on = "P", desc = "pull" },
      { on = "d", desc = "diff hovered file" },
      { on = "r", desc = "refresh indicator" },
    }
  end

  local idx = U.which_fn { cands = cands }
  if not idx then return end
  local key = cands[idx].on

  if     key == "i" and not st.is_repo then C.init()
  elseif key == "c" and not st.is_repo then C.clone()
  elseif key == "i" then cmd_gitignore_menu()
  elseif key == "b" then cmd_branch_menu()
  elseif key == "s" then cmd_stash_menu()
  elseif key == "c" then cmd_commit_menu()
  elseif key == "f" then C.fetch()
  elseif key == "p" then C.push()
  elseif key == "P" then C.pull()
  elseif key == "d" then C.diff()
  elseif key == "r" then U.refresh()
  end
end

------------------------------------------------------------
-- Entry (async — coroutine; required for Command:output)
------------------------------------------------------------
function M:entry(job)
  lazy_load()
  local sub = job and job.args and job.args[1]
  U.dbg("entry:", sub or "<nil>")

  -- no args = invoked by ps.sub("cd") emit; refresh silently
  if not sub or sub == "" then
    U.refresh()
    return
  end

  local ok, err = pcall(function()
    if     sub == "menu"     then cmd_menu()
    elseif sub == "init"     then C.init()
    elseif sub == "clone"    then C.clone()
    elseif sub == "branches" then cmd_branch_menu()
    elseif sub == "switch"   then C.branch_switch()
    elseif sub == "history"  then C.history()
    elseif sub == "status"   then C.status()
    elseif sub == "stash"    then cmd_stash_menu()
    elseif sub == "gitignore" then cmd_gitignore_menu()
    elseif sub == "commit"   then C.commit_all()
    elseif sub == "amend"    then C.amend()
    elseif sub == "log10"    then C.log10()
    elseif sub == "fetch"    then C.fetch()
    elseif sub == "push"     then C.push()
    elseif sub == "pull"     then C.pull()
    elseif sub == "diff"     then C.diff()
    elseif sub == "refresh"  then U.refresh()
    else U.notify("unknown subcommand: " .. tostring(sub), "warn") end
  end)
  if not ok then
    U.dbg("entry error:", err)
    U.notify("error: " .. tostring(err), "error")
  end
end

return M
