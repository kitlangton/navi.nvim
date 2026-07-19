if vim.g.loaded_navi then
  return
end
vim.g.loaded_navi = true

vim.api.nvim_create_user_command("NaviLoad", function(options)
  require("navi").load_file(options.args)
end, { nargs = 1, complete = "file", desc = "Load a Navi tour from a JSON file" })

vim.api.nvim_create_user_command("NaviNext", function()
  require("navi").next()
end, { desc = "Go to the next Navi stop" })

vim.api.nvim_create_user_command("NaviPrev", function()
  require("navi").prev()
end, { desc = "Go to the previous Navi stop" })

vim.api.nvim_create_user_command("NaviPick", function()
  require("navi").pick()
end, { desc = "Pick a Navi stop" })

vim.api.nvim_create_user_command("NaviClear", function()
  require("navi").clear()
end, { desc = "End the active Navi tour" })
