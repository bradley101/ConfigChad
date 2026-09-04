-- navigation_panes/init.lua
-- Two-pane shifting history viewport.
--   RIGHT pane = current jumplist position (the window you actually work in)
--   LEFT  pane = the location one step older (exactly where <C-o> would take you)
--
-- The left pane is derived, never authoritative: it is always recomputed from
-- getjumplist() of the right window, so it stays correct no matter how the
-- right window moved (LSP jump, <C-o>, <C-i>, tags, search).
--
-- Neither pane is a workspace you can repoint. Whatever buffer arrives in the
-- left pane by other means (`:edit` there, a telescope pick, a jump taken inside
-- it) is what you are working on now, so it gets moved into the right pane and
-- the left pane falls back to one step older. A buffer swapped into the right
-- pane is simply the new current location and the left pane reflows behind it.
--
-- :NavPanesToggle (or :NavPanesEnable / :NavPanesDisable) switches the whole
-- thing off: the left pane is torn down and the mappings hand <C-o>, <C-S-o>
-- and <Space>1 straight back to Neovim, counts and all.

local M = {}

local state = {
  left = nil,
  right = nil,
  scratch = nil,
  last = nil, -- { bufnr, lnum } currently shown in the left pane
  right_buf = nil, -- buffer we last put in / observed in the right pane
  busy = false, -- true while we are the ones moving buffers around
  enabled = true,
}

local CTRL_O = vim.api.nvim_replace_termcodes("<C-o>", true, false, true)
local CTRL_I = vim.api.nvim_replace_termcodes("<C-i>", true, false, true)

local function win_ok(w)
  return w ~= nil and vim.api.nvim_win_is_valid(w)
end

local function is_float(w)
  return vim.api.nvim_win_get_config(w).relative ~= ""
end

--- Run fn with the layout marked as ours, so the autocmds below ignore the
--- window shuffling we do ourselves and only react to the user's.
local function with_busy(fn, ...)
  if state.busy then
    return fn(...)
  end
  state.busy = true
  local ok, res = pcall(fn, ...)
  state.busy = false
  if not ok then
    error(res, 0)
  end
  return res
end

local function scratch_buf()
  if state.scratch and vim.api.nvim_buf_is_valid(state.scratch) then
    return state.scratch
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "", "   no older location" })
  vim.bo[b].modifiable = false
  vim.bo[b].bufhidden = "hide"
  state.scratch = b
  return b
end

local function style_left()
  local w = state.left
  vim.wo[w].winfixwidth = true
  vim.wo[w].number = true
  vim.wo[w].relativenumber = false
  vim.wo[w].cursorline = true
  vim.wo[w].signcolumn = "no"
  vim.wo[w].winbar = "%#Comment#  (previous) "
end

local function drop_left()
  if win_ok(state.left) then
    pcall(vim.api.nvim_win_close, state.left, true)
  end
  state.left = nil
  state.last = nil
end

--- getjumplist() of a window as (list, curidx).
---
--- curidx is a 0-based index into the Vimscript list, so in Lua the entry <C-o>
--- would jump to is list[curidx] -- by definition "one step older" than wherever
--- the window is sitting, whether or not the user is mid-history.
local function jumplist_of(win)
  local jl = vim.api.nvim_win_call(win, function()
    return vim.fn.getjumplist()
  end)
  return jl[1], jl[2]
end

--- Newest jumplist entry at or below `from` (Lua index) that still points at a
--- real, named buffer. Returns nil when there is nothing older left to show.
local function newest_showable(list, from)
  for i = from, 1, -1 do
    local e = list[i]
    if e and vim.api.nvim_buf_is_valid(e.bufnr) and vim.api.nvim_buf_get_name(e.bufnr) ~= "" then
      return e
    end
  end
end

--- Guarantee both panes exist. Leaves the cursor in the RIGHT pane.
--- opts.adopt = true: if the user is currently in some unrelated window,
--- rebuild the layout around that window instead of hijacking the old one.
local function ensure_layout(opts)
  opts = opts or {}
  local cur = vim.api.nvim_get_current_win()

  if opts.adopt and not is_float(cur) and cur ~= state.left and cur ~= state.right then
    drop_left()
    state.right = cur
  end

  if not win_ok(state.right) then
    if win_ok(state.left) and cur == state.left then
      state.right = state.left -- only the left pane survived; promote it
      state.left = nil
    elseif is_float(cur) then
      return nil, nil
    else
      state.right = cur
    end
  end

  if not win_ok(state.left) then
    vim.api.nvim_set_current_win(state.right)
    vim.cmd("aboveleft vsplit")
    state.left = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.left, scratch_buf())
    style_left()
    vim.cmd("wincmd =")
    state.last = nil
  end

  vim.api.nvim_set_current_win(state.right)
  state.right_buf = vim.api.nvim_win_get_buf(state.right)
  return state.left, state.right
end

