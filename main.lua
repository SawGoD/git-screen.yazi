--- git-screen: footer branch indicator + interactive git ops

local U = require("git-screen.util")
U.dbg("module loaded")

local M = {}

------------------------------------------------------------
-- Setup (sync; runs from init.lua)
------------------------------------------------------------
function M:setup()
  U.dbg("setup")
  -- ps.sub("cd") callback runs sync (no coroutine); defer to async entry.
  ps.sub("cd", function()
    U.dbg("cd event -> emit refresh")
    ya.emit("plugin", { "git-screen", args = "refresh" })
  end)

  Status:children_add(function() return U.render_status() end, 500, Status.RIGHT)
end

------------------------------------------------------------
-- Local helpers built on U
------------------------------------------------------------
local function require_repo()
  local cwd = U.get_cwd()
  local st = U.compute(cwd)
  U.set_state(st)
  if not st.is_repo then return nil end
  return cwd, st
end

local function pick_branch(cwd, st, scope, title_hint)
  local refpath = (scope == "remote") and "refs/remotes/" or "refs/heads/"
  local out, err = U.run(cwd, {
    "for-each-ref",
    "--sort=-committerdate",
    "--format=%(refname:short)\t%(objectname:short)\t%(subject)",
    refpath,
  })
  if err then U.notify("list branches failed: " .. err, "error"); return nil end
  local lines = U.split_lines(out)
  if #lines == 0 then U.notify("no " .. scope .. " branches", "warn"); return nil end

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
  local idx = U.which_fn { cands = cands }
  if not idx then return nil end
  return mapping[idx]
end

local function pick_stash(cwd, hint)
  local out, err = U.run(cwd, { "stash", "list", "--format=%gd|%gs" })
  if err then U.notify("stash list failed: " .. err, "error"); return nil end
  if not out or out == "" then U.notify("no stashes", "warn"); return nil end

  local keys = "abcdefghijklmnopqrstuvwxyz0123456789"
  local cands, mapping = {}, {}
  for i, line in ipairs(U.split_lines(out)) do
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
  local idx = U.which_fn { cands = cands }
  if not idx then return nil end
  return mapping[idx]
end

------------------------------------------------------------
-- Commands
------------------------------------------------------------
local function cmd_init()
  local cwd = U.get_cwd()
  local st = U.compute(cwd)
  if st.is_repo then
    U.notify("Already a git repo: " .. (st.branch or "?"))
    return
  end
  local _, err = U.run(cwd, { "init" })
  if err then U.notify("git init failed: " .. err, "error"); return end
  U.notify("Initialized git repo in " .. cwd)
  U.refresh()
end

local function cmd_branch_switch()
  local cwd, st = require_repo(); if not cwd then return end
  local target = pick_branch(cwd, st, "local", "switch")
  if not target or target == st.branch then return end
  local _, ce = U.run(cwd, { "checkout", target })
  if ce then U.notify("checkout failed: " .. ce, "error"); return end
  U.notify("Switched to " .. target)
  U.refresh()
end

local function cmd_branch_create()
  local cwd, st = require_repo(); if not cwd then return end
  local name, evt = U.input_fn {
    title = "New branch name (created from `" .. (st.branch or "?") .. "`):",
    value = "",
    pos = { "center", w = 60 },
  }
  if evt ~= 1 or not name or U.trim(name) == "" then return end
  local _, ce = U.run(cwd, { "checkout", "-b", U.trim(name) })
  if ce then U.notify("create failed: " .. ce, "error"); return end
  U.notify("Created and switched to " .. U.trim(name))
  U.refresh()
end

local function cmd_branch_delete(force)
  local cwd, st = require_repo(); if not cwd then return end
  local target = pick_branch(cwd, st, "local",
    force and "DELETE -D" or "delete -d")
  if not target then return end
  if target == st.branch then
    U.notify("cannot delete current branch", "warn"); return
  end
  local _, ce = U.run(cwd, { "branch", force and "-D" or "-d", target })
  if ce then U.notify("delete failed: " .. ce, "error"); return end
  U.notify((force and "Force-deleted " or "Deleted ") .. target)
  U.refresh()
