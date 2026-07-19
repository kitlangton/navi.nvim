local M = {}

M.ns = vim.api.nvim_create_namespace("navi-evidence")

local nio
local files
local client
local evidence = {}
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

  local icons = { running = "◌", passed = "✓", failed = "✗", skipped = "○", stale = "○" }
  local highlights = {
    running = "DiagnosticInfo",
    passed = "DiagnosticOk",
    failed = "DiagnosticError",
    skipped = "DiagnosticWarn",
    stale = "Comment",
  }
  local virtual_lines = {
    { { "  " .. icons[status] .. " ", highlights[status] }, { name, status == "stale" and "Comment" or "Normal" } },
  }

  for _, line in ipairs(details or {}) do
    table.insert(virtual_lines, {
      { "    │ " .. line, status == "stale" and "Comment" or "DiagnosticVirtualTextInfo" },
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

local function remember(buffer, row, details, changedtick, mark, stale)
  evidence[buffer] = {
    changedtick = changedtick or vim.api.nvim_buf_get_changedtick(buffer),
    details = details,
    mark = mark,
    row = row,
    stale = stale or false,
  }
end

local function mark_stale(buffer)
  local state = evidence[buffer]
  if not state or state.stale or not buffer_alive(buffer) then
    return
  end
  if vim.api.nvim_buf_get_changedtick(buffer) == state.changedtick then
    return
  end

  state.row = tracked_row(buffer, state.mark, state.row)
  state.stale = true
  state.mark = render(buffer, state.row, "stale", "stale test evidence", state.details)
end

local function initialize(consumer_client)
  client = consumer_client
  nio = require("nio")
  files = require("neotest.lib").files

  local group = vim.api.nvim_create_augroup("navi-evidence", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(event)
      mark_stale(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufUnload" }, {
    group = group,
    callback = function(event)
      evidence[event.buf] = nil
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
    evidence[buffer] = nil
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
    local result_row = tracked_row(buffer, mark, end_row)
    local stale = vim.api.nvim_buf_get_changedtick(buffer) ~= changedtick
    local status = stale and "stale" or result.status
    local name = stale and "stale test evidence" or position.name
    local result_mark = render(buffer, result_row, status, name, details)
    remember(buffer, result_row, details, changedtick, result_mark, stale)
  end)
end

return setmetatable(M, {
  __call = function(_, ...)
    return initialize(...)
  end,
})
