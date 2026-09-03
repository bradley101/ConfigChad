-- navigation_panes/init.lua
-- Two-pane shifting history viewport.
--   RIGHT pane = current jumplist position (the window you actually work in)
--   LEFT  pane = the location one step older (exactly where <C-o> would take you)
--
-- The left pane is derived, never authoritative: it is always recomputed from
-- getjumplist() of the right window, so it stays correct no matter how the
-- right window moved (LSP jump, <C-o>, <C-i>, tags, search).

local M = {}

local state = {
  left = nil,
  right = nil,
  scratch = nil,
  last = nil, -- { bufnr, lnum } currently shown in the left pane
}

local CTRL_O = vim.api.nvim_replace_termcodes("<C-o>", true, false, true)
local CTRL_I = vim.api.nvim_replace_termcodes("<C-i>", true, false, true)

local function win_ok(w)
  return w ~= nil and vim.api.nvim_win_is_valid(w)
end

local function is_float(w)
  return vim.api.nvim_win_get_config(w).relative ~= ""
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
function M.ensure_layout(opts)
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
  return state.left, state.right
end

--- Recompute the left pane from the right window's jumplist.
function M.sync_left()
  if not (win_ok(state.left) and win_ok(state.right)) then
    return
  end

  local list, curidx = jumplist_of(state.right)
  local entry = newest_showable(list, curidx)

  if not entry then
    if state.last ~= nil then
      vim.api.nvim_win_set_buf(state.left, scratch_buf())
      vim.wo[state.left].winbar = "%#Comment#  (previous) "
      state.last = nil
    end
    return
  end

  if state.last and state.last.bufnr == entry.bufnr and state.last.lnum == entry.lnum then
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

--- Open a location in the right pane, pushing the position we leave onto that
--- window's jumplist (that is what `m'` does), then reflow the left pane.
function M.open_in_right(filename, lnum, col)
  M.ensure_layout()
  if not win_ok(state.right) then
    return
  end

  local buf = vim.fn.bufadd(filename)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true

  vim.api.nvim_win_call(state.right, function()
    vim.cmd("normal! m'")
  end)

  vim.api.nvim_win_set_buf(state.right, buf)
  pcall(vim.api.nvim_win_set_cursor, state.right, { lnum or 1, math.max((col or 1) - 1, 0) })
  vim.api.nvim_win_call(state.right, function()
    vim.cmd("normal! zz")
  end)

  M.sync_left()
end

--- <Space>1
function M.goto_definition()
  M.ensure_layout({ adopt = true })
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

local function step(keys)
  M.ensure_layout()
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
  M.sync_left()
end

--- True when a <C-o> in the right pane would leave the left pane with nothing
--- older to show -- i.e. the left pane is already displaying the oldest entry
--- in the jumplist.
local function at_oldest()
  local list, curidx = jumplist_of(state.right)
  return newest_showable(list, curidx - 1) == nil
end

--- <C-o>
---
--- At the oldest edge of the jumplist, stepping would slide the right pane onto
--- the location the left pane already shows and blank the left one ("no older
--- location"). That loses the two-pane view for no gain, so instead just hand the
--- cursor to the left pane: the location you were heading for is already there.
function M.back()
  M.ensure_layout()
  if not win_ok(state.right) then
    return
  end

  if win_ok(state.left) and state.last and at_oldest() then
    vim.api.nvim_set_current_win(state.left)
    return
  end

  step(CTRL_O)
end

--- <C-S-o>
function M.forward()
  step(CTRL_I)
end

--- Tear the layout down, keep the right pane.
function M.close()
  drop_left()
  if win_ok(state.right) then
    vim.api.nvim_set_current_win(state.right)
  end
end

function M.setup(opts)
  opts = vim.tbl_extend("force", {
    keys = true,
    auto_sync = true, -- keep the left pane honest after non-mapped jumps (gd, :tag, /)
  }, opts or {})

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
      end
    end,
  })

  if opts.auto_sync then
    vim.api.nvim_create_autocmd({ "CursorHold", "BufWinEnter" }, {
      group = grp,
      callback = function()
        if win_ok(state.left) and win_ok(state.right)
          and vim.api.nvim_get_current_win() == state.right then
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

  vim.api.nvim_create_user_command("NavPanesClose", M.close, {})
  vim.api.nvim_create_user_command("NavPanesSync", M.sync_left, {})

  return M
end

return M