end

local function cmd_branch_delete_remote()
  local cwd, st = require_repo(); if not cwd then return end
  local target = pick_branch(cwd, st, "remote", "delete remote")
  if not target then return end
  local remote, branch = target:match("^([^/]+)/(.+)$")
  if not remote or not branch then
    U.notify("can't parse remote ref: " .. target, "error"); return
  end
  U.emit_shell("cd " .. string.format("%q", cwd)
    .. string.format(" && git push %q --delete %q;", remote, branch)
    .. " echo; echo '[press any key]'; read -n1 _")
  U.refresh()
end

local function cmd_stash_push()
  local cwd, st = require_repo(); if not cwd then return end
  if not st.dirty then U.notify("nothing to stash (clean tree)", "warn"); return end

  local msg, evt = U.input_fn {
    title = "Stash message (empty = WIP):",
    pos = { "center", w = 60 },
  }
  if evt ~= 1 then return end
  msg = U.trim(msg or "")

  local args = { "stash", "push", "-u" }
  if msg ~= "" then args[#args + 1] = "-m"; args[#args + 1] = msg end

  local _, err = U.run(cwd, args)
  if err then U.notify("stash push failed: " .. err, "error"); return end
  U.clear_selection()
  U.notify("stashed" .. (msg ~= "" and (": " .. msg) or ""))
  U.refresh()
end

local function cmd_stash_apply_or_pop(pop)
  local cwd = require_repo(); if not cwd then return end
  local list = U.run(cwd, { "stash", "list" }) or ""
  if list == "" then U.notify("no stashes", "warn"); return end

  local target
  if #U.split_lines(list) == 1 then
    target = "stash@{0}"
  else
    target = pick_stash(cwd, pop and "pop" or "apply")
    if not target then return end
  end

  local ok, output = U.git_capture(cwd, { "stash", pop and "pop" or "apply", target })
  if ok then
    U.notify((pop and "popped " or "applied ") .. target)
  else
    U.show_output((pop and "stash pop" or "stash apply") .. " ✗", output, "error")
  end
  U.refresh()
end

local function cmd_stash_list()
  local cwd = require_repo(); if not cwd then return end
  local list = U.run(cwd, { "stash", "list" }) or ""
  if list == "" then U.notify("no stashes", "warn"); return end
  local pager = os.getenv("PAGER") or "less -R"
  local fmt = U.sh_pct("%C(yellow)%gd%C(reset)  %C(cyan)%cr%C(reset)  %gs")
  U.emit_shell("cd " .. string.format("%q", cwd)
    .. " && git --no-pager stash list --color=always --format='" .. fmt .. "' | " .. pager)
end

local function cmd_stash_show()
  local cwd = require_repo(); if not cwd then return end
  local list = U.run(cwd, { "stash", "list" }) or ""
  if list == "" then U.notify("no stashes", "warn"); return end

  local target
  if #U.split_lines(list) == 1 then
    target = "stash@{0}"
  else
    target = pick_stash(cwd, "show diff")
    if not target then return end
  end
  local pager = os.getenv("PAGER") or "less -R"
  local viewer = (os.execute("command -v delta >/dev/null 2>&1") == 0) and "delta" or pager
  U.emit_shell("cd " .. string.format("%q", cwd)
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
  local idx = U.which_fn { cands = cands }
  if not idx or cands[idx].on ~= "y" then return end
  local _, err = U.run(cwd, { "stash", "drop", target })
  if err then U.notify("drop failed: " .. err, "error"); return end
  U.notify("dropped " .. target)
end

local function cmd_stash_clear()
  local cwd = require_repo(); if not cwd then return end
  local list = U.run(cwd, { "stash", "list" }) or ""
  if list == "" then U.notify("no stashes to clear", "warn"); return end
  local count = #U.split_lines(list)
  local cands = {
    { on = "y", desc = "CLEAR all " .. count .. " stash(es) (irreversible)" },
    { on = "<Left>", desc = "← cancel" },
  }
  local idx = U.which_fn { cands = cands }
  if not idx or cands[idx].on ~= "y" then return end
  local _, err = U.run(cwd, { "stash", "clear" })
  if err then U.notify("clear failed: " .. err, "error"); return end
  U.notify("cleared " .. count .. " stash(es)")
end

local function cmd_stash_branch()
  local cwd = require_repo(); if not cwd then return end
  local target = pick_stash(cwd, "→ new branch")
  if not target then return end
  local name, evt = U.input_fn {
    title = "Branch name from " .. target .. ":",
    pos = { "center", w = 60 },
  }
  if evt ~= 1 or not name or U.trim(name) == "" then return end
  local _, err = U.run(cwd, { "stash", "branch", U.trim(name), target })
  if err then U.notify("stash branch failed: " .. err, "error"); return end
  U.notify("created branch `" .. U.trim(name) .. "` from " .. target)
  U.refresh()
end

local function cmd_history()
  local cwd = require_repo(); if not cwd then return end
  local pager = os.getenv("PAGER") or "less -R"
  local fmt = U.sh_pct("%C(auto)%h%d %C(white)%s %C(dim)(%an, %ar)")
  U.emit_shell("cd " .. string.format("%q", cwd)
    .. " && git log --graph --decorate --all --color=always"
    .. " --pretty=format:'" .. fmt .. "' | " .. pager)
end

local function cmd_log10()
  local cwd = require_repo(); if not cwd then return end
  local pager = os.getenv("PAGER") or "less -R"
  local fmt = U.sh_pct("%C(yellow)%h%C(reset) | %C(cyan)%an%C(reset) | "
    .. "%C(green)%ad%C(reset) | %s")
  local date = U.sh_pct("%d.%m.%y %H:%M")
  U.emit_shell("cd " .. string.format("%q", cwd)
    .. " && git log -10 --color=always"
    .. " --pretty=format:'" .. fmt .. "'"
    .. " --date=format:'" .. date .. "' | " .. pager)
end

local function cmd_status()
  local cwd = require_repo(); if not cwd then return end
  local out, err = U.run(cwd, { "status", "--short", "--branch" })
  if err then U.notify("status failed: " .. err, "error"); return end
  if out == "" then U.notify("clean working tree"); return end
  ya.notify({ title = "git status", content = out, timeout = 6.0, level = "info" })
end

local function cmd_commit()
  local cwd, st = require_repo(); if not cwd then return end
  if not st.dirty then U.notify("nothing to commit", "warn"); return end

  local msg, evt = U.input_fn {
    title = "Commit ALL (add -A) — message:",
    pos = { "center", w = 60 },
  }
  if evt ~= 1 or not msg or U.trim(msg) == "" then return end

  local _, ae = U.run(cwd, { "add", "-A" })
  if ae then U.notify("add failed: " .. ae, "error"); return end
  local out, ce = U.run(cwd, { "commit", "-m", msg })
  if ce then U.notify("commit failed: " .. ce, "error"); return end
  U.notify("Committed: " .. (out and out:match("[^\n]+") or msg))
  U.refresh()
end

local function cmd_commit_selected()
  local cwd, st = require_repo(); if not cwd then return end
  if not st.dirty then U.notify("nothing to commit", "warn"); return end

  local files = U.get_selected()
  if #files == 0 then U.notify("no files selected/hovered", "warn"); return end

  local msg, evt = U.input_fn {
    title = string.format("Commit %d file(s) — message:", #files),
    pos = { "center", w = 60 },
  }
  if evt ~= 1 or not msg or U.trim(msg) == "" then return end

  local add_args = { "add", "--" }
  for _, p in ipairs(files) do add_args[#add_args + 1] = p end
  local _, ae = U.run(cwd, add_args)
  if ae then U.notify("add failed: " .. ae, "error"); return end

  local out, ce = U.run(cwd, { "commit", "-m", msg })
  if ce then U.notify("commit failed: " .. ce, "error"); return end
  U.clear_selection()
  U.notify(string.format("Committed %d file(s): %s",
    #files, out and out:match("[^\n]+") or msg))
  U.refresh()
end

local function cmd_push()
  local cwd, st = require_repo(); if not cwd then return end

  local up = U.run(cwd, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" })
  local push_args
  if not up or up == "" then
    local remote = U.ensure_remote(cwd); if not remote then return end

    local ref, evt = U.input_fn {
      title = "First push — `" .. (st.branch or "?") .. "` → (remote/branch):",
      value = remote .. "/" .. (st.branch or ""),
      pos = { "center", w = 60 },
    }
    if evt ~= 1 or not ref or U.trim(ref) == "" then return end
    local r, b = U.trim(ref):match("^([^/]+)/(.+)$")
    if not r or not b then
      U.notify("expected `remote/branch`, got: " .. ref, "error"); return
    end
    push_args = { "push", "--set-upstream", r, (st.branch or "HEAD") .. ":" .. b }
  else
    push_args = { "push" }
  end

  local ok, output = U.git_capture(cwd, push_args)
  U.refresh()

  if ok then
    U.show_output("git push ✓", output, "info")
    return
  end

  local lower = output:lower()
  if lower:find("rejected") or lower:find("non%-fast%-forward") or lower:find("fetch first") then
    U.show_output("push rejected", output, "warn")
    local cands = {
      { on = "p", desc = "pull --rebase then push (safe)" },
      { on = "f", desc = "force push (--force-with-lease)" },
      { on = "<Left>", desc = "← cancel" },
    }
    local idx = U.which_fn { cands = cands }
    if not idx then return end
    local key = cands[idx].on
    if key == "p" then
      local ok2, out2 = U.git_capture(cwd, { "pull", "--rebase" })
      if not ok2 then U.show_output("pull --rebase failed", out2, "error"); U.refresh(); return end
      U.show_output("rebased ✓ → retrying push", out2, "info")
      local ok3, out3 = U.git_capture(cwd, { "push" })
      U.show_output(ok3 and "git push ✓" or "git push ✗", out3, ok3 and "info" or "error")
      U.refresh()
    elseif key == "f" then
      local ok2, out2 = U.git_capture(cwd, { "push", "--force-with-lease" })
      U.show_output(ok2 and "force-push ✓" or "force-push ✗", out2, ok2 and "info" or "error")
      U.refresh()
    end
    return
  end

  U.show_output("git push ✗", output, "error")
end

local function cmd_pull()
  local cwd, st = require_repo(); if not cwd then return end

  local up = U.run(cwd, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" })
  if not up or up == "" then
    local remote = U.ensure_remote(cwd); if not remote then return end
    local default_ref = remote .. "/" .. (st.branch or "")
    local val, evt = U.input_fn {
      title = "Set upstream for `" .. (st.branch or "?") .. "` (remote/branch):",
      value = default_ref,
      pos = { "center", w = 60 },
    }
    if evt ~= 1 or not val or U.trim(val) == "" then return end
    local _, se = U.run(cwd, { "branch", "--set-upstream-to=" .. U.trim(val) })
    if se then U.notify("set-upstream failed: " .. se, "error"); return end
    U.notify("upstream set: " .. U.trim(val))
  end

  local ok, output = U.git_capture(cwd, { "pull" })
  U.refresh()

  if ok then
    U.show_output("git pull ✓", output, "info")
    return
  end

  local conflicts = {}
  local porcelain = U.run(cwd, { "diff", "--name-only", "--diff-filter=U" })
  if porcelain and porcelain ~= "" then
    for _, p in ipairs(U.split_lines(porcelain)) do conflicts[#conflicts + 1] = p end
  end

  if #conflicts > 0 then
    local body = output .. "\n\nConflicted files:\n  " .. table.concat(conflicts, "\n  ")
      .. "\n\nResolve, then commit. Or run `git merge --abort` to bail out."
    U.show_output("pull → MERGE CONFLICT", body, "error")

    local cands = {
      { on = "a", desc = "git merge --abort (roll back pull)" },
      { on = "<Left>", desc = "← keep conflicts to resolve manually" },
    }
    local idx = U.which_fn { cands = cands }
    if idx and cands[idx].on == "a" then
      local ok2, out2 = U.git_capture(cwd, { "merge", "--abort" })
      U.show_output(ok2 and "merge --abort ✓" or "merge --abort ✗",
        out2, ok2 and "info" or "error")
      U.refresh()
    end
    return
  end

  U.show_output("git pull ✗", output, "error")
end

local function cmd_amend()
  local cwd = require_repo(); if not cwd then return end
  local last, lerr = U.run(cwd, { "log", "-1", "--pretty=%B" })
  if lerr then U.notify("no commits to amend: " .. lerr, "error"); return end

  local msg, evt = U.input_fn {
    title = "Amend last commit message:",
    value = last or "",
    pos = { "center", w = 70 },
  }
  if evt ~= 1 or not msg or U.trim(msg) == "" then return end

  local _, ae = U.run(cwd, { "add", "-A" })
  if ae then U.notify("add failed: " .. ae, "error"); return end

  local _, ce = U.run(cwd, { "commit", "--amend", "-m", msg })
  if ce then U.notify("amend failed: " .. ce, "error"); return end
  U.notify("Amended: " .. (msg:match("[^\n]+") or msg))
  U.refresh()
end

local function cmd_fetch()
  local cwd = require_repo(); if not cwd then return end
  local _, err = U.run(cwd, { "fetch", "--all", "--prune" })
  if err then U.notify("fetch failed: " .. err, "error"); return end
  U.refresh()
  local st = U.get_state()
  U.notify(string.format("fetched: %s ↑%d ↓%d",
    st.branch or "?", st.ahead or 0, st.behind or 0))
end

local function cmd_diff()
  local cwd = require_repo(); if not cwd then return end
  local path = U.get_hovered()
  if not path then U.notify("no file under cursor", "warn"); return end
  local viewer = (os.execute("command -v delta >/dev/null 2>&1") == 0)
    and "delta" or (os.getenv("PAGER") or "less -R")
  U.emit_shell(string.format(
    "cd %q && git diff --color=always -- %q | %s", cwd, path, viewer))
end

------------------------------------------------------------
-- Menus (top-level + submenus)
------------------------------------------------------------
local cmd_menu  -- forward decl for submenus' back-arrow

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
  local idx = U.which_fn { cands = cands }
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
  local idx = U.which_fn { cands = cands }
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
  local idx = U.which_fn { cands = cands }
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

cmd_menu = function()
  local cwd = U.get_cwd()
  local st = U.compute(cwd)
  U.set_state(st)

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

  local idx = U.which_fn { cands = cands }
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
  elseif key == "r" then U.refresh()
  end
end

------------------------------------------------------------
-- Entry (async — coroutine; required for Command:output)
------------------------------------------------------------
function M:entry(job)
  local sub = job and job.args and job.args[1]
  U.dbg("entry:", sub or "<nil>")

  -- no args = invoked by ps.sub("cd") emit; refresh silently
  if not sub or sub == "" then
    U.refresh()
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
    elseif sub == "refresh"  then U.refresh()
    else U.notify("unknown subcommand: " .. tostring(sub), "warn") end
  end)
  if not ok then
    U.dbg("entry error:", err)
    U.notify("error: " .. tostring(err), "error")
  end
end

return M
