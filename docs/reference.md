# Reference

Descriptions of the command, its options, the module-id rules, and the
programmatic API.

## CLI

```text
Usage: nvim-bundle <entry> [options]

Options:
  --root <dir>       Source root to scan (default: lua)
  --out <file>       Output bundle (default: dist/<entry>.lua)
  --exclude <glob>   Skip paths matching <glob> (repeatable)
  --bin              Make an executable that returns the entry module
  -h, --help         Show this help
  -V, --version      Print the nvim-bundle and Neovim versions
```

`<entry>` is a module name, not a file path. A dotted entry such as
`myplugin.core` resolves to `lua/myplugin/core.lua` first, then to
`lua/myplugin/core/init.lua`. The command scans `--root`, writes one file, and
prints a summary.

| Option             | Behavior                                                              |
| ------------------ | --------------------------------------------------------------------- |
| `--root <dir>`     | Changes the directory that is scanned. The default is `lua`.          |
| `--out <file>`     | Changes the generated file. The default is `dist/<entry>.lua`.        |
| `--exclude <glob>` | Skips matching files. Repeat the option to add more globs.            |
| `--bin`            | Adds a shebang, makes the file executable, and returns the entry.     |
| `-h`, `--help`     | Prints usage without bundling anything.                               |
| `-V`, `--version`  | Prints the nvim-bundle and Neovim versions without bundling.          |

`nvim-bundle --version` and `nvim-bundle -V` print the nvim-bundle version and
the Neovim version that is running it, for example:

```text
nvim-bundle 0.1.0 (Neovim 0.12.6)
```

The command exits with status 0 on success and status 1 on failure. Errors are
written to stderr. `--help` prints usage and exits successfully.

## Module ids

Every `.lua` file below the source root becomes a module. The id is derived by
removing the `.lua` suffix and replacing directory separators with dots:

| File                                                        | Module id       |
| ----------------------------------------------------------- | --------------- |
| `lua/myplugin.lua`                                          | `myplugin`      |
| `lua/myplugin/core.lua`                                     | `myplugin.core` |
| `lua/myplugin/init.lua`                                     | `myplugin`      |
| `lua/myplugin/init.lua` when `lua/myplugin.lua` also exists | `myplugin.init` |
| `lua/init.lua`                                              | `init`          |

`lua/foo.lua` shadows `lua/foo/init.lua` for `require 'foo'`, so the directory's
init file remains addressable as `foo.init`. A root `lua/init.lua` becomes
`init` because there is no parent module name to attach it to.

Two files can map to the same id when dots are used in filenames. For example,
`lua/a/b.lua` and `lua/a.b.lua` both become `a.b`. The bundler rejects that
layout with `module id collision`.

## Generated bundle

By default, the generated file returns a registry table keyed by module id.
Each value is a lazy loader that returns that module's exports. The file also
defines a module table named `__mods`.

- Each module is stored as a function whose field name derives from the module
  id. For example, `myplugin.util` becomes `__mods._myplugin_util`.
- A resolved `require 'myplugin.util'` becomes a direct call to that function.
- A call the linker cannot resolve remains a host `require` call.
- A bundled module is evaluated at most once and caches its value.
- A require cycle raises `loop or previous error loading module '<name>'`.
- The registry contains every bundled module, including the entry. Installing
  the output as `lua/myplugin.lua` makes `require 'myplugin'` return the
  registry, so the entry is reached through its loader:

  ```lua
  local bundle = require 'myplugin'
  local myplugin = bundle['myplugin']()
  local core = bundle['myplugin.core']()
  ```

- The registry is lazy: creating it evaluates no modules, and calling a loader
  evaluates that module at most once. A loader returns the module's value as a
  static call would, including `nil` for a module with no return value.
- Indexing the registry with a literal id lets the language server use the
  module's type. This is less ergonomic than a callable `bundle('id')`, but the
  call form would need a written return type for every module; see
  [Reaching a bundled module](explanation.md#reaching-a-bundled-module).
- The bundle's modules are private to the bundle: the host only caches the
  registry under the bundle's name.

With `--bin`, the file is an executable instead. It starts with the shebang
`#!/usr/bin/env -S nvim --clean -l` and a modeline, carries the executable bit,
and returns the entry module's value rather than the registry. The entry module
decides whether it is the main script, so executing the file runs its own
`main` guard and requiring it returns the entry's exports. The registry is not
reachable from a `--bin` bundle.

See [How static linking works](explanation.md#how-static-linking-works) for the
reason behind these rules.

## Programmatic API

### `NvimBundle.build(opts)`

```lua
local NvimBundle = require 'nvim-bundle'
local result = NvimBundle.build { entry = 'myplugin' }
```

`entry` is required. `root` defaults to `lua`, `out` defaults to
`dist/<entry>.lua`, and `exclude` defaults to an empty list. Set `bin = true` to
make the output executable.

```lua
{
  out = 'dist/myplugin.lua',
  entry = 'myplugin',
  modules = 12,
}
```

`out` is the output path, `entry` is the resolved entry module id, and `modules`
is the number of emitted modules. `build` raises on failure. The process
boundary around it is private; running the script or a `--bin` bundle is the
supported way to get the summary, error, and exit-status behavior.

## Validation

The bundler stops before writing a bundle when:

- The entry module cannot be found. The error lists the candidate paths.
- The entry is excluded from the bundle.
- A module has a syntax error. The error names the source file.
- The Lua tree-sitter parser is unavailable.
- The output path is inside the source root.
- Two files map to the same module id.
- An `--exclude` glob is invalid.

Byte-order marks and shebangs are removed from module sources, and a missing
final newline is added.

## Project layout

- `README.md` — tutorial and documentation entry point.
- `lua/nvim-bundle.lua` — the bundler and its CLI entry point.
- `lua/nvim-bundle/_vendor/args.lua` — vendored args.nvim argument parser.
- `docs/how-to.md` — task-oriented guides.
- `docs/reference.md` — this reference.
- `docs/explanation.md` — design rationale and limitations.
- `spec/nvim-bundle_spec.lua` — black-box tests using temporary fixture trees.
- `library/busted/` — git submodule with type stubs for busted.
- `scripts/env.sh` — exports `PREFIX`, `VIMRUNTIME`, and the luarocks path.
- `dist/` — generated bundles; git-ignored.
