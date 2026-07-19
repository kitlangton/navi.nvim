local M = {}

M.ns = vim.api.nvim_create_namespace("navi")
M.sign_group = "NaviSigns"
M.stops = {}
M.current = 0

local origin_win
local origin_winbar

local function realpath(path)
  local absolute = vim.fn.fnamemodify(path, ":p")
  return vim.uv.fs_realpath(absolute) or absolute
end

for i = 1, 9 do
  vim.fn.sign_define("NaviStop" .. i, { text = tostring(i), texthl = "DiagnosticHint" })
  vim.fn.sign_define("NaviCurrent" .. i, { text = tostring(i), texthl = "DiagnosticOk" })
end
vim.fn.sign_define("NaviStop10", { text = "*", texthl = "DiagnosticHint" })
vim.fn.sign_define("NaviCurrent10", { text = "*", texthl = "DiagnosticOk" })

local function clear_extmarks()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.ns, 0, -1)
    end
  end
end

local function restore_winbar()
  if origin_win and vim.api.nvim_win_is_valid(origin_win) then
    vim.api.nvim_set_option_value("winbar", origin_winbar or "", { win = origin_win })
  end
  origin_win = nil
  origin_winbar = nil
end

local function update_winbar()
  if not origin_win or not vim.api.nvim_win_is_valid(origin_win) then
    return
  end

  local value = #M.stops <= 1 and "" or string.format(" ▶ %d/%d", M.current, #M.stops)
  vim.api.nvim_set_option_value("winbar", value, { win = origin_win })
end

local function update_signs()
  vim.fn.sign_unplace(M.sign_group)

  for i, stop in ipairs(M.stops) do
    local bufnr = vim.fn.bufnr(stop.file)
    if bufnr ~= -1 then
      local num = #M.stops == 1 and 10 or math.min(i, 10)
      local prefix = i == M.current and "NaviCurrent" or "NaviStop"
      vim.fn.sign_place(i, M.sign_group, prefix .. num, bufnr, { lnum = stop.line, priority = 100 })
    end
  end
end

local function split_token(token, width)
  local parts = {}
  local current = ""

  for index = 0, vim.fn.strchars(token) - 1 do
    local char = vim.fn.strcharpart(token, index, 1)
    if current ~= "" and vim.fn.strdisplaywidth(current .. char) > width then
      table.insert(parts, current)
      current = char
    else
      current = current .. char
    end
  end

  if current ~= "" then
    table.insert(parts, current)
  end
  return parts
end

local function wrap_line(line, width)
  width = math.max(1, width)
  if line == "" then
    return { "" }
  end

  local lines = {}
  local current = ""
  for word in line:gmatch("%S+") do
    if vim.fn.strdisplaywidth(word) > width then
      if current ~= "" then
        table.insert(lines, current)
        current = ""
      end
      local pieces = split_token(word, width)
      for index, piece in ipairs(pieces) do
        if index < #pieces then
          table.insert(lines, piece)
        else
          current = piece
        end
      end
    else
      local candidate = current == "" and word or current .. " " .. word
      if current ~= "" and vim.fn.strdisplaywidth(candidate) > width then
        table.insert(lines, current)
        current = word
      else
        current = candidate
      end
    end
  end
  if current ~= "" then
    table.insert(lines, current)
  end
  return lines
end

local inline_rules = {
  { pattern = "`([^`]+)`", highlight = "@markup.raw" },
  { pattern = "%*%*([^*]+)%*%*", highlight = "@markup.strong" },
  { pattern = "__([^_]+)__", highlight = "@markup.strong" },
  { pattern = "~~([^~]+)~~", highlight = "@markup.strikethrough" },
  { pattern = "%*([^*]+)%*", highlight = "@markup.italic" },
  { pattern = "_([^_]+)_", highlight = "@markup.italic" },
  { pattern = "%[([^%]]+)%]%([^%)]+%)", highlight = "@markup.link.label" },
}

