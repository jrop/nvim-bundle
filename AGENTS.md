# nvim-bundle - Agent Development Guide

## Project

`lua/nvim-bundle.lua` is a standalone Lua bundler, not a Neovim plugin. It scans a
source root, maps each file to a module id, and emits one Lua file whose
resolvable `require` calls are linked directly to the bundled module functions.
Calls that cannot be resolved statically remain host `require` calls.

The CLI parses arguments with the vendored args.nvim copy at
`lua/nvim-bundle/vendor/args.lua`. The release task bundles nvim-bundle with
itself using `--bin`, so that require is also exercised during releases.

The file is also its own CLI entry point, so an example run is:

```sh
nvim --clean -l lua/nvim-bundle.lua build morph --exclude '**/_test/**'
```

## Commands

All tasks use `mise`:

- `mise run fmt` - format with stylua
- `mise run fmt:check` - check formatting
- `mise run generate` - generate `lua/nvim-bundle/dto.types.lua` from the guard
  schemas; skipped while the output is newer than its sources
- `mise run lint` - `generate`, then type-check with `emmylua_check` (warnings
  are errors)
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
busted spec/define_spec.lua
```

## Architecture

- **`lua/nvim-bundle.lua`** - the CLI: one `COMMANDS` entry per subcommand
  owns its options, usage text, and `run`. It also exposes the public `build`
  API.
- **`lua/nvim-bundle/build.lua`** - module-id resolution, file discovery,
  and static bundle assembly. It is separate
  from the CLI so `install` can build dependencies without requiring the CLI
  module while it is still loading.
- **`lua/nvim-bundle/deps.lua`** - `install`, `remove`, `update`, and
  `outdated`. Every dependency is a git repository built from source: it parses
  each manifest entry once into a dependency value and owns the manifest and
  lock entries. Every vendored file starts with `---@diagnostic disable`, and
  its locked `sha256` covers that line.
- **`lua/nvim-bundle/git.lua`** - the git commands every dependency goes
  through: `latest_tag`, `branch_head`, `ref_kind`, and `checkout`.
- **`lua/nvim-bundle/dto.lua`** - guard schemas for every value that enters
  from outside: the manifest, the lock, and `build` options. `check` validates
  against one and raises a message naming each problem. The LuaCATS classes
  (`nvim-bundle.dto.*`) are generated into the git-ignored `dto.types.lua`, so
  never hand-write a class for a DTO; edit the schema and run `generate`. The
  module requires only guard, because the generator loads it on its own.
- **`lua/nvim-bundle/transform.lua`** - the pipeline every module source
  passes through, and the `Tree` class that passes use: `matches` runs a
  query (Neovim caches each parsed query), `text` reads a node, `literal`
  evaluates a number or string literal, and `replace` swaps node texts and
  returns the re-parsed tree. Tree-sitter trees are read-only, so a pass
  changes text and the tree is parsed again. `replace` keeps every pass's line
  numbers (see Static linking).
- **`lua/nvim-bundle/transform/*.lua`** - one pass per file, each a function
  from tree to tree. A pass reads what the build knows from `tree.build` and owns its
  queries as string constants. `PASSES` in `transform.lua` fixes their order:
  `define`, `dead_code`, then `require`: dead-code removal reads the literals
  that define inserts, and a require in a removed branch is never linked.
- **`lua/nvim-bundle/files.lua`** - file and JSON I/O for building and
  vendoring. JSON is written with sorted keys so manifests diff cleanly.
- **`lua/nvim-bundle/version.lua`** - `VERSION`, read from
  `vim.g.nvim_bundle_version`, which the release task sets with `--define`.
- **`lua/nvim-bundle/vendor/args.lua`** - vendored args.nvim v0.1.0 parser.
  Treat it as third-party code: update it from the upstream release rather than
  editing it in place.
- **`lua/nvim-bundle/vendor/guard.lua`** - vendored guard v0.1.0, the schema
  library behind `dto.lua`. It is also the type generator `generate` runs.
  Treat it as third-party code, like args.
- **`spec/*_spec.lua`** - black-box tests, one file per area: `cli`,
  `build` (bundle shape, bin bundles, registries, excludes), one file per
  transform pass (`require`, `define`, `dead_code`), `types`,
  `project_files` (manifest and lock validation), and `deps`. Each case
  writes a fixture tree to a temporary directory, runs the CLI in a child
  Neovim, and executes or inspects the emitted bundle. The `types` cases shell
  out to `emmylua_check`. Dependency cases run offline: the `remote` helper
  makes a local repository with a `file://` URL, and the `owner/repo`
  shorthand is tested through git's own `url.<base>.insteadOf` setting.
- **`spec/helpers.lua`** - what every spec file shares: fixtures, the CLI
  runner, and local remotes. Busted gives `assert` its matchers only inside
  spec files, so the helpers require `luassert` themselves. Each spec file
  registers `after_each(h.remove_created)` to delete its temporary paths.
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
- Direct `require 'literal'` and `require("literal")` calls are
  rewritten to `__mods.<derived>("literal")`.
- `pcall(require, 'literal')` and `xpcall(require, handler, 'literal')` are
  rewritten so the `require` argument becomes a forwarding function; this keeps
  type inference through `pcall`.
- Computed names, aliases, shadowed `require`/`pcall`/`xpcall`, excluded
  modules, and modules outside the bundle remain host requires.
- Every replacement keeps its module's line numbers: `Tree:replace` pads a
  shortened replacement with leading line breaks, prefixes `;` to a value that
  starts with `(` after another statement, and fails on a replacement that adds
  lines.
- A module that the Lua tree-sitter parser cannot parse also keeps its requires
  dynamic.
- Every module function is a thin wrapper around one generic `__load(id, fn,
  ...)`, which owns caching and cycle detection in a single `__loaded` table.
  The `fun(...): T` annotation carries each module's return type to the
  caller; a cache read before it is assigned would otherwise make every
  `require` of the bundle look nil-able. A module that returns nothing is
  cached as `true`, as `require` does. Wrappers are never reassigned, so
  `pcall` inference still has a stable function to look at.
- `build <entry>` ends the bundle with `return __mods.<field>(<id>)`, so
  requiring it behaves like requiring the module. `build` with no entry
  returns a registry of lazy loaders instead, named after the root's one
  package. `--bin` needs an entry, prepends a shebang and modeline, and sets
  the executable bit; executing it lets the module's own `is_main` guard run.
- `--define <key>=<value>` replaces each read of a global name or dotted path
  with a Lua expression, in every module including vendored bundles. Field
  names, table keys, strings, comments, and names the module declares itself
  are left alone; an unmatched key is silent; an
  assignment to a defined key, or through it, is a build error.
- Dead-code removal runs on every build. It removes an `if`/`elseif`/`while`
  branch only when its condition is built from literals, `not`, `==`, `~=`,
  parentheses, or an `and`/`or` whose left side decides the result. A kept
  branch becomes `do ... end`, and a statement removed whole becomes `do end`,
  so scope, `return`, and neighboring lines behave as before.
- Every module except the entry (every module, in a registry) begins with
  `local arg = {}`. All modules share the bundle's source path, so without it
  a library's own `is_main` guard would pass whenever the bundle is executed.
  `debug.getinfo` still reports the bundle file for every module; see
  `docs/explanation.md` ("Why libraries see an empty `arg`").
- The entry is looked up by module id, so its file rules are exactly the module
  id rules.

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
- Hand-written types are namespaced by module path, as the generated ones are:
  `nvim-bundle.deps.Dependency` lives in `lua/nvim-bundle/deps.lua`.
- Stylua: single quotes, no call parentheses for simple statements, 2-space
  indent, 100-column width, sorted requires.
- Generated bundles are build artifacts and live under `dist/`, which is
  git-ignored.
- The release task builds `lua/` with `--bin` into the extensionless
  `dist/nvim-bundle` asset, with `--define` setting the version it reports. The
  self-bundle inlines the vendored parser, keeps the `require 'nvim-bundle'`
  return shape, and carries its own shebang and modeline. The source keeps its
  `.lua` extension so `stylua`, `emmylua_check`, and `require 'nvim-bundle'`
  keep working during development.
- Module ids follow Neovim's lookup order: `lua/foo.lua` shadows
  `lua/foo/init.lua`, so the init file is addressable as `foo.init`.
- `VERSION` in `lua/nvim-bundle/version.lua` falls back to the version a
  checkout reports. The release task defines `vim.g.nvim_bundle_version` as
  the tag, so the published `--version` always matches its release.
- Do not reintroduce `--source-strings`: sources are always emitted as code so
  language-server annotations remain visible.
