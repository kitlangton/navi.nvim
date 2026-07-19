# navi.nvim

A small Neovim companion for JSON-defined source tours. Navi opens each stop, marks its source range, and renders its Markdown-like note as virtual lines beneath the range.

Navi has no required dependencies. If [Telescope](https://github.com/nvim-telescope/telescope.nvim) is available, `:NaviPick` uses it; otherwise it uses `vim.ui.select`.

## Features

- Resolves symlinks and compares real paths when matching stops to buffers.
- Locates ranges by line numbers or literal start and end patterns.
- Renders Markdown-like headings, emphasis, links, lists, quotes, rules, and fenced code in virtual lines.
- Wraps notes to the window's text viewport, excluding number and sign columns.
- Uses an asterisk sign and no winbar for a one-stop tour.
- Uses numbered signs and a count-only `current/total` winbar for multi-stop tours.
- Provides Telescope and built-in pickers plus an explicit clear command.
- Leaves mappings entirely under user control.

## Requirements

- Neovim 0.10 or newer

## Installation

### lazy.nvim

```lua
{
  "kitlangton/navi.nvim",
}
```

No `setup()` call is required.

For a local checkout before publication:

```lua
{
  dir = vim.fn.expand("~/code/open-source/navi.nvim"),
}
```

### vim.pack

On Neovim versions with `vim.pack`, add Navi directly from its Git repository:

```lua
vim.pack.add({
  "https://github.com/kitlangton/navi.nvim",
})
```

### Manual

Clone the repository into a directory on Neovim's `packpath`:

```sh
git clone https://github.com/kitlangton/navi.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/navi.nvim
```

Alternatively, add an existing checkout to `runtimepath` in `init.lua`:

```lua
vim.opt.runtimepath:prepend(vim.fn.expand("~/path/to/navi.nvim"))
```

## Commands

| Command | Description |
| --- | --- |
| `:NaviLoad {file}` | Load a tour from a JSON file without modifying the file. |
| `:NaviNext` | Go to the next stop. |
| `:NaviPrev` | Go to the previous stop. |
| `:NaviPick` | Select any stop with Telescope or `vim.ui.select`. |
| `:NaviClear` | End the tour, remove its signs and virtual lines, and restore the prior winbar. |

Navi does not create global mappings. Optional mappings can call either the commands or Lua API:

```lua
vim.keymap.set("n", "]n", "<Cmd>NaviNext<CR>", { desc = "Next Navi stop" })
vim.keymap.set("n", "[n", "<Cmd>NaviPrev<CR>", { desc = "Previous Navi stop" })
vim.keymap.set("n", "<leader>np", "<Cmd>NaviPick<CR>", { desc = "Pick Navi stop" })
vim.keymap.set("n", "<leader>nc", "<Cmd>NaviClear<CR>", { desc = "Clear Navi tour" })
```

## JSON schema

A tour is a JSON array of stop objects:

```json
[
  {
    "file": "src/example.ts",
    "pattern": "export function example",
    "end_pattern": "return result",
    "message": "## The example\n\nThis range returns the computed **result**."
  },
  {
    "file": "src/other.ts",
    "line": 12,
    "end_line": 18,
    "message": "A stop can use explicit line numbers."
  }
]
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `file` | string | yes | File to open. Relative paths are resolved from Neovim's working directory. |
| `line` | positive integer | exactly one start anchor | One-based start line. |
| `pattern` | non-empty string | exactly one start anchor | Literal text used to find the first matching start line. |
| `end_line` | positive integer | no | One-based inclusive end line. Mutually exclusive with `end_pattern`. |
| `end_pattern` | non-empty string | no | Literal text used to find the first match at or after the start. Mutually exclusive with `end_line`. |
| `message` | string | yes | Markdown-like note rendered below the source range. May be empty. |

The tour must be a non-empty array of stop objects. Every source file must be readable when the tour is loaded. Numeric anchors must be within the file, an end must not precede its start, and every pattern must resolve. Pattern matching is literal, not a Lua pattern or regular expression.

Validation is transactional: Navi resolves and validates every stop before replacing the active tour. Malformed JSON, a missing source or tour file, an unresolved pattern, or any schema error reports the stop and field involved while leaving the prior tour and its UI intact.

## Lua API

```lua
local navi = require("navi")

-- Load decoded Lua stop tables.
navi.load({
  {
    file = "src/example.ts",
    line = 10,
    end_line = 14,
    message = "Explain this range.",
  },
})

-- Or load a JSON string.
navi.load(vim.json.encode({
  {
    file = "src/example.ts",
    line = 10,
    end_line = 14,
    message = "Explain this range.",
  },
}))

-- Load a JSON file without modifying it.
navi.load_file("/path/to/tour.json")

navi.next()
navi.prev()
navi.goto_stop(1)
navi.pick()
navi.clear()
```

The current state is available as `navi.stops` and `navi.current`.

## Testing

Run the dependency-free headless suite from any working directory:

```sh
make test
# or
./scripts/test
```

Format or check the Lua sources with StyLua:

```sh
make format
make format-check
```

## License

MIT