--- Recompute the left pane from the right window's jumplist.
local function sync_left()
  if not (win_ok(state.left) and win_ok(state.right)) then
    return
  end

  local list, curidx = jumplist_of(state.right)
  local entry = newest_showable(list, curidx)

  if not entry then
    if state.last ~= nil or vim.api.nvim_win_get_buf(state.left) ~= scratch_buf() then
      vim.api.nvim_win_set_buf(state.left, scratch_buf())
      vim.wo[state.left].winbar = "%#Comment#  (previous) "
      state.last = nil
    end
    return
  end

  if state.last and state.last.bufnr == entry.bufnr and state.last.lnum == entry.lnum
    and vim.api.nvim_win_get_buf(state.left) == entry.bufnr then
    return -- already showing it
  end

  if not vim.api.nvim_buf_is_loaded(entry.bufnr) then
    vim.fn.bufload(entry.bufnr)
  end

  vim.api.nvim_win_set_buf(state.left, entry.bufnr)
  local lnum = math.min(math.max(entry.lnum, 1), vim.api.nvim_buf_line_count(entry.bufnr))
  pcall(vim.api.nvim_win_set_cursor, state.left, { lnum, math.max(entry.col or 0, 0) })
  vim.api.nvim_win_call(state.left, function()
    vim.cmd("normal! zz")
  end)

  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(entry.bufnr), ":t")
  vim.wo[state.left].winbar = "%#Comment#  " .. name .. ":" .. lnum .. " "
  state.last = { bufnr = entry.bufnr, lnum = entry.lnum }
end

