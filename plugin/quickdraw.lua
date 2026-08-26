if vim.g.loaded_quickdraw then
  return
end

vim.api.nvim_create_user_command("Quickdraw", function()
  require("quickdraw")._command()
end, {
  nargs = 0,
  desc = "Create or edit a Quickdraw drawing",
})

vim.g.loaded_quickdraw = 1
