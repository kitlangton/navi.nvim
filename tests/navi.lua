local function assert_equal(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %q, got %q", message, expected, actual))
end

local function extmarks(navi, bufnr)
  return vim.api.nvim_buf_get_extmarks(bufnr, navi.ns, 0, -1, { details = true })
end

local function note_mark(navi, bufnr)
  for _, mark in ipairs(extmarks(navi, bufnr)) do
    if mark[4].virt_lines then
      return mark
    end
  end
end

local function assert_note_width(note, width, message)
  for _, line in ipairs(note[4].virt_lines) do
    local actual = 0
    for _, chunk in ipairs(line) do
      actual = actual + vim.fn.strdisplaywidth(chunk[1])
    end
    assert(actual <= width, string.format("%s: expected <= %d, got %d", message, width, actual))
  end
end

local root = vim.fn.tempname()
local first_file = root .. "/reactivity.ts"
local second_file = root .. "/consumer.ts"
local linked_file = root .. "/linked-reactivity.ts"

vim.fn.mkdir(root, "p")
vim.fn.writefile({
  "export function createSignal<T>(initialValue: T) {",
  "  let value = initialValue",
  "  const read = () => value",
  "  const write = (nextValue: T) => (value = nextValue)",
  "",
  "  return [read, write] as const",
  "}",
}, first_file)
vim.fn.writefile({
  "const [read, write] = createSignal(0)",
  "write(1)",
  "console.log(read())",
}, second_file)
assert(vim.uv.fs_symlink(first_file, linked_file), "expected test symlink")

vim.cmd.edit(vim.fn.fnameescape(linked_file))
vim.cmd.vsplit()
vim.wo.number = true
vim.wo.signcolumn = "yes"
vim.wo.winbar = "Original winbar"
vim.api.nvim_win_set_width(0, 60)
vim.api.nvim_set_hl(0, "Normal", { bg = 0x101010, fg = 0xeeeeee })
vim.api.nvim_set_hl(0, "NormalFloat", { bg = 0x202020, fg = 0xeeeeee })

vim.keymap.set("n", "<Tab>", "<cmd>let g:navi_tab = 1<cr>")
vim.keymap.set("n", "<S-Tab>", "<cmd>let g:navi_stab = 1<cr>")
vim.keymap.set("n", "<leader>np", "<cmd>let g:navi_pick = 1<cr>")
vim.keymap.set("n", "Q", "<cmd>let g:navi_q = 1<cr>")
local mappings = {
  tab = vim.fn.maparg("<Tab>", "n"),
  stab = vim.fn.maparg("<S-Tab>", "n"),
  pick = vim.fn.maparg("<leader>np", "n"),
  q = vim.fn.maparg("Q", "n"),
}

local commands = vim.api.nvim_get_commands({})
for _, name in ipairs({ "NaviLoad", "NaviNext", "NaviPrev", "NaviPick", "NaviClear" }) do
  assert(commands[name], "expected :" .. name .. " to be registered")
end

local navi = require("navi")
local canonical_first = assert(vim.uv.fs_realpath(first_file))
local canonical_second = assert(vim.uv.fs_realpath(second_file))
local long_token = string.rep("unbroken", 10)

-- Direct Lua tables are accepted, symlinks match canonical paths, and single-stop UI is minimal.
assert(navi.load({
  {
    file = canonical_first,
    pattern = "export function createSignal",
    end_pattern = "return [read, write]",
    message = "# Closure\n" .. long_token,
  },
}))
assert_equal(navi.stops[1].line, 1, "pattern start")
assert_equal(navi.stops[1].end_line, 6, "pattern end")
local first_buf = vim.fn.bufnr(canonical_first)
assert(first_buf ~= -1, "expected the first file buffer")
assert_equal(#extmarks(navi, first_buf), 2, "single-stop range and note extmarks")
local note = assert(note_mark(navi, first_buf), "expected note extmark")
local wide_note_lines = #note[4].virt_lines
assert_equal(note[4].virt_lines[1][1][1], "▎ ", "note accent rail")
assert_equal(note[4].virt_lines[1][2][1], "Closure", "Markdown-like heading marker removal")
assert_equal(vim.wo.winbar, "", "single-stop winbar")
local signs = vim.fn.sign_getplaced(first_buf, { group = navi.sign_group })[1].signs
assert(#signs == 1 and signs[1].name == "NaviCurrent10", "expected an asterisk sign for one stop")

local range_hl = vim.api.nvim_get_hl(0, { name = "NaviRange", link = false })
local note_hl = vim.api.nvim_get_hl(0, { name = "NaviNoteNormal", link = false })
assert_equal(range_hl.bg, 0x101010, "range keeps Normal background")
assert_equal(note_hl.bg, 0x202020, "note uses distinct NormalFloat background")

assert_equal(vim.fn.maparg("<Tab>", "n"), mappings.tab, "load preserves Tab mapping")
assert_equal(vim.fn.maparg("<S-Tab>", "n"), mappings.stab, "load preserves Shift-Tab mapping")
assert_equal(vim.fn.maparg("<leader>np", "n"), mappings.pick, "load preserves picker mapping")
assert_equal(vim.fn.maparg("Q", "n"), mappings.q, "load preserves Q mapping")

-- Narrow rendering uses the real viewport and hard-splits long unbroken tokens.
vim.api.nvim_win_set_width(0, 18)
vim.api.nvim_exec_autocmds("VimResized", {})
note = assert(note_mark(navi, first_buf), "expected rerendered note after resize")
local window_info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
local available_width = vim.api.nvim_win_get_width(0) - window_info.textoff - 1
assert(available_width < 20, "expected a viewport narrower than the old 20-column floor")
assert(#note[4].virt_lines > wide_note_lines, "expected the long token to hard-wrap")
assert_note_width(note, available_width, "narrow note width")

-- ColorScheme also rebuilds highlights and rerenders the active note.
vim.api.nvim_buf_clear_namespace(first_buf, navi.ns, 0, -1)
vim.api.nvim_exec_autocmds("ColorScheme", {})
assert_equal(#extmarks(navi, first_buf), 2, "ColorScheme rerender")

-- A JSON tour spanning two files clears stale extmarks whenever navigation changes buffers.
assert(navi.load(vim.json.encode({
  { file = canonical_first, line = 2, message = "First stop" },
  { file = canonical_second, line = 2, end_line = 3, message = "Second stop" },
})))
assert_equal(vim.wo.winbar, " ▶ 1/2", "multi-stop winbar")
signs = vim.fn.sign_getplaced(first_buf, { group = navi.sign_group })[1].signs
assert_equal(#signs, 1, "first file sign")
assert_equal(signs[1].name, "NaviCurrent1", "current numbered sign")

navi.next()
local second_buf = vim.fn.bufnr(canonical_second)
assert_equal(navi.current, 2, "next navigation")
assert_equal(#extmarks(navi, first_buf), 0, "first buffer stale extmarks cleared")
assert_equal(#extmarks(navi, second_buf), 2, "second buffer active extmarks")
assert_equal(vim.wo.winbar, " ▶ 2/2", "updated winbar")

navi.prev()
assert_equal(navi.current, 1, "previous navigation")
assert_equal(#extmarks(navi, second_buf), 0, "second buffer stale extmarks cleared")
assert_equal(#extmarks(navi, first_buf), 2, "first buffer rerendered")

local original_select = vim.ui.select
vim.ui.select = function(items, options, callback)
  assert_equal(options.prompt, "Jump to stop:", "picker prompt")
  assert_equal(#items, 2, "picker entries")
  callback(items[2], 2)
end
navi.pick()
vim.ui.select = original_select
assert_equal(navi.current, 2, "fallback picker navigation")

-- A successful second tour replaces all state and decoration from the first.
assert(navi.load({ { file = canonical_first, line = 3, message = "Replacement" } }))
assert_equal(#navi.stops, 1, "second tour replaces stops")
assert_equal(navi.stops[1].line, 3, "replacement stop")
assert_equal(#extmarks(navi, second_buf), 0, "replacement clears previously visited buffer")
assert_equal(#extmarks(navi, first_buf), 2, "replacement renders its active buffer")

-- Invalid tours and unreadable tour files leave the replacement tour intact.
local prior_stops = navi.stops
local invalid_tours = {
  "{not json",
  {},
  { "not a stop" },
  { { file = canonical_first, message = "No anchor" } },
  { { file = canonical_first, line = 1, pattern = "export", message = "Two starts" } },
  { { file = canonical_first, line = 1, end_line = 2, end_pattern = "return", message = "Two ends" } },
  { { file = canonical_first, line = 0, message = "Bad line" } },
  { { file = canonical_first, line = 1, message = 42 } },
  { { file = canonical_first, line = 99, message = "Out of bounds" } },
  { { file = canonical_first, line = 1, end_line = 99, message = "End out of bounds" } },
  { { file = canonical_first, line = 2, end_line = 1, message = "End before start" } },
  { { file = canonical_first, pattern = "missing pattern", message = "Missing pattern" } },
  { { file = root .. "/missing-source.ts", line = 1, message = "Missing file" } },
}
for index, invalid in ipairs(invalid_tours) do
  local ok = navi.load(invalid)
  assert(not ok, "expected invalid tour " .. index .. " to fail")
  assert(navi.stops == prior_stops, "invalid tour must retain prior stop table")
  assert_equal(navi.stops[1].line, 3, "invalid tour retains prior state")
  assert_equal(#extmarks(navi, first_buf), 2, "invalid tour retains prior extmarks")
end

local missing_tour = root .. "/missing-tour.json"
assert(not navi.load_file(missing_tour), "expected missing tour file to fail")
assert(navi.stops == prior_stops, "missing tour file retains state")

local malformed_tour = root .. "/malformed.json"
vim.fn.writefile({ "[invalid" }, malformed_tour)
assert(not navi.load_file(malformed_tour), "expected malformed tour file to fail")
assert_equal(vim.fn.filereadable(malformed_tour), 1, "malformed input is not deleted")
assert(navi.stops == prior_stops, "malformed tour file retains state")

local tour_file = root .. "/tour.json"
vim.fn.writefile({ vim.json.encode({ { file = canonical_first, line = 4, message = "From file" } }) }, tour_file)
vim.cmd("NaviLoad " .. vim.fn.fnameescape(tour_file))
assert_equal(navi.stops[1].line, 4, "NaviLoad command")
assert_equal(vim.fn.filereadable(tour_file), 1, "NaviLoad never deletes its input")

vim.cmd.NaviClear()
assert_equal(#navi.stops, 0, "cleared stops")
assert_equal(vim.wo.winbar, "Original winbar", "origin winbar restored")
assert_equal(vim.fn.maparg("<Tab>", "n"), mappings.tab, "clear preserves Tab mapping")
assert_equal(vim.fn.maparg("<S-Tab>", "n"), mappings.stab, "clear preserves Shift-Tab mapping")
assert_equal(vim.fn.maparg("<leader>np", "n"), mappings.pick, "clear preserves picker mapping")
assert_equal(vim.fn.maparg("Q", "n"), mappings.q, "clear preserves Q mapping")
assert_equal(#vim.fn.sign_getplaced(first_buf, { group = navi.sign_group })[1].signs, 0, "cleared signs")
assert_equal(#extmarks(navi, first_buf), 0, "cleared first-buffer extmarks")
assert_equal(#extmarks(navi, second_buf), 0, "cleared second-buffer extmarks")

vim.fn.delete(root, "rf")
print("Navi tests passed")
