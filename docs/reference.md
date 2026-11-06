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
  -h, --help         Show this help
```

Options:

| Option             | Behavior                                                              |
| ------------------ | --------------------------------------------------------------------- |
| `--root <dir>`     | Changes the directory that is scanned. The default is `lua`.          |
| `--out <file>`     | Changes the generated file. The default is `dist/<entry>.lua`.        |
| `--exclude <glob>` | Skips matching files. Repeat the option to add more globs.            |
| `-h`, `--help`     | Prints usage without bundling anything.                               |

`<entry>` is a module name, not a file path. A dotted entry such as
`myplugin.core` resolves to `lua/myplugin/core.lua` first, then to
`lua/myplugin/core/init.lua`.

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

The generated file returns the entry module's value and defines a module table
named `__mods`.

- Each module is stored as a function whose field name derives from the module
  id. For example, `myplugin.util` becomes `__mods._myplugin_util`.
- A resolved `require 'myplugin.util'` becomes a direct call to that function.
- A call the linker cannot resolve remains a host `require` call.
- A bundled module is evaluated at most once and caches its value.
- A require cycle raises `loop or previous error loading module '<name>'`.
- A bundled submodule is private to the bundle. Installing the output as
  `lua/myplugin.lua` makes `require 'myplugin'` return the entry, but
  `require 'myplugin.core'` does not reach the bundled copy.

See [How static linking works](explanation.md#how-static-linking-works) for the
reason behind these rules.

## Programmatic API

### `NvimBundle.run(argv)`

```lua
local NvimBundle = require 'nvim-bundle'
local result = NvimBundle.run { 'myplugin', '--root', 'lua' }
```

`argv` is an array of CLI arguments, without the program name. `run` raises on
failure and returns:

```lua
{
  out = 'dist/myplugin.lua',
  entry = 'myplugin',
  modules = 12,
}
```

`out` is the output path, `entry` is the resolved entry module id, and `modules`
is the number of emitted modules.

### `NvimBundle.main(argv)`

`main` is the CLI wrapper around `run`. It prints the summary to stdout, writes
errors to stderr, and calls `os.exit(1)` on failure. Use it when you are
implementing an executable and want the default CLI behavior.

## Build validation

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
- `docs/how-to.md` — task-oriented guides.
- `docs/reference.md` — this reference.
- `docs/explanation.md` — design rationale and limitations.
- `spec/nvim-bundle_spec.lua` — black-box tests using temporary fixture trees.
- `library/busted/` — git submodule with type stubs for busted.
- `scripts/env.sh` — exports `PREFIX`, `VIMRUNTIME`, and the luarocks path.
- `dist/` — generated bundles; git-ignored.
