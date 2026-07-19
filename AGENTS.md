# navi.nvim

## Purpose

Navi is a dependency-free Neovim plugin for navigating JSON-defined source tours. Preserve the zero-configuration runtime behavior and direct Lua API.

## Layout

- `lua/navi/init.lua`: tour state, navigation, rendering, signs, and public Lua API.
- `lua/navi/evidence.lua`: optional Neotest consumer for inline test evidence that is cleared when source changes.
- `plugin/navi.lua`: automatically loaded user-command definitions.
- `tests/navi.lua`: headless integration tests using only Neovim APIs.
- `tests/evidence.lua`: dependency-stubbed Neotest consumer integration tests.
- `scripts/test`: portable test entry point.

## Development

- Run `make test` after changes.
- Keep the plugin dependency-free; Telescope must remain optional.
- Do not introduce machine-specific paths into source, tests, or documentation examples.
- Keep stop line numbers one-based and range ends inclusive at the public boundary.
- Test visible behavior through Neovim APIs rather than exposing rendering internals.
- Update the README when commands, mappings, schema fields, or public Lua functions change.
