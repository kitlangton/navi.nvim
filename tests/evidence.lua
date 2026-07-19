local function assert_equal(actual, expected, message)
  assert(actual == expected, string.format("%s: expected %q, got %q", message, expected, actual))
end

local output = table.concat({
  "\27[?25l\27[90mstdout\27[2m | src/example.test.ts > example",
  "\27[22m\27[39mfirst value 1",
  "second value 2",
  "",
  "\27[32m✓\27[39m example",
}, "\n")

local tasks = {}
local output_path = vim.fn.tempname()
vim.fn.writefile(vim.split(output, "\n", { plain = true }), output_path)

package.preload["nio"] = function()
  return {
    run = function(effect)
      table.insert(tasks, effect)
    end,
    scheduler = function() end,
  }
end
package.preload["neotest.lib"] = function()
  return {
    files = {
      read = function(path)
        return table.concat(vim.fn.readfile(path), "\n")
      end,
    },
  }
end

local buffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buffer, vim.fn.tempname() .. "/example.test.ts")
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
  'test("example", () => {',
  "  console.log('first value', 1)",
  "})",
})
vim.bo[buffer].modified = false
vim.api.nvim_set_current_buf(buffer)
vim.api.nvim_win_set_cursor(0, { 1, 0 })

local position = {
  id = "example",
  name = "example",
  range = { 0, 0, 2, 2 },
}
local result = {
  status = "passed",
  output = output_path,
}
local tree = {
  data = function()
    return position
  end,
}
local client = {
  get_nearest = function()
    return tree, "vitest"
  end,
  run_tree = function() end,
  get_results = function()
    return { example = result }
  end,
}

local evidence = require("navi.evidence")(client)
evidence.run()
table.remove(tasks, 1)()
local marks = vim.api.nvim_buf_get_extmarks(buffer, evidence.ns, 0, -1, { details = true })
assert_equal(#marks, 1, "passing evidence extmark")
assert_equal(marks[1][2], 2, "evidence row")
assert_equal(marks[1][4].virt_lines[1][1][1], "  ✓ ", "passing icon")
assert_equal(marks[1][4].virt_lines[2][1][1], "    │ first value 1", "first rendered console line")
assert_equal(marks[1][4].virt_lines[3][1][1], "    │ second value 2", "second rendered console line")
assert(vim.api.nvim_get_commands({}).NaviTest, "expected :NaviTest command")

vim.api.nvim_buf_set_lines(buffer, 0, 0, false, { "// inserted above the test" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = buffer })
marks = vim.api.nvim_buf_get_extmarks(buffer, evidence.ns, 0, -1, { details = true })
assert_equal(marks[1][2], 3, "stale evidence follows inserted lines")
assert_equal(marks[1][4].virt_lines[1][1][1], "  ○ ", "stale icon")
assert_equal(marks[1][4].virt_lines[1][2][1], "stale test evidence", "stale label")
assert_equal(marks[1][4].virt_lines[2][1][1], "    │ first value 1", "stale evidence retains output")

local runs = 0
client.run_tree = function()
  runs = runs + 1
end
vim.bo[buffer].modified = true
evidence.run()
assert_equal(runs, 0, "unsaved buffer is not executed")

vim.api.nvim_buf_set_lines(buffer, 0, 1, false, {})
vim.bo[buffer].modified = false
result.status = "failed"
result.errors = { { message = "\27[31mExpected 1\nReceived 2\27[39m" } }
evidence.run()
table.remove(tasks, 1)()
marks = vim.api.nvim_buf_get_extmarks(buffer, evidence.ns, 0, -1, { details = true })
assert_equal(marks[1][4].virt_lines[1][1][1], "  ✗ ", "failure icon")
assert_equal(marks[1][4].virt_lines[2][1][1], "    │ first value 1", "failure retains console output")
assert_equal(marks[1][4].virt_lines[4][1][1], "    │ Expected 1", "first failure line")
assert_equal(marks[1][4].virt_lines[5][1][1], "    │ Received 2", "second failure line")

result.status = "passed"
result.errors = nil
runs = 0
evidence.run()
evidence.run()
table.remove(tasks, 2)()
table.remove(tasks, 1)()
assert_equal(runs, 1, "older overlapping run is ignored")

evidence.run()
client.run_tree = function()
  vim.api.nvim_buf_delete(buffer, { force = true })
end
local ok = pcall(table.remove(tasks, 1))
assert(ok, "buffer deletion during a run must not fail")

vim.fn.delete(output_path)
print("Navi evidence tests passed")
