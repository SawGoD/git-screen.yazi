--- git-screen: footer branch indicator + interactive git ops

local M = {}

local LOG = "/tmp/git-screen.log"
local function dbg(...)
  local parts = { os.date("%H:%M:%S"), "git-screen:" }
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  local f = io.open(LOG, "a")
  if f then f:write(table.concat(parts, " "), "\n"); f:close() end
end
dbg("module loaded")

-- yazi 26.x renamed several APIs from `ya.*` to `ui.*`. Use whichever exists.
local input_fn = (ui and ui.input) or ya.input
local which_fn = (ui and ui.which) or ya.which

------------------------------------------------------------
-- State stored in a sync closure so footer renderer (sync) and
-- async ops can both reach it via ya.sync setters/getters.
------------------------------------------------------------
local set_state = ya.sync(function(st, new)
  st.git = new
  ui.render()
end)

local get_state = ya.sync(function(st)
  return st.git or {}
end)

local get_cwd = ya.sync(function()
  return tostring(cx.active.current.cwd)
end)

local get_hovered = ya.sync(function()
  local h = cx.active.current.hovered
  return h and tostring(h.url) or nil
end)

-- Returns list of selected file paths. Falls back to hovered if nothing is
-- explicitly selected.
local get_selected = ya.sync(function()
  local paths = {}
  for _, u in pairs(cx.active.selected or {}) do
    paths[#paths + 1] = tostring(u)
  end
  if #paths == 0 then
    local h = cx.active.current.hovered
    if h then paths[1] = tostring(h.url) end
  end
  return paths
end)

------------------------------------------------------------
-- Async helpers (run in coroutine context)
------------------------------------------------------------
local function run(cwd, args)
  local out, err = Command("git")
    :cwd(cwd)
    :arg(args)
    :stdout(Command.PIPED)
    :stderr(Command.PIPED)
    :output()
  if not out then return nil, tostring(err) end
  if not out.status.success then
    return nil, (out.stderr or ""):gsub("%s+$", "")
  end
  return (out.stdout or ""):gsub("%s+$", ""), nil
end

local function trim(s)
  local r = (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return r
end

local function split_lines(s)
  local t = {}
  for line in (s or ""):gmatch("[^\r\n]+") do t[#t + 1] = line end
  return t
end

local function compute(cwd)
  local s = { cwd = cwd, is_repo = false, branch = nil,
              ahead = 0, behind = 0, dirty = false, conflict = false }

  local top = run(cwd, { "rev-parse", "--show-toplevel" })
  if not top or top == "" then
    dbg("compute: not a repo", cwd)
    return s
  end
  s.is_repo = true

  local br = run(cwd, { "symbolic-ref", "--short", "HEAD" })
  if not br or br == "" then
    br = run(cwd, { "rev-parse", "--short", "HEAD" }) or "?"
    s.branch = "(" .. br .. ")"
  else
    s.branch = br
  end

  local lr = run(cwd, { "rev-list", "--left-right", "--count", "@{upstream}...HEAD" })
  if lr then
    local b, a = lr:match("(%d+)%s+(%d+)")
    s.behind = tonumber(b) or 0
    s.ahead = tonumber(a) or 0
  end

  local pst = run(cwd, { "status", "--porcelain" })
  if pst and pst ~= "" then
    s.dirty = true
    for _, line in ipairs(split_lines(pst)) do
      local xy = line:sub(1, 2)
      if xy:find("U") or xy == "AA" or xy == "DD" then
        s.conflict = true
        break
      end
    end
  end
  dbg("compute:", s.branch, "ahead", s.ahead, "behind", s.behind, "dirty", s.dirty)
  return s
end

local function refresh()
  local cwd = get_cwd()
  local s = compute(cwd)
  set_state(s)
end

------------------------------------------------------------
-- Footer render (called sync by yazi)
------------------------------------------------------------
local function render_status()
  local st = get_state()
  if not st.is_repo then return ui.Line("") end

  local color
  if st.conflict then color = "red"
  elseif st.dirty then color = "yellow"
  else color = "green" end

  local spans = {
    ui.Span(" "),
    ui.Span(" " .. (st.branch or "?") .. " "):fg(color):bold(),
  }
  if (st.ahead or 0) > 0 then
    spans[#spans + 1] = ui.Span("↑" .. st.ahead .. " "):fg("blue")
  end
  if (st.behind or 0) > 0 then
    spans[#spans + 1] = ui.Span("↓" .. st.behind .. " "):fg("magenta")
  end
  return ui.Line(spans)
end

------------------------------------------------------------
-- Setup (sync; runs from init.lua)
------------------------------------------------------------
function M:setup()
  dbg("setup")
  -- ps.sub callback runs sync (no coroutine), so we can't call Command directly.
  -- Defer to our async entry via ya.emit("plugin", ...).
  ps.sub("cd", function()
    dbg("cd event -> emit refresh")
    ya.emit("plugin", { "git-screen", args = "refresh" })
  end)

  Status:children_add(function() return render_status() end, 500, Status.RIGHT)
end

------------------------------------------------------------
-- Notifications / shell (sync wrappers)
------------------------------------------------------------
local function notify(content, level, title)
  ya.notify({
    title = title or "git-screen",
    content = tostring(content),
    timeout = 3.0,
    level = level or "info",
  })
end

local emit_shell = ya.sync(function(_, cmd)
  ya.emit("shell", { cmd, block = true, confirm = false })
end)

local clear_selection = ya.sync(function()
  ya.emit("escape", { select = true })
end)

-- Capture git invocation output. Returns (success, combined_text).
local function git_capture(cwd, args)
  local out, err = Command("git")
    :cwd(cwd)
    :arg(args)
    :stdout(Command.PIPED)
    :stderr(Command.PIPED)
    :output()
  if not out then return false, tostring(err or "spawn failed") end
  local txt = (out.stdout or "") .. (out.stderr or "")
  return out.status.success, (txt:gsub("%s+$", ""))
end

-- Long-lived notification for command output. level: "info" | "warn" | "error".
local function show_output(title, body, level)
  ya.notify {
    title = title,
    content = (body == "" and "(empty output)" or body),
    timeout = 20.0,
    level = level or "info",
  }
end

-- Ensure a remote exists; returns first remote name or nil if user cancelled.
local function ensure_remote(cwd)
  local remotes = run(cwd, { "remote" }) or ""
  if remotes ~= "" then return (split_lines(remotes))[1] end

  local url, uevt = input_fn {
    title = "Add remote `origin` URL:",
    value = "",
    pos = { "center", w = 70 },
  }
  if uevt ~= 1 or not url or trim(url) == "" then return nil end
  local _, re = run(cwd, { "remote", "add", "origin", trim(url) })
  if re then notify("remote add failed: " .. re, "error"); return nil end
  notify("added origin: " .. trim(url))
  return "origin"
end

------------------------------------------------------------
-- Commands (async; entry is a coroutine)
------------------------------------------------------------
local function cmd_init()
  local cwd = get_cwd()
  local st = compute(cwd)
  if st.is_repo then
    notify("Already a git repo: " .. (st.branch or "?"))
    return
  end
  local _, err = run(cwd, { "init" })
  if err then notify("git init failed: " .. err, "error"); return end
  notify("Initialized git repo in " .. cwd)
  refresh()
end

local function require_repo()
  local cwd = get_cwd()
  local st = compute(cwd)
  set_state(st)
  if not st.is_repo then return nil end
  return cwd, st
end

-- Branch picker: returns selected ref name or nil. `scope` = "local" | "remote".
-- `exclude_current` = true to mark and skip current branch.
local function pick_branch(cwd, st, scope, title_hint)
  local refpath = (scope == "remote") and "refs/remotes/" or "refs/heads/"
  local out, err = run(cwd, {
    "for-each-ref",
    "--sort=-committerdate",
    "--format=%(refname:short)\t%(objectname:short)\t%(subject)",
    refpath,
  })
  if err then notify("list branches failed: " .. err, "error"); return nil end
  local lines = split_lines(out)
  if #lines == 0 then notify("no " .. scope .. " branches", "warn"); return nil end

  local keys = "abcdefghijklmnopqrstuvwxyz0123456789"
  local cands, mapping = {}, {}
  for i, line in ipairs(lines) do
    if i > #keys then break end
    local ref, sha, subj = line:match("^([^\t]+)\t([^\t]+)\t(.*)$")
    if ref and ref ~= "origin/HEAD" then
      local k = keys:sub(i, i)
      local marker = (scope == "local" and ref == st.branch) and "* " or "  "
      cands[#cands + 1] = {
        on = k,
        desc = string.format("%s[%s] %s  %s  %s",
          marker, title_hint or scope, ref, sha, subj or ""),
      }
      mapping[i] = ref
    end
  end

  local idx = which_fn { cands = cands }
  if not idx then return nil end
  return mapping[idx]
end

local function cmd_branch_switch()
  local cwd, st = require_repo(); if not cwd then return end
  local target = pick_branch(cwd, st, "local", "switch")
  if not target or target == st.branch then return end
  local _, ce = run(cwd, { "checkout", target })
  if ce then notify("checkout failed: " .. ce, "error"); return end
  notify("Switched to " .. target)
  refresh()
end

local function cmd_branch_create()
  local cwd, st = require_repo(); if not cwd then return end
  local name, evt = input_fn {
    title = "New branch name (created from `" .. (st.branch or "?") .. "`):",
    value = "",
    pos = { "center", w = 60 },
  }
  if evt ~= 1 or not name or trim(name) == "" then return end
  local _, ce = run(cwd, { "checkout", "-b", trim(name) })
  if ce then notify("create failed: " .. ce, "error"); return end
  notify("Created and switched to " .. trim(name))
  refresh()
end

local function cmd_branch_delete(force)
  local cwd, st = require_repo(); if not cwd then return end
  local target = pick_branch(cwd, st, "local",
    force and "DELETE -D" or "delete -d")
  if not target then return end
  if target == st.branch then
    notify("cannot delete current branch", "warn"); return
  end
  local _, ce = run(cwd, { "branch", force and "-D" or "-d", target })
  if ce then notify("delete failed: " .. ce, "error"); return end
  notify((force and "Force-deleted " or "Deleted ") .. target)
  refresh()
end

local function cmd_branch_delete_remote()
  local cwd, st = require_repo(); if not cwd then return end
  local target = pick_branch(cwd, st, "remote", "delete remote")
  if not target then return end
  -- target looks like "origin/feature-x"; split
  local remote, branch = target:match("^([^/]+)/(.+)$")
  if not remote or not branch then
    notify("can't parse remote ref: " .. target, "error"); return
  end
  emit_shell("cd " .. string.format("%q", cwd)
    .. string.format(" && git push %q --delete %q;", remote, branch)
    .. " echo; echo '[press any key]'; read -n1 _")
  refresh()
end

-- forward decl so submenus can call cmd_menu (defined below)
local cmd_menu

local function cmd_branch_menu()
  if not require_repo() then return end
  local cands = {
    { on = "s", desc = "switch branch" },
    { on = "c", desc = "create branch (from current)" },
    { on = "d", desc = "delete local branch" },
    { on = "D", desc = "force-delete local branch (unmerged)" },
    { on = "r", desc = "delete REMOTE branch (push --delete)" },
    { on = "<Left>", desc = "← back" },
  }
  local idx = which_fn { cands = cands }
  if not idx then return end
  local key = cands[idx].on
  if     key == "s" then cmd_branch_switch()
  elseif key == "c" then cmd_branch_create()
  elseif key == "d" then cmd_branch_delete(false)
  elseif key == "D" then cmd_branch_delete(true)
  elseif key == "r" then cmd_branch_delete_remote()
  elseif key == "<Left>" then cmd_menu()
  end
end

------------------------------------------------------------
-- Stash submenu (o g s)
------------------------------------------------------------

-- Pick a stash from `git stash list`; returns "stash@{N}" or nil.
local function pick_stash(cwd, hint)
  local out, err = run(cwd, { "stash", "list", "--format=%gd|%gs" })
  if err then notify("stash list failed: " .. err, "error"); return nil end
  if not out or out == "" then notify("no stashes", "warn"); return nil end

  local keys = "abcdefghijklmnopqrstuvwxyz0123456789"
  local cands, mapping = {}, {}
  for i, line in ipairs(split_lines(out)) do
    if i > #keys then break end
    local ref, subj = line:match("^([^|]+)|(.*)$")
    if ref then
      local k = keys:sub(i, i)
      cands[#cands + 1] = {
        on = k,
        desc = string.format("[%s] %s  %s", hint or "stash", ref, subj or ""),
      }
      mapping[i] = ref
    end
  end
  local idx = which_fn { cands = cands }
  if not idx then return nil end
  return mapping[idx]
end

local function cmd_stash_push()
  local cwd, st = require_repo(); if not cwd then return end
  if not st.dirty then notify("nothing to stash (clean tree)", "warn"); return end

  local msg, evt = input_fn {
    title = "Stash message (empty = WIP):",
    pos = { "center", w = 60 },
  }
  if evt ~= 1 then return end
  msg = trim(msg or "")

  local args = { "stash", "push", "-u" }
  if msg ~= "" then args[#args + 1] = "-m"; args[#args + 1] = msg end

  local _, err = run(cwd, args)
  if err then notify("stash push failed: " .. err, "error"); return end
  clear_selection()
  notify("stashed" .. (msg ~= "" and (": " .. msg) or ""))
  refresh()
end

-- Apply or pop most-recent if only one stash, else pick.
local function cmd_stash_apply_or_pop(pop)
  local cwd = require_repo(); if not cwd then return end
  local list = run(cwd, { "stash", "list" }) or ""
  if list == "" then notify("no stashes", "warn"); return end

  local target
  if #split_lines(list) == 1 then
    target = "stash@{0}"
  else
    target = pick_stash(cwd, pop and "pop" or "apply")
    if not target then return end
  end

  local ok, output = git_capture(cwd, { "stash", pop and "pop" or "apply", target })
  if ok then
    notify((pop and "popped " or "applied ") .. target)
  else
    show_output((pop and "stash pop" or "stash apply") .. " ✗", output, "error")
  end
  refresh()
end

local function cmd_stash_list()
  local cwd = require_repo(); if not cwd then return end
  local list = run(cwd, { "stash", "list" }) or ""
  if list == "" then notify("no stashes", "warn"); return end
  local pager = os.getenv("PAGER") or "less -R"
  local cmd = "cd " .. string.format("%q", cwd)
    .. " && git --no-pager stash list --color=always"
    .. " --format='%C(yellow)%gd%C(reset)  %C(cyan)%cr%C(reset)  %gs' | " .. pager
  emit_shell((cmd:gsub("%%", "%%%%")))  -- escape % for yazi shell expansion
end

local function cmd_stash_show()
  local cwd = require_repo(); if not cwd then return end
  local list = run(cwd, { "stash", "list" }) or ""
  if list == "" then notify("no stashes", "warn"); return end

  local target
  if #split_lines(list) == 1 then
    target = "stash@{0}"
  else
    target = pick_stash(cwd, "show diff")
    if not target then return end
  end
  local pager = os.getenv("PAGER") or "less -R"
  local viewer = (os.execute("command -v delta >/dev/null 2>&1") == 0) and "delta" or pager
  emit_shell("cd " .. string.format("%q", cwd)
    .. " && git stash show -p --color=always " .. target .. " | " .. viewer)
end

local function cmd_stash_drop()
  local cwd = require_repo(); if not cwd then return end
  local target = pick_stash(cwd, "DROP")
  if not target then return end

  local cands = {
    { on = "y", desc = "drop " .. target .. " (irreversible)" },
    { on = "<Left>", desc = "← cancel" },
  }
  local idx = which_fn { cands = cands }
  if not idx or cands[idx].on ~= "y" then return end
  local _, err = run(cwd, { "stash", "drop", target })
  if err then notify("drop failed: " .. err, "error"); return end
  notify("dropped " .. target)
end

local function cmd_stash_clear()
  local cwd = require_repo(); if not cwd then return end
  local list = run(cwd, { "stash", "list" }) or ""
  if list == "" then notify("no stashes to clear", "warn"); return end
  local count = #split_lines(list)
  local cands = {
    { on = "y", desc = "CLEAR all " .. count .. " stash(es) (irreversible)" },
    { on = "<Left>", desc = "← cancel" },
  }
  local idx = which_fn { cands = cands }
  if not idx or cands[idx].on ~= "y" then return end
  local _, err = run(cwd, { "stash", "clear" })
  if err then notify("clear failed: " .. err, "error"); return end
  notify("cleared " .. count .. " stash(es)")
end

local function cmd_stash_branch()
  local cwd = require_repo(); if not cwd then return end
  local target = pick_stash(cwd, "→ new branch")
  if not target then return end
  local name, evt = input_fn {
    title = "Branch name from " .. target .. ":",
    pos = { "center", w = 60 },
  }
  if evt ~= 1 or not name or trim(name) == "" then return end
  local _, err = run(cwd, { "stash", "branch", trim(name), target })
  if err then notify("stash branch failed: " .. err, "error"); return end
  notify("created branch `" .. trim(name) .. "` from " .. target)
  refresh()
end

local function cmd_stash_menu()
  if not require_repo() then return end
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
  local idx = which_fn { cands = cands }
  if not idx then return end
  local key = cands[idx].on
  if     key == "s" then cmd_stash_push()
  elseif key == "p" then cmd_stash_apply_or_pop(true)
  elseif key == "a" then cmd_stash_apply_or_pop(false)
  elseif key == "l" then cmd_stash_list()
  elseif key == "S" then cmd_stash_show()
  elseif key == "d" then cmd_stash_drop()
  elseif key == "c" then cmd_stash_clear()
  elseif key == "b" then cmd_stash_branch()
  elseif key == "<Left>" then cmd_menu()
  end
end

-- yazi substitutes %h/%d/%a/%n/etc in shell commands. Escape with %% so
-- yazi passes a literal % to the shell where git/date can use it.
local function sh_pct(s) return (s:gsub("%%", "%%%%")) end

local function cmd_history()
  local cwd = require_repo(); if not cwd then return end
  local pager = os.getenv("PAGER") or "less -R"
  local fmt = sh_pct("%C(auto)%h%d %C(white)%s %C(dim)(%an, %ar)")
  local cmd = "cd " .. string.format("%q", cwd)
    .. " && git log --graph --decorate --all --color=always"
    .. " --pretty=format:'" .. fmt .. "' | " .. pager
  emit_shell(cmd)
end

local function cmd_log10()
  local cwd = require_repo(); if not cwd then return end
  local pager = os.getenv("PAGER") or "less -R"
  local fmt = sh_pct("%C(yellow)%h%C(reset) | %C(cyan)%an%C(reset) | "
    .. "%C(green)%ad%C(reset) | %s")
  local date = sh_pct("%d.%m.%y %H:%M")
  local cmd = "cd " .. string.format("%q", cwd)
    .. " && git log -10 --color=always"
    .. " --pretty=format:'" .. fmt .. "'"
    .. " --date=format:'" .. date .. "'"
    .. " | " .. pager
  emit_shell(cmd)
end

local function cmd_status()
  local cwd = require_repo(); if not cwd then return end
  local out, err = run(cwd, { "status", "--short", "--branch" })
  if err then notify("status failed: " .. err, "error"); return end
  if out == "" then notify("clean working tree"); return end
  ya.notify({ title = "git status", content = out, timeout = 6.0, level = "info" })
end

local function cmd_commit()
  local cwd, st = require_repo(); if not cwd then return end
  if not st.dirty then notify("nothing to commit", "warn"); return end

  local msg, evt = input_fn {
    title = "Commit ALL (add -A) — message:",
    pos = { "center", w = 60 },
  }
  if evt ~= 1 or not msg or trim(msg) == "" then return end

  local _, ae = run(cwd, { "add", "-A" })
  if ae then notify("add failed: " .. ae, "error"); return end
  local out, ce = run(cwd, { "commit", "-m", msg })
  if ce then notify("commit failed: " .. ce, "error"); return end
  notify("Committed: " .. (out and out:match("[^\n]+") or msg))
  refresh()
end

local function cmd_commit_selected()
  local cwd, st = require_repo(); if not cwd then return end
  if not st.dirty then notify("nothing to commit", "warn"); return end

  local files = get_selected()
  if #files == 0 then notify("no files selected/hovered", "warn"); return end

  local msg, evt = input_fn {
    title = string.format("Commit %d file(s) — message:", #files),
    pos = { "center", w = 60 },
  }
  if evt ~= 1 or not msg or trim(msg) == "" then return end

  -- `git add --` accepts absolute paths; safer than relativizing
  local add_args = { "add", "--" }
  for _, p in ipairs(files) do add_args[#add_args + 1] = p end
  local _, ae = run(cwd, add_args)
  if ae then notify("add failed: " .. ae, "error"); return end

  local out, ce = run(cwd, { "commit", "-m", msg })
  if ce then notify("commit failed: " .. ce, "error"); return end
  clear_selection()
  notify(string.format("Committed %d file(s): %s",
    #files, out and out:match("[^\n]+") or msg))
  refresh()
end

local function cmd_push()
  local cwd, st = require_repo(); if not cwd then return end

  local up = run(cwd, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" })
  local push_args
  if not up or up == "" then
    local remote = ensure_remote(cwd); if not remote then return end

    local ref, evt = input_fn {
      title = "First push — `" .. (st.branch or "?") .. "` → (remote/branch):",
      value = remote .. "/" .. (st.branch or ""),
      pos = { "center", w = 60 },
    }
    if evt ~= 1 or not ref or trim(ref) == "" then return end
    local r, b = trim(ref):match("^([^/]+)/(.+)$")
    if not r or not b then
      notify("expected `remote/branch`, got: " .. ref, "error"); return
    end
    push_args = { "push", "--set-upstream", r, (st.branch or "HEAD") .. ":" .. b }
  else
    push_args = { "push" }
  end

  local ok, output = git_capture(cwd, push_args)
  refresh()

  if ok then
    show_output("git push ✓", output, "info")
    return
  end

  -- Detect non-fast-forward / rejected — offer remediation.
  local lower = output:lower()
  if lower:find("rejected") or lower:find("non%-fast%-forward") or lower:find("fetch first") then
    show_output("push rejected", output, "warn")
    local cands = {
      { on = "p", desc = "pull --rebase then push (safe)" },
      { on = "f", desc = "force push (--force-with-lease)" },
      { on = "<Left>", desc = "← cancel" },
    }
    local idx = which_fn { cands = cands }
    if not idx then return end
    local key = cands[idx].on
    if key == "p" then
      local ok2, out2 = git_capture(cwd, { "pull", "--rebase" })
      if not ok2 then show_output("pull --rebase failed", out2, "error"); refresh(); return end
      show_output("rebased ✓ → retrying push", out2, "info")
      local ok3, out3 = git_capture(cwd, { "push" })
      show_output(ok3 and "git push ✓" or "git push ✗", out3, ok3 and "info" or "error")
      refresh()
    elseif key == "f" then
      local ok2, out2 = git_capture(cwd, { "push", "--force-with-lease" })
      show_output(ok2 and "force-push ✓" or "force-push ✗", out2, ok2 and "info" or "error")
      refresh()
    end
    return
  end

  show_output("git push ✗", output, "error")
end

local function cmd_pull()
  local cwd, st = require_repo(); if not cwd then return end

  local up = run(cwd, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" })
  if not up or up == "" then
    local remote = ensure_remote(cwd); if not remote then return end
    local default_ref = remote .. "/" .. (st.branch or "")
    local val, evt = input_fn {
      title = "Set upstream for `" .. (st.branch or "?") .. "` (remote/branch):",
      value = default_ref,
      pos = { "center", w = 60 },
    }
    if evt ~= 1 or not val or trim(val) == "" then return end
    local _, se = run(cwd, { "branch", "--set-upstream-to=" .. trim(val) })
    if se then notify("set-upstream failed: " .. se, "error"); return end
    notify("upstream set: " .. trim(val))
  end

  local ok, output = git_capture(cwd, { "pull" })
  refresh()

  if ok then
    show_output("git pull ✓", output, "info")
    return
  end

  -- Inspect for merge conflicts.
  local conflicts = {}
  local porcelain = run(cwd, { "diff", "--name-only", "--diff-filter=U" })
  if porcelain and porcelain ~= "" then
    for _, p in ipairs(split_lines(porcelain)) do conflicts[#conflicts + 1] = p end
  end

  if #conflicts > 0 then
    local body = output .. "\n\nConflicted files:\n  " .. table.concat(conflicts, "\n  ")
      .. "\n\nResolve, then commit. Or run `git merge --abort` to bail out."
    show_output("pull → MERGE CONFLICT", body, "error")

    local cands = {
      { on = "a", desc = "git merge --abort (roll back pull)" },
      { on = "<Left>", desc = "← keep conflicts to resolve manually" },
    }
    local idx = which_fn { cands = cands }
    if idx and cands[idx].on == "a" then
      local ok2, out2 = git_capture(cwd, { "merge", "--abort" })
      show_output(ok2 and "merge --abort ✓" or "merge --abort ✗",
        out2, ok2 and "info" or "error")
      refresh()
    end
    return
  end

  show_output("git pull ✗", output, "error")
end

local function cmd_amend()
  local cwd = require_repo(); if not cwd then return end
  local last, lerr = run(cwd, { "log", "-1", "--pretty=%B" })
  if lerr then notify("no commits to amend: " .. lerr, "error"); return end

  local msg, evt = input_fn {
    title = "Amend last commit message:",
    value = last or "",
    pos = { "center", w = 70 },
  }
  if evt ~= 1 or not msg or trim(msg) == "" then return end

  -- stage current changes too (so amend bundles them); skip if user wants
  -- message-only amend, they can avoid having dirty tree.
  local _, ae = run(cwd, { "add", "-A" })
  if ae then notify("add failed: " .. ae, "error"); return end

  local _, ce = run(cwd, { "commit", "--amend", "-m", msg })
  if ce then notify("amend failed: " .. ce, "error"); return end
  notify("Amended: " .. (msg:match("[^\n]+") or msg))
  refresh()
end

local function cmd_fetch()
  local cwd = require_repo(); if not cwd then return end
  local _, err = run(cwd, { "fetch", "--all", "--prune" })
  if err then notify("fetch failed: " .. err, "error"); return end
  refresh()
  local st = get_state()
  notify(string.format("fetched: %s ↑%d ↓%d",
    st.branch or "?", st.ahead or 0, st.behind or 0))
end

local function cmd_diff()
  local cwd = require_repo(); if not cwd then return end
  local path = get_hovered()
  if not path then notify("no file under cursor", "warn"); return end
  local viewer = (os.execute("command -v delta >/dev/null 2>&1") == 0)
    and "delta" or (os.getenv("PAGER") or "less -R")
  emit_shell(string.format(
    "cd %q && git diff --color=always -- %q | %s", cwd, path, viewer))
end

------------------------------------------------------------
-- Commit submenu (o g c) — commit-related actions
------------------------------------------------------------
local function cmd_commit_menu()
  if not require_repo() then return end
  local cands = {
    { on = "c", desc = "commit SELECTED (or hovered if none)" },
    { on = "C", desc = "commit ALL (add -A)" },
    { on = "a", desc = "amend last commit (edit msg)" },
    { on = "h", desc = "commit history graph" },
    { on = "l", desc = "log -10 (compact table)" },
    { on = "<Left>", desc = "← back" },
  }
  local idx = which_fn { cands = cands }
  if not idx then return end
  local key = cands[idx].on
  if     key == "c" then cmd_commit_selected()
  elseif key == "C" then cmd_commit()
  elseif key == "a" then cmd_amend()
  elseif key == "h" then cmd_history()
  elseif key == "l" then cmd_log10()
  elseif key == "<Left>" then cmd_menu()
  end
end

------------------------------------------------------------
-- Menu (o g) — top-level picker; only `i` if not a repo
------------------------------------------------------------
cmd_menu = function()
  local cwd = get_cwd()
  local st = compute(cwd)
  set_state(st)

  local cands
  if not st.is_repo then
    cands = { { on = "i", desc = "init repo here" } }
  else
    cands = {
      { on = "b", desc = "branches menu (switch / create / delete / remote-delete)" },
      { on = "s", desc = "stash menu (push / pop / apply / list / show / drop / clear / branch)" },
      { on = "c", desc = "commit menu (commit / amend / history / log)" },
      { on = "f", desc = "fetch --all --prune" },
      { on = "p", desc = "push" },
      { on = "P", desc = "pull" },
      { on = "d", desc = "diff hovered file" },
      { on = "r", desc = "refresh indicator" },
    }
  end

  local idx = which_fn { cands = cands }
  if not idx then return end
  local key = cands[idx].on

  if     key == "i" then cmd_init()
  elseif key == "b" then cmd_branch_menu()
  elseif key == "s" then cmd_stash_menu()
  elseif key == "c" then cmd_commit_menu()
  elseif key == "f" then cmd_fetch()
  elseif key == "p" then cmd_push()
  elseif key == "P" then cmd_pull()
  elseif key == "d" then cmd_diff()
  elseif key == "r" then refresh()
  end
end

------------------------------------------------------------
-- Entry (async — coroutine; required for Command:output)
------------------------------------------------------------
function M:entry(job)
  local sub = job and job.args and job.args[1]
  dbg("entry:", sub or "<nil>")

  -- no args = invoked by ps.sub("cd") emit; just refresh silently
  if not sub or sub == "" then
    refresh()
    return
  end

  local ok, err = pcall(function()
    if     sub == "menu"     then cmd_menu()
    elseif sub == "init"     then cmd_init()
    elseif sub == "branches" then cmd_branch_menu()
    elseif sub == "switch"   then cmd_branch_switch()
    elseif sub == "history"  then cmd_history()
    elseif sub == "status"   then cmd_status()
    elseif sub == "stash"    then cmd_stash_menu()
    elseif sub == "commit"   then cmd_commit()
    elseif sub == "amend"    then cmd_amend()
    elseif sub == "log10"    then cmd_log10()
    elseif sub == "fetch"    then cmd_fetch()
    elseif sub == "push"     then cmd_push()
    elseif sub == "pull"     then cmd_pull()
    elseif sub == "diff"     then cmd_diff()
    elseif sub == "refresh"  then refresh()
    else notify("unknown subcommand: " .. tostring(sub), "warn") end
  end)
  if not ok then
    dbg("entry error:", err)
    notify("error: " .. tostring(err), "error")
  end
end

return M