local function render_inline(line, default_highlight)
  local chunks = {}
  local offset = 1

  while offset <= #line do
    local earliest
    for _, rule in ipairs(inline_rules) do
      local start_index, end_index, content = line:find(rule.pattern, offset)
      if start_index and (not earliest or start_index < earliest.start_index) then
        earliest = {
          start_index = start_index,
          end_index = end_index,
          content = content,
          highlight = rule.highlight,
        }
      end
    end

    if not earliest then
      table.insert(chunks, { line:sub(offset), default_highlight })
      break
    end
    if earliest.start_index > offset then
      table.insert(chunks, { line:sub(offset, earliest.start_index - 1), default_highlight })
    end
    table.insert(chunks, { earliest.content, earliest.highlight })
    offset = earliest.end_index + 1
  end

  if #chunks == 0 then
    table.insert(chunks, { "", default_highlight })
  end
  return chunks
end

local function render_markdown_line(line, default_highlight, code_block, width)
  if code_block then
    return { { line, "@markup.raw.block" } }
  end

  local hashes, heading = line:match("^(#+)%s+(.+)$")
  if heading then
    local level = math.min(#hashes, 6)
    return render_inline(heading, "@markup.heading." .. level)
  end

  local quote = line:match("^>%s?(.*)$")
  if quote then
    local chunks = { { "│ ", "@markup.quote" } }
    vim.list_extend(chunks, render_inline(quote, default_highlight))
    return chunks
  end

  local indent, item = line:match("^(%s*)[-+*]%s+(.+)$")
  if item then
    local chunks = { { indent .. "• ", "@markup.list" } }
    vim.list_extend(chunks, render_inline(item, default_highlight))
    return chunks
  end

  local number, numbered_item = line:match("^%s*(%d+)[.)]%s+(.+)$")
  if numbered_item then
    local chunks = { { number .. ". ", "@markup.list" } }
    vim.list_extend(chunks, render_inline(numbered_item, default_highlight))
    return chunks
  end

  if line:match("^%s*[-*_][-*_][-*_]+%s*$") then
    return { { string.rep("─", math.min(24, width)), "@markup.heading" } }
  end
  return render_inline(line, default_highlight)
end

local function note_highlight(highlight)
  local name = "NaviNote" .. highlight:gsub("[^%w]", "")
  local source = vim.api.nvim_get_hl(0, { name = highlight, link = false })
  local surface = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  source.bg = surface.bg
  vim.api.nvim_set_hl(0, name, source)
  return name
end

local function decorate_note_line(chunks, width)
  local rail = width >= 2 and "▎ " or ""
  local line = rail == "" and {} or { { rail, note_highlight("DiagnosticInfo") } }
  local used = vim.fn.strdisplaywidth(rail)
  for _, chunk in ipairs(chunks) do
    table.insert(line, { chunk[1], note_highlight(chunk[2]) })
    used = used + vim.fn.strdisplaywidth(chunk[1])
  end
  table.insert(line, { string.rep(" ", math.max(0, width - used)), note_highlight("Normal") })
  return line
end

local function text_width(window)
  local info = vim.fn.getwininfo(window)[1]
  local textoff = info and info.textoff or 0
  return math.max(1, vim.api.nvim_win_get_width(window) - textoff - 1)
end

local function render_active(window, bufnr)
  clear_extmarks()

  local stop = M.stops[M.current]
  if not stop or not vim.api.nvim_win_is_valid(window) or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if realpath(vim.api.nvim_buf_get_name(bufnr)) ~= stop.file then
    return
  end

  local width = text_width(window)
  local rail_width = width >= 2 and 2 or 0
  local content_width = math.max(1, width - rail_width)
  local virt_lines = {}
  local message = stop.message .. "\n"
  local code_block = false
  for line in message:gmatch("(.-)\n") do
    local fence = line:match("^%s*```%s*(.*)$")
    if fence then
      code_block = not code_block
    else
      for _, wrapped in ipairs(wrap_line(line, content_width)) do
        local chunks = render_markdown_line(wrapped, "Normal", code_block, content_width)
        table.insert(virt_lines, decorate_note_line(chunks, width))
      end
    end
  end

  local source = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  vim.api.nvim_set_hl(0, "NaviRange", { bg = source.bg })
  vim.api.nvim_buf_set_extmark(bufnr, M.ns, stop.line - 1, 0, {
    end_row = stop.end_line,
    hl_group = "NaviRange",
    hl_eol = true,
    priority = 50,
  })
  vim.api.nvim_buf_set_extmark(bufnr, M.ns, stop.end_line - 1, 0, { virt_lines = virt_lines })
end

local function rerender_active()
  local stop = M.stops[M.current]
  if not stop then
    clear_extmarks()
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_win_get_buf(current_win)
  if realpath(vim.api.nvim_buf_get_name(current_buf)) == stop.file then
    render_active(current_win, current_buf)
    return
  end

  for _, window in ipairs(vim.api.nvim_list_wins()) do
    local bufnr = vim.api.nvim_win_get_buf(window)
    if realpath(vim.api.nvim_buf_get_name(bufnr)) == stop.file then
      render_active(window, bufnr)
      return
    end
  end
  clear_extmarks()
end

function M.goto_stop(index)
  if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #M.stops then
    return
  end

  clear_extmarks()
  M.current = index
  local stop = M.stops[index]
  vim.cmd("edit " .. vim.fn.fnameescape(stop.file))
  vim.api.nvim_win_set_cursor(0, { stop.line, 0 })
  vim.cmd("normal! zz")

  update_winbar()
  update_signs()
  render_active(vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf())
end

function M.next()
  if M.current < #M.stops then
    M.goto_stop(M.current + 1)
  else
    vim.notify("End of tour", vim.log.levels.INFO)
  end
end

function M.prev()
  if M.current > 1 then
    M.goto_stop(M.current - 1)
  else
    vim.notify("Start of tour", vim.log.levels.INFO)
  end
end

function M.pick()
  local ok = pcall(require, "telescope")
  if ok then
    require("telescope.pickers")
      .new({}, {
        prompt_title = "Navi Tour",
        finder = require("telescope.finders").new_table({
          results = M.stops,
          entry_maker = function(stop)
            local display = string.format("%d. %s", stop.index, stop.message)
            return { value = stop, display = display, ordinal = display }
          end,
        }),
        sorter = require("telescope.config").values.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
          require("telescope.actions").select_default:replace(function()
            require("telescope.actions").close(prompt_bufnr)
            local selection = require("telescope.actions.state").get_selected_entry()
            M.goto_stop(selection.value.index)
          end)
          return true
        end,
      })
      :find()
  else
    local lines = {}
    for i, stop in ipairs(M.stops) do
      table.insert(lines, string.format("%d. %s", i, stop.message))
    end
    vim.ui.select(lines, { prompt = "Jump to stop:" }, function(_, index)
      if index then
        M.goto_stop(index)
      end
    end)
  end
end

local function validation_error(message)
  local full_message = "Navi: " .. message
  vim.notify(full_message, vim.log.levels.ERROR)
  return nil, full_message
end

local function positive_integer(value)
  return type(value) == "number" and value > 0 and value % 1 == 0
end

local function validate_array(stops)
  if type(stops) ~= "table" then
    return false
  end
  local length = #stops
  if length == 0 then
    return false
  end
  local count = 0
  for key in pairs(stops) do
    if not positive_integer(key) or key > length then
      return false
    end
    count = count + 1
  end
  return count == length
end

local function find_pattern(lines, pattern, first_line)
  for index = first_line or 1, #lines do
    if lines[index]:find(pattern, 1, true) then
      return index
    end
  end
end

local function prepare_stops(input)
  local stops = input
  if type(input) == "string" then
    local ok, decoded = pcall(vim.json.decode, input)
    if not ok then
      return validation_error("invalid JSON: " .. tostring(decoded))
    end
    stops = decoded
  elseif type(input) ~= "table" then
    return validation_error("tour must be a JSON string or Lua array of stops")
  end

  if not validate_array(stops) then
    return validation_error("tour must be a non-empty array of stops")
  end

  local prepared = {}
  for index, stop in ipairs(stops) do
    local label = string.format("stop %d", index)
    if type(stop) ~= "table" then
      return validation_error(label .. " must be a table")
    end
    if type(stop.file) ~= "string" or stop.file == "" then
      return validation_error(label .. ".file must be a non-empty string")
    end
    if type(stop.message) ~= "string" then
      return validation_error(label .. ".message must be a string")
    end

    local has_line = stop.line ~= nil
    local has_pattern = stop.pattern ~= nil
    if has_line == has_pattern then
      return validation_error(label .. " must specify exactly one of .line or .pattern")
    end
    local has_end_line = stop.end_line ~= nil
    local has_end_pattern = stop.end_pattern ~= nil
    if has_end_line and has_end_pattern then
      return validation_error(label .. " may specify at most one of .end_line or .end_pattern")
    end
    if has_line and not positive_integer(stop.line) then
      return validation_error(label .. ".line must be a positive integer")
    end
    if has_end_line and not positive_integer(stop.end_line) then
      return validation_error(label .. ".end_line must be a positive integer")
    end
    if has_pattern and (type(stop.pattern) ~= "string" or stop.pattern == "") then
      return validation_error(label .. ".pattern must be a non-empty string")
    end
    if has_end_pattern and (type(stop.end_pattern) ~= "string" or stop.end_pattern == "") then
      return validation_error(label .. ".end_pattern must be a non-empty string")
    end

    local filepath = realpath(stop.file)
    if vim.fn.filereadable(filepath) ~= 1 then
      return validation_error(string.format("%s.file is not readable: %s", label, stop.file))
    end
    local ok, lines = pcall(vim.fn.readfile, filepath)
    if not ok then
      return validation_error(string.format("could not read %s.file: %s", label, stop.file))
    end

    local line = stop.line or find_pattern(lines, stop.pattern)
    if not line then
      return validation_error(string.format("%s.pattern was not found in %s: %s", label, stop.file, stop.pattern))
    end
    if line > #lines then
      return validation_error(string.format("%s.line %d exceeds the %d-line file", label, line, #lines))
    end

    local end_line = stop.end_line or line
    if has_end_pattern then
      end_line = find_pattern(lines, stop.end_pattern, line)
      if not end_line then
        return validation_error(
          string.format(
            "%s.end_pattern was not found at or after line %d in %s: %s",
            label,
            line,
            stop.file,
            stop.end_pattern
          )
        )
      end
    end
    if end_line > #lines then
      return validation_error(string.format("%s.end_line %d exceeds the %d-line file", label, end_line, #lines))
    end
    if end_line < line then
      return validation_error(string.format("%s end line %d is before start line %d", label, end_line, line))
    end

    table.insert(prepared, {
      index = index,
      file = filepath,
      line = line,
      end_line = end_line,
      message = stop.message,
    })
  end

  return prepared
end

function M.load(input)
  local stops, err = prepare_stops(input)
  if not stops then
    return nil, err
  end

  restore_winbar()
  clear_extmarks()
  vim.fn.sign_unplace(M.sign_group)

  origin_win = vim.api.nvim_get_current_win()
  origin_winbar = vim.api.nvim_get_option_value("winbar", { win = origin_win })
  M.stops = stops
  M.current = 0
  M.goto_stop(1)
  vim.notify(string.format("Navi tour loaded: %d stop%s", #M.stops, #M.stops == 1 and "" or "s"), vim.log.levels.INFO)
  return true
end

function M.load_file(filepath)
  local file, open_error = io.open(filepath, "r")
  if not file then
    return validation_error(string.format("could not open tour file %s: %s", filepath, open_error or "unknown error"))
  end
  local content = file:read("*a")
  file:close()
  return M.load(content)
end

function M.clear()
  clear_extmarks()
  vim.fn.sign_unplace(M.sign_group)
  restore_winbar()
  M.stops = {}
  M.current = 0
end

local augroup = vim.api.nvim_create_augroup("Navi", { clear = true })
vim.api.nvim_create_autocmd({ "VimResized", "ColorScheme" }, {
  group = augroup,
  callback = function()
    if #M.stops > 0 then
      rerender_active()
    end
  end,
})
vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
  group = augroup,
  callback = function(args)
    local stop = M.stops[M.current]
    if stop and realpath(vim.api.nvim_buf_get_name(args.buf)) == stop.file then
      render_active(vim.api.nvim_get_current_win(), args.buf)
    end
  end,
})

return M
