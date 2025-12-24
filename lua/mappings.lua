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