--- Show a buffer in the right pane, pushing the position we leave onto that
--- window's jumplist (that is what `m'` does), then reflow the left pane.
--- `col` is 0-based, like nvim_win_get_cursor returns it.
local function place_in_right(buf, lnum, col)
  ensure_layout()
  if not win_ok(state.right) then
    return
  end

  vim.api.nvim_win_call(state.right, function()
    vim.cmd("normal! m'")
  end)

  vim.api.nvim_win_set_buf(state.right, buf)
  state.right_buf = buf
  pcall(vim.api.nvim_win_set_cursor, state.right, { lnum or 1, math.max(col or 0, 0) })
  vim.api.nvim_win_call(state.right, function()
    vim.cmd("normal! zz")
  end)

  sync_left()
end

local function open_in_right(filename, lnum, col)
  local buf = vim.fn.bufadd(filename)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  place_in_right(buf, lnum, math.max((col or 1) - 1, 0))
end

--- The left pane is a viewport, not a workspace. When a buffer we did not put
--- there shows up in it, the user went to work in the previous location, so it
--- becomes the current one: hand the buffer to the right pane (which pushes the
--- location it held onto the jumplist) and let the left pane fall back a step.
local function left_is_foreign()
  if not (win_ok(state.left) and win_ok(state.right)) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(state.left)
  if buf == state.scratch or vim.api.nvim_buf_get_name(buf) == "" then
    return false
  end
  return not (state.last and state.last.bufnr == buf)
end

local function reclaim_left()
  if not left_is_foreign() then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(state.left)
  local pos = vim.api.nvim_win_get_cursor(state.left)
  place_in_right(buf, pos[1], pos[2])
  return true
end

local function goto_definition()
  ensure_layout({ adopt = true })
  if not win_ok(state.right) then
    return
  end

  local clients = vim.lsp.get_clients({ bufnr = vim.api.nvim_win_get_buf(state.right) })
  if #clients == 0 then
    vim.notify("navigation_panes: no LSP client attached", vim.log.levels.WARN)
    return
  end

  vim.lsp.buf.definition({
    on_list = function(res)
      local items = res.items or {}
      if #items == 0 then
        vim.notify("navigation_panes: no definition found", vim.log.levels.WARN)
        return
      end
      if #items > 1 then
        vim.fn.setqflist({}, " ", res)
        vim.notify(("navigation_panes: %d definitions, taking the first (:copen for the rest)")
          :format(#items), vim.log.levels.INFO)
      end
      local it = items[1]
      local fname = it.filename or vim.api.nvim_buf_get_name(it.bufnr or 0)
      M.open_in_right(fname, it.lnum, it.col)
    end,
  })
end

--- Hand a key back to Neovim untouched, count included: what the mappings do
--- while the feature is switched off.
local function native_key(keys)
  pcall(vim.cmd, "normal! " .. vim.v.count1 .. keys)
end

local function step(keys)
  ensure_layout()
  if not win_ok(state.right) then
    return
  end
  vim.api.nvim_win_call(state.right, function()
    -- The leading "1" is a count, and it is load-bearing: <C-i> is a literal
    -- tab, so `normal! <Tab>` has the ex parser swallow it as the separator
    -- after the command name and the jump is silently dropped. A count in
    -- front keeps the key in the argument.
    pcall(vim.cmd, "normal! 1" .. keys)
  end)
  state.right_buf = vim.api.nvim_win_get_buf(state.right)
  sync_left()
end

--- True when a <C-o> in the right pane would leave the left pane with nothing
--- older to show -- i.e. the left pane is already displaying the oldest entry
--- in the jumplist.
local function at_oldest()
  local list, curidx = jumplist_of(state.right)
  return newest_showable(list, curidx - 1) == nil
end

--- At the oldest edge of the jumplist, stepping would slide the right pane onto
--- the location the left pane already shows and blank the left one ("no older
--- location"). That loses the two-pane view for no gain, so instead just hand the
--- cursor to the left pane: the location you were heading for is already there.
local function back()
  ensure_layout()
  if not win_ok(state.right) then
    return
  end

  if win_ok(state.left) and state.last and at_oldest() then
    vim.api.nvim_set_current_win(state.left)
    return
  end

  step(CTRL_O)
end

local function close()
  drop_left()
  if win_ok(state.right) then
    vim.api.nvim_set_current_win(state.right)
  end
end

--- Switch the viewport on or off. Off tears the left pane down and forgets the
--- layout, so turning it back on adopts whatever window you are in next.
local function set_enabled(on)
  on = on and true or false
  if state.enabled and not on then
    close()
    state.right = nil
    state.right_buf = nil
  end
  state.enabled = on
end

-- Public API. Everything the user can trigger runs under with_busy so our own
-- buffer moves never look like the user repointing a pane.
function M.ensure_layout(opts)
  return with_busy(ensure_layout, opts)
end

function M.sync_left()
  if not state.enabled then
    return
  end
  return with_busy(sync_left)
end

function M.open_in_right(filename, lnum, col)
  return with_busy(open_in_right, filename, lnum, col)
end

--- <Space>1
function M.goto_definition()
  if not state.enabled then
    return vim.lsp.buf.definition()
  end
  return with_busy(goto_definition)
end

--- <C-o>
function M.back()
  if not state.enabled then
    return native_key(CTRL_O)
  end
  return with_busy(back)
end

--- <C-S-o>
function M.forward()
  if not state.enabled then
    return native_key(CTRL_I)
  end
  return with_busy(step, CTRL_I)
end

--- Pull a foreign buffer out of the left pane and make it the current location.
function M.reclaim_left()
  if not state.enabled then
    return
  end
  return with_busy(reclaim_left)
end

function M.enabled()
  return state.enabled
end

--- :NavPanesEnable / :NavPanesDisable / :NavPanesToggle
function M.set_enabled(on, quiet)
  local was = state.enabled
  with_busy(set_enabled, on)
  if not quiet and was ~= state.enabled then
    vim.notify("navigation_panes: " .. (state.enabled and "enabled" or "disabled"), vim.log.levels.INFO)
  end
  return state.enabled
end

function M.toggle()
  return M.set_enabled(not state.enabled)
end

--- Tear the layout down, keep the right pane.
function M.close()
  return with_busy(close)
end

function M.setup(opts)
  opts = vim.tbl_extend("force", {
    keys = true,
    enabled = true, -- start switched on; :NavPanesToggle flips it at runtime
    auto_sync = true, -- track buffers/jumps the keymaps did not make (gd, :edit, telescope, :tag, /)
  }, opts or {})

  state.enabled = opts.enabled and true or false

  local grp = vim.api.nvim_create_augroup("NavigationPanes", { clear = true })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = grp,
    callback = function(ev)
      local w = tonumber(ev.match)
      if w == state.left then
        state.left = nil
        state.last = nil
      end
      if w == state.right then
        state.right = nil
        state.right_buf = nil
      end
    end,
  })

  if opts.auto_sync then
    vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinEnter", "CursorHold" }, {
      group = grp,
      callback = function()
        if not state.enabled then
          return
        end
        if state.busy or not (win_ok(state.left) and win_ok(state.right)) then
          return
        end

        -- Deferred: this fires from inside the :edit / window switch that put the
        -- buffer there, which is no place to be moving windows around.
        if left_is_foreign() then
          vim.schedule(M.reclaim_left)
          return
        end

        if vim.api.nvim_get_current_win() == state.right
          or vim.api.nvim_win_get_buf(state.right) ~= state.right_buf then
          state.right_buf = vim.api.nvim_win_get_buf(state.right)
          M.sync_left()
        end
      end,
    })
  end

  if opts.keys then
    local map = vim.keymap.set
    map("n", "<Space>1", M.goto_definition, { silent = true, desc = "Definition -> right pane" })
    map("n", "<C-o>", M.back, { silent = true, desc = "History back (both panes)" })
    map("n", "<C-S-o>", M.forward, { silent = true, desc = "History forward (both panes)" })
    map("n", "<Space>2", M.forward, { silent = true, desc = "History forward (fallback)" })
  end

  local cmd = vim.api.nvim_create_user_command
  cmd("NavPanesClose", M.close, { desc = "Close the previous pane, keep the current one" })
  cmd("NavPanesSync", M.sync_left, { desc = "Recompute the previous pane" })
  cmd("NavPanesToggle", function()
    M.toggle()
  end, { desc = "Toggle the two-pane history viewport" })
  cmd("NavPanesEnable", function()
    M.set_enabled(true)
  end, { desc = "Enable the two-pane history viewport" })
  cmd("NavPanesDisable", function()
    M.set_enabled(false)
  end, { desc = "Disable it: <C-o>/<C-S-o>/<Space>1 go back to their native behaviour" })

  return M
end

return M
