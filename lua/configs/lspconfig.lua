require("nvchad.configs.lspconfig").defaults()

-- Enable clangd with navic
vim.lsp.config("clangd", {
  cmd = { "clangd" },
  filetypes = { "c", "cpp", "objc", "objcpp" },
  on_attach = function(client, bufnr)
    if client.server_capabilities.documentSymbolProvider then
      require("nvim-navic").attach(client, bufnr)
    end
  end,
})

local servers = { "clangd" }
vim.lsp.enable(servers)

-- Enable winbar to show navic
vim.o.winbar = "%{%v:lua.require'nvim-navic'.get_location()%}"
