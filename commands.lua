-- git-screen: git operations. Plain module — imports util itself.

local U = require("git-screen.util")
local C = {}

----------------------------------------------------------
-- Local helpers (used by commands only)
----------------------------------------------------------
local function require_repo()
  local cwd = U.get_cwd()
  local st = U.compute(cwd)
  U.set_state(st)
  if not st.is_repo then return nil end
  return cwd, st
end
C.require_repo = require_repo

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

----------------------------------------------------------
-- Init / repo lifecycle
----------------------------------------------------------
function C.init()
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

----------------------------------------------------------
-- Branches
----------------------------------------------------------
function C.branch_switch()
  local cwd, st = require_repo(); if not cwd then return end
  local target = pick_branch(cwd, st, "local", "switch")
  if not target or target == st.branch then return end
  local _, ce = U.run(cwd, { "checkout", target })
  if ce then U.notify("checkout failed: " .. ce, "error"); return end
  U.notify("Switched to " .. target)
  U.refresh()
end

function C.branch_create()
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

function C.branch_delete(force)
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

function C.branch_delete_remote()
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

----------------------------------------------------------
-- Stash
----------------------------------------------------------
function C.stash_push()
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

function C.stash_apply_or_pop(pop)
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

function C.stash_list()
  local cwd = require_repo(); if not cwd then return end
  local list = U.run(cwd, { "stash", "list" }) or ""
  if list == "" then U.notify("no stashes", "warn"); return end
  local pager = os.getenv("PAGER") or "less -R"
  local fmt = U.sh_pct("%C(yellow)%gd%C(reset)  %C(cyan)%cr%C(reset)  %gs")
  U.emit_shell("cd " .. string.format("%q", cwd)
    .. " && git --no-pager stash list --color=always --format='" .. fmt .. "' | " .. pager)
end

function C.stash_show()
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

function C.stash_drop()
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

function C.stash_clear()
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

function C.stash_branch()
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

----------------------------------------------------------
-- Commits / history / status / diff
----------------------------------------------------------
function C.history()
  local cwd = require_repo(); if not cwd then return end
  local pager = os.getenv("PAGER") or "less -R"
  local fmt = U.sh_pct("%C(auto)%h%d %C(white)%s %C(dim)(%an, %ar)")
  U.emit_shell("cd " .. string.format("%q", cwd)
    .. " && git log --graph --decorate --all --color=always"
    .. " --pretty=format:'" .. fmt .. "' | " .. pager)
end

function C.log10()
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

function C.status()
  local cwd = require_repo(); if not cwd then return end
  local out, err = U.run(cwd, { "status", "--short", "--branch" })
  if err then U.notify("status failed: " .. err, "error"); return end
  if out == "" then U.notify("clean working tree"); return end
  ya.notify({ title = "git status", content = out, timeout = 6.0, level = "info" })
end

function C.commit_all()
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

function C.commit_selected()
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

function C.amend()
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

function C.diff()
  local cwd = require_repo(); if not cwd then return end
  local path = U.get_hovered()
  if not path then U.notify("no file under cursor", "warn"); return end
  local viewer = (os.execute("command -v delta >/dev/null 2>&1") == 0)
    and "delta" or (os.getenv("PAGER") or "less -R")
  U.emit_shell(string.format(
    "cd %q && git diff --color=always -- %q | %s", cwd, path, viewer))
end

----------------------------------------------------------
-- Sync (fetch / push / pull)
----------------------------------------------------------
function C.fetch()
  local cwd = require_repo(); if not cwd then return end
  local _, err = U.run(cwd, { "fetch", "--all", "--prune" })
  if err then U.notify("fetch failed: " .. err, "error"); return end
  U.refresh()
  local st = U.get_state()
  U.notify(string.format("fetched: %s ↑%d ↓%d",
    st.branch or "?", st.ahead or 0, st.behind or 0))
end

function C.push()
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

function C.pull()
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

return C
