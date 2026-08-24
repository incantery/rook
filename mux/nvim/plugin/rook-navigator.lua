-- rook ↔ nvim seamless navigation (the vim-tmux-navigator of rook).
--
-- Ctrl-h/j/k/l moves between nvim windows; when a move hits the edge of
-- nvim, the plugin hands it to rook with `rook nav <dir>` and rook moves
-- pane focus instead. The rook side already knows to forward these keys
-- to nvim (it checks the pane's foreground process), so the two halves
-- meet in the middle.
--
-- Loads only inside a rook pane (ROOK_MUX_PANE is set by the server).

if vim.g.loaded_rook_navigator then
  return
end
if not vim.env.ROOK_MUX_PANE then
  return
end
vim.g.loaded_rook_navigator = 1

local function navigate(dir)
  local before = vim.api.nvim_get_current_win()
  vim.cmd.wincmd(dir)
  if vim.api.nvim_get_current_win() == before then
    -- at nvim's edge: rook takes it from here
    vim.system({ "rook", "nav", dir }, { detach = true })
  end
end

for _, dir in ipairs({ "h", "j", "k", "l" }) do
  vim.keymap.set({ "n", "t" }, "<C-" .. dir .. ">", function()
    navigate(dir)
  end, { silent = true, desc = "rook: navigate " .. dir })
end
