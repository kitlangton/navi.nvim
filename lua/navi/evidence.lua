local M = {}

M.ns = vim.api.nvim_create_namespace("navi-evidence")

local nio
local files
local client
local next_request = 0
local requests = {}

local function buffer_alive(buffer)
  return vim.api.nvim_buf_is_valid(buffer) and vim.api.nvim_buf_is_loaded(buffer)
end

local function clean_output(output)
  return output:gsub("\27%[[0-?]*[ -/]*[@-~]", ""):gsub("\r", "")
end

local function console_lines(output)
  local lines = {}
  local collecting = false

  for _, line in ipairs(vim.split(clean_output(output), "\n", { plain = true })) do
    if line:match("^std[%w]+%s*|") then
      collecting = true
    elseif collecting and line == "" then
      collecting = false
    elseif collecting then
      table.insert(lines, line)
    end
  end

  return lines
end

local function render(buffer, row, status, name, details)
  if not buffer_alive(buffer) then
    return
  end

  local icons = { running = "◌", passed = "✓", failed = "✗", skipped = "○" }
  local highlights = {
    running = "DiagnosticInfo",
    passed = "DiagnosticOk",
    failed = "DiagnosticError",
    skipped = "DiagnosticWarn",
  }
  local virtual_lines = {
    { { "  " .. icons[status] .. " ", highlights[status] }, { name, "Normal" } },
  }

  for _, line in ipairs(details or {}) do
    table.insert(virtual_lines, {
      { "    │ " .. line, "DiagnosticVirtualTextInfo" },
    })
  end

  vim.api.nvim_buf_clear_namespace(buffer, M.ns, 0, -1)
  return vim.api.nvim_buf_set_extmark(buffer, M.ns, row, 0, {
    virt_lines = virtual_lines,
    virt_lines_above = false,
  })
end

local function tracked_row(buffer, mark, fallback)
  local position = mark and vim.api.nvim_buf_get_extmark_by_id(buffer, M.ns, mark, {}) or {}
  return position[1] or fallback
end

local function clear(buffer)
  if buffer_alive(buffer) then
    vim.api.nvim_buf_clear_namespace(buffer, M.ns, 0, -1)
  end
end

local function initialize(consumer_client)
  client = consumer_client
  nio = require("nio")
  files = require("neotest.lib").files

  local group = vim.api.nvim_create_augroup("navi-evidence", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(event)
      clear(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufUnload" }, {
    group = group,
    callback = function(event)
      requests[event.buf] = nil
    end,
  })

  vim.api.nvim_create_user_command("NaviTest", M.run, {
    desc = "Run the nearest test and render its output inline",
    force = true,
  })

  return M
end

function M.run()
  local buffer = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buffer)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local changedtick = vim.api.nvim_buf_get_changedtick(buffer)

  if vim.bo[buffer].modified then
    vim.notify("Save the buffer before collecting test evidence", vim.log.levels.WARN)
    return
  end

  next_request = next_request + 1
  local request = next_request
  requests[buffer] = request

  nio.run(function()
    local tree, adapter = client:get_nearest(path, row, {})
    if not tree then
      nio.scheduler()
      vim.notify("No test found", vim.log.levels.WARN)
      return
    end
    if requests[buffer] ~= request or not buffer_alive(buffer) then
      return
    end

    local position = tree:data()
    local end_row = math.min(position.range[3], vim.api.nvim_buf_line_count(buffer) - 1)
    nio.scheduler()
    if requests[buffer] ~= request or not buffer_alive(buffer) then
      return
    end
    local mark = render(buffer, end_row, "running", position.name)

    client:run_tree(tree, { adapter = adapter })
    if requests[buffer] ~= request or not buffer_alive(buffer) then
      return
    end
    local result = client:get_results(adapter)[position.id]
    local details = result.output and console_lines(files.read(result.output)) or {}
    if result.status == "failed" then
      for _, err in ipairs(result.errors or {}) do
        for _, line in ipairs(vim.split(clean_output(vim.trim(err.message)), "\n", { plain = true })) do
          table.insert(details, line)
        end
      end
    end

    nio.scheduler()
    if requests[buffer] ~= request or not buffer_alive(buffer) then
      return
    end
    if vim.api.nvim_buf_get_changedtick(buffer) ~= changedtick then
      clear(buffer)
      return
    end
    local result_row = tracked_row(buffer, mark, end_row)
    render(buffer, result_row, result.status, position.name, details)
  end)
end

return setmetatable(M, {
  __call = function(_, ...)
    return initialize(...)
  end,
})
