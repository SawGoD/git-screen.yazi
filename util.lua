-- git-screen: shared helpers, state, and footer renderer.
-- All Command:output() calls live here; consumers stay in async (coroutine)
-- context. `cx`, `ui.render`, `ya.emit`, `Status` access goes through ya.sync.

local U = {}

------------------------------------------------------------
-- Debug log (file-based, always on; level-independent)
------------------------------------------------------------
local LOG = "/tmp/git-screen.log"
function U.dbg(...)
  local parts = { os.date("%H:%M:%S"), "git-screen:" }
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  local f = io.open(LOG, "a")
  if f then f:write(table.concat(parts, " "), "\n"); f:close() end
end

------------------------------------------------------------
-- yazi 26.x renamed `ya.input` / `ya.which` → `ui.*`. Use whichever exists.
------------------------------------------------------------
U.input_fn = (ui and ui.input) or ya.input
U.which_fn = (ui and ui.which) or ya.which

------------------------------------------------------------
-- State (kept inside a ya.sync upvalue so footer + commands share it)
------------------------------------------------------------
U.set_state = ya.sync(function(st, new)
  st.git = new
  ui.render()
end)

U.get_state = ya.sync(function(st)
  return st.git or {}
end)

U.get_cwd = ya.sync(function()
  return tostring(cx.active.current.cwd)
end)

U.get_hovered = ya.sync(function()
  local h = cx.active.current.hovered
  return h and tostring(h.url) or nil
end)

-- Selected files (multi-select via Space). Falls back to hovered if empty.
U.get_selected = ya.sync(function()
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

U.emit_shell = ya.sync(function(_, cmd)
  ya.emit("shell", { cmd, block = true, confirm = false })
end)

U.clear_selection = ya.sync(function()
  ya.emit("escape", { select = true })
end)

------------------------------------------------------------
-- Small async helpers
------------------------------------------------------------
function U.run(cwd, args)
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

function U.trim(s)
  local r = (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return r
end

function U.split_lines(s)
  local t = {}
  for line in (s or ""):gmatch("[^\r\n]+") do t[#t + 1] = line end
  return t
end

-- yazi substitutes %h/%d/%a/%n/etc in shell commands. Double `%` so yazi
-- emits a literal `%` to the shell where git/date placeholders live.
function U.sh_pct(s) return (s:gsub("%%", "%%%%")) end

-- Capture combined git output. Returns (success, combined_text).
function U.git_capture(cwd, args)
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

------------------------------------------------------------
-- Notifications
------------------------------------------------------------
function U.notify(content, level, title)
  ya.notify({
    title = title or "git-screen",
    content = tostring(content),
    timeout = 3.0,
    level = level or "info",
  })
end

-- Long-lived notification for command output.
function U.show_output(title, body, level)
  ya.notify {
    title = title,
    content = (body == "" and "(empty output)" or body),
    timeout = 20.0,
    level = level or "info",
  }
end

------------------------------------------------------------
-- Compute repo state + refresh footer
------------------------------------------------------------
function U.compute(cwd)
  local s = { cwd = cwd, is_repo = false, branch = nil,
              ahead = 0, behind = 0, dirty = false, conflict = false }

  local top = U.run(cwd, { "rev-parse", "--show-toplevel" })
  if not top or top == "" then
    U.dbg("compute: not a repo", cwd)
    return s
  end
  s.is_repo = true

  local br = U.run(cwd, { "symbolic-ref", "--short", "HEAD" })
  if not br or br == "" then
    br = U.run(cwd, { "rev-parse", "--short", "HEAD" }) or "?"
    s.branch = "(" .. br .. ")"
  else
    s.branch = br
  end

  local lr = U.run(cwd, { "rev-list", "--left-right", "--count", "@{upstream}...HEAD" })
  if lr then
    local b, a = lr:match("(%d+)%s+(%d+)")
    s.behind = tonumber(b) or 0
    s.ahead = tonumber(a) or 0
  end

  local pst = U.run(cwd, { "status", "--porcelain" })
  if pst and pst ~= "" then
    s.dirty = true
    for _, line in ipairs(U.split_lines(pst)) do
      local xy = line:sub(1, 2)
      if xy:find("U") or xy == "AA" or xy == "DD" then
        s.conflict = true
        break
      end
    end
  end
  U.dbg("compute:", s.branch, "ahead", s.ahead, "behind", s.behind, "dirty", s.dirty)
  return s
end

function U.refresh()
  local cwd = U.get_cwd()
  U.set_state(U.compute(cwd))
end

------------------------------------------------------------
-- Footer render (called sync by yazi)
------------------------------------------------------------
function U.render_status()
  local st = U.get_state()
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
-- Path / repo helpers
------------------------------------------------------------

-- Absolute path of the repo root, or nil if cwd is not inside a git repo.
function U.repo_root(cwd)
  local top = U.run(cwd, { "rev-parse", "--show-toplevel" })
  return (top and top ~= "") and top or nil
end

-- Returns abs path relative to root, or nil if abs is outside root.
function U.relpath(abs, root)
  if not abs or not root then return nil end
  abs = abs:gsub("/+$", "")
  root = root:gsub("/+$", "")
  if abs == root then return "" end
  if abs:sub(1, #root + 1) == root .. "/" then
    return abs:sub(#root + 2)
  end
  return nil
end

-- True if path exists and is a directory (yazi fs.cha is sync-safe).
U.path_is_dir = ya.sync(function(_, abs)
  if not abs then return false end
  local ok, cha = pcall(fs.cha, Url(abs))
  if not ok or not cha then return false end
  return cha.is_dir == true
end)

-- True if `git ls-files --error-unmatch <path>` succeeds (path is tracked).
function U.is_tracked(cwd, abs_path)
  local _, err = U.run(cwd, { "ls-files", "--error-unmatch", "--", abs_path })
  return err == nil
end

------------------------------------------------------------
-- ensure_remote: shared by push/pull on first-time setup
------------------------------------------------------------
function U.ensure_remote(cwd)
  local remotes = U.run(cwd, { "remote" }) or ""
  if remotes ~= "" then return (U.split_lines(remotes))[1] end

  local url, uevt = U.input_fn {
    title = "Add remote `origin` URL:",
    value = "",
    pos = { "center", w = 70 },
  }
  if uevt ~= 1 or not url or U.trim(url) == "" then return nil end
  local _, re = U.run(cwd, { "remote", "add", "origin", U.trim(url) })
  if re then U.notify("remote add failed: " .. re, "error"); return nil end
  U.notify("added origin: " .. U.trim(url))
  return "origin"
end

return U
