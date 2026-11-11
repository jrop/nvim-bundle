# nvim-bundle - Agent Development Guide

## Project

`lua/nvim-bundle.lua` is a standalone Lua bundler, not a Neovim plugin. It scans a
source root, maps each file to a module id, and emits one Lua file whose
resolvable `require` calls are linked directly to the bundled module functions.
Calls that cannot be resolved statically remain host `require` calls.

The CLI parses arguments with the vendored args.nvim copy at
`lua/nvim-bundle/_vendor/args.lua`. The release task bundles nvim-bundle with
itself using `--bin`, so that require is also exercised during releases.

The file is also its own CLI entry point, so an example run is:

```sh
nvim --clean -l lua/nvim-bundle.lua morph --exclude '**/_test/**'
```

## Commands

All tasks use `mise`:

- `mise run fmt` - format with stylua
- `mise run fmt:check` - check formatting
- `mise run lint` - type-check with `emmylua_check` (warnings are errors)
- `mise run test` - run busted against Neovim 0.12.6
- `mise run test:all` - run busted against 0.10.4, 0.11.7, 0.12.6, and nightly
- `mise run test:coverage` - test with luacov (covers `lua/nvim-bundle` only)
- `mise run ci` - `fmt:check` then `lint` then `test:all`
- `mise run release` - publish the current `v*` tag to GitHub (maintainers only)

Initialize the type-stub submodule after cloning:

```sh
git submodule update --init --recursive
```

Run one spec file directly after `mise run test:prepare`:

```sh
eval $(nvimv env 0.12.6)
busted spec/nvim-bundle_spec.lua
```

## Architecture

- **`lua/nvim-bundle.lua`** - argument parsing, the public `build` API,
  module-id resolution, file discovery, tree-sitter require rewriting, and
  static bundle assembly.
- **`lua/nvim-bundle/_vendor/args.lua`** - vendored args.nvim v0.1.0 parser.
  Treat it as third-party code: update it from the upstream release rather than
  editing it in place.
- **`spec/nvim-bundle_spec.lua`** - black-box tests. Each case writes a fixture
  tree to a temporary directory, runs the CLI in a child Neovim, and executes
  or inspects the emitted bundle. The `types` cases shell out to
  `emmylua_check`.
- **`library/busted`** - git submodule with busted type stubs (stylua-ignored).

## Documentation

The documentation follows the four Diátaxis modes:

- **`README.md`** - the tutorial and front door. Keep it learning-oriented.
- **`docs/how-to.md`** - task-oriented recipes for users and maintainers.
- **`docs/reference.md`** - CLI, module ids, generated bundle, and Lua API.
- **`docs/explanation.md`** - why static linking, executable bundles, and
  self-hosting work the way they do.

Do not put implementation rationale in the README or how-to guide; link to the
explanation instead.

## Static linking

- Every module becomes a function in the generated `__mods` table. Its field
  name derives from the module id: `myplugin.util` becomes
  `__mods._myplugin_util`, and collisions get a numeric suffix.
- Direct single-line `require 'literal'` and `require("literal")` calls are
  rewritten to `__mods.<derived>("literal")`.
- `pcall(require, 'literal')` and `xpcall(require, handler, 'literal')` are
  rewritten so the `require` argument becomes a forwarding function; this keeps
  type inference through `pcall`.
- Computed names, aliases, shadowed `require`/`pcall`/`xpcall`, multi-line
  calls, excluded modules, and modules outside the bundle remain host requires.
- A module that the Lua tree-sitter parser cannot parse also keeps its requires
  dynamic.
- Modules cache their values in a block-local upvalue inside one `do` block per
  module, which avoids Lua's 200-local limit and keeps module functions stable
  enough for `pcall` type inference.
- A normal bundle returns a registry of lazy loaders. With `--bin`, the bundle
  instead ends with `return __mods.<entry>(<entry id>)`, so requiring it
  returns the entry module and executing it lets the entry's own `is_main`
  guard run. `--bin` also prepends a shebang and modeline and sets the
  executable bit.

## Test environment

The host (busted runner) is an isolated headless Neovim invoked as
`nvim --clean -l`. Specs invoke the CLI in a child Neovim, so they exercise the
same `main` boundary a user does. The generated bundle is then executed
in-process, where `vim.*` and `vim.treesitter` are available.

A fixture proves that bundling works by requiring a module that exists only in
the fixture directory. The host's `package.path` cannot see that module, so a
successful `require` must have been statically linked into the bundle.

## Conventions

- LuaJIT; do **not** use goto.
- Stylua: single quotes, no call parentheses for simple statements, 2-space
  indent, 100-column width, sorted requires.
- Generated bundles are build artifacts and live under `dist/`, which is
  git-ignored.
- The release task builds `lua/` with `--bin` into the extensionless
  `dist/nvim-bundle` asset, then stamps the tag into the built file. The
  self-bundle inlines the vendored parser, keeps the `require 'nvim-bundle'`
  return shape, and carries its own shebang and modeline. The source keeps its
  `.lua` extension so `stylua`, `emmylua_check`, and `require 'nvim-bundle'`
  keep working during development.
- Module ids follow Neovim's lookup order: `lua/foo.lua` shadows
  `lua/foo/init.lua`, so the init file is addressable as `foo.init`.
- `VERSION` in `lua/nvim-bundle.lua` is the version a checkout reports. The
  release task stamps the tag into the built asset, so the published
  `--version` always matches its release.
- Do not reintroduce `--source-strings`: sources are always emitted as code so
  language-server annotations remain visible.
