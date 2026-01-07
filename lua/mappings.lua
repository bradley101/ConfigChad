require "nvchad.mappings"

-- add yours here

local map = vim.keymap.set

map("n", ";", ":", { desc = "CMD enter command mode" })
map("i", "jk", "<ESC>")

-- map({ "n", "i", "v" }, "<C-s>", "<cmd> w <cr>")
--
-- my mappings from here --


map("n", "<leader>vv", "<C-w>v", { desc = "Vertical split same buffer" })
map("n", "<leader>ww", "<cmd>wa<CR>", { desc = "Save all buffers" })

map("n", "<leader>fr", function()
  require("telescope.builtin").resume()
end, { desc = "Resume last Telescope picker" })
map("n", "gr", vim.lsp.buf.references, {})
map("n", "<leader>gr", "<cmd>Telescope lsp_references<CR>",
  { desc = "LSP References (Telescope)" })
map("n", "<leader>tn", "<cmd>tabNext<CR>", { desc = "Go to Next Tab" })
map("n", "<leader>tp", "<cmd>tabPrevious<CR>", { desc = "Go to Previous Tab" })
