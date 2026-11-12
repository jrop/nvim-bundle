# Reference

Descriptions of the commands, their options, the module-id rules, the
dependency files, and the programmatic API.

## CLI

```text
Usage: nvim-bundle <command> [options]

Commands:
  build [<entry>]    Bundle a source tree into one Lua file
  install [<spec>]   Vendor a dependency, or sync lua/<name>/vendor/
  remove <alias>     Delete a vendored dependency
  update [<alias>]   Move dependencies to newer tags or branch heads
  outdated           List dependencies that update would move

Options:
  -C <dir>           Run as if started in <dir>
  -h, --help         Show this help
  -V, --version      Print the nvim-bundle and Neovim versions
```

Every action is a subcommand, so the first word after `nvim-bundle` must name
one. An example is `nvim-bundle myplugin`: `myplugin` is not a command, so the
CLI exits with `unknown command: myplugin`.

`nvim-bundle --version` and `nvim-bundle -V` print the nvim-bundle version and
the Neovim version that is running it, for example:

```text
nvim-bundle 0.1.0 (Neovim 0.12.6)
```

The command exits with status 0 on success and status 1 on failure. Errors are
written to stderr. `--help` prints usage and exits successfully.

### `build`

```text
Usage: nvim-bundle build [<entry>] [options]

Options:
  --root <dir>       Source root to scan (default: lua)
  --out <file>       Output bundle (default: dist/<entry>.lua, or
                     dist/<package>.lua for a registry)
  --exclude <glob>   Skip paths matching <glob> (repeatable)
  --bin              Make an executable (needs <entry>)
  -h, --help         Show this help
```

`<entry>` names the module that requiring the bundle returns:

| Command                      | The bundle returns                                  |
| ---------------------------- | --------------------------------------------------- |
| `nvim-bundle build demo`     | `demo`'s value, as `require 'demo'` would.          |
| `nvim-bundle build`          | A [registry](#generated-bundle) of every module.    |
| `nvim-bundle build cli --bin`| `cli`'s value, in an executable file.               |

`<entry>` is a [module id](#module-ids), not a file path, so `myplugin.core`
means `lua/myplugin/core.lua`, or `lua/myplugin/core/init.lua` when the first
file does not exist. With no `<entry>`, the default output is named after the
one package under `--root`, such as `dist/demo.lua` for `lua/demo/`. A root with
several packages needs `--out`. The command scans `--root`, writes one file,
and prints a summary such as `bundled 2 modules into dist/demo.lua (returns
demo)` or `(registry)`.

| Option             | Behavior                                                          |
| ------------------ | ----------------------------------------------------------------- |
| `--root <dir>`     | Changes the directory that is scanned. The default is `lua`.      |
| `--out <file>`     | Changes the generated file.                                       |
| `--exclude <glob>` | Skips matching files. Repeat the option to add more globs.        |
| `--bin`            | Adds a shebang and a modeline, and makes the file executable.     |
| `-h`, `--help`     | Prints the `build` usage without bundling anything.               |

### `install`

```text
Usage: nvim-bundle install [<spec> [<entry>]] [options]

Options:
  --root <dir>       Source root in the repository (default: lua)
  --exclude <glob>   Skip paths matching <glob> (repeatable)
  --as <alias>       Vendor as lua/<name>/vendor/<alias>.lua (default: the
                     package of <entry>, or the repository's one package)
  --force            Overwrite a vendored file that install did not create
  --frozen           With no <spec>, fail instead of changing any file
  -h, --help         Show this help
```

`install <spec> [<entry>]` clones one [dependency](#dependencies), builds it
from source, writes the bundle to `lua/<name>/vendor/<alias>.lua`, and records
it in both [`nvim-bundle.json`](#manifest-nvim-bundlejson) and
[`nvim-bundle.lock.json`](#lock-file-nvim-bundlelockjson). A missing manifest is
created. A spec without a ref resolves to the newest stable tag, and the
manifest records that tag.

`<entry>`, `--root`, and `--exclude` mean exactly what they mean for
[`build`](#build), because the checkout is built the same way; see
[How a dependency is built](#how-a-dependency-is-built). An example is
`install jrop/args.nvim@v0.1.0 args`: the bundle returns `args`, so
`require 'myplugin.vendor.args'` behaves like `require 'args'`. Without
`<entry>`, the bundle is a registry.

`install` refuses to overwrite a file in `vendor/` that the lock does not list,
so a hand-written module is never replaced by accident. `--force` replaces it
anyway.

`install` with no spec makes `vendor/` match the manifest. Each dependency
gets one of these outcomes:

| Situation                                                      | Outcome                                                        |
| -------------------------------------------------------------- | -------------------------------------------------------------- |
| The lock matches the entry, and the file matches the hash      | Nothing happens, and git is not run.                           |
| The lock matches, but the file is missing or edited            | **restore**: rebuild the locked commit and check the hash.     |
| The lock is missing, or records another repo, ref, or setting  | **resolve**: build the entry again.                            |
| The lock has an entry the manifest no longer has               | **remove**: delete the vendored file.                          |

`--frozen` reports the planned outcomes as an error and changes nothing, so CI
fails on a stale `vendor/` directory. Only files recorded in the lock are ever
removed.

### `remove`

`remove <alias>` deletes `lua/<name>/vendor/<alias>.lua` and its manifest and
lock entries.

### `update`

`update [<alias>]` moves every tagged dependency, or only `<alias>`, to its
newest stable tag, and rewrites the tag in the manifest. A branch moves to its
remote head, and the new commit is recorded in the lock. A rev never moves.

### `outdated`

`outdated` prints one line per dependency that `update` would move, such as
`args v0.1.0 -> v0.2.0` or `dep 1a2b3c4 -> 5d6e7f8` for a branch, and one line
per rev, such as `dep is pinned to 1a2b3c4`. It changes no file.

## Dependencies

Every dependency is a git repository, built from source by the installed
nvim-bundle. A manifest entry is a string or an object.

**A string** is a repository with an optional ref:

| String                    | Clones                                         |
| ------------------------- | ---------------------------------------------- |
| `owner/repo[@<ref>]`      | `https://github.com/owner/repo`                |
| `<git url>[@<ref>]`       | Any URL or path git can clone, as written      |

The ref is an `@` in the **last path segment** only. An example is
`git@host:me/dep.nvim@v1.0.0`: the first `@` belongs to the location, and the
ref is `v1.0.0`.

The first `install` decides what kind of ref it is, and the lock records the
answer, so later syncs need no remote:

| The ref is                         | It is treated as | `update` moves it to       |
| ---------------------------------- | ---------------- | -------------------------- |
| A full commit SHA (40 or 64 hex)   | a rev            | nowhere; it stays pinned   |
| A tag on the remote                | a tag            | the newest stable tag      |
| Otherwise, a branch on the remote  | a branch         | the branch's current head  |

A tag wins over a branch of the same name, as it does in git. A ref that is
neither fails with `<ref> is neither a tag nor a branch of <url>`. The
manifest keeps the string as written, except that `update` replaces a tag
with the newer one.

**An object** is the same dependency with build settings. `install` writes
one whenever `<entry>`, `--root`, or `--exclude` was given:

```json
{ "repo": "owner/dep.nvim", "ref": "main", "entry": "dep.core", "root": "src", "exclude": ["**/_test/**"] }
```

| Field      | Meaning                                                                       |
| ---------- | ----------------------------------------------------------------------------- |
| `repo`     | Required. The same forms as a string, without the ref.                        |
| `ref`      | A tag, branch, or SHA, resolved as above. With none, the newest stable tag is used and recorded. |
| `entry`    | The module the bundle returns, as `build <entry>`. Without it, a registry.     |
| `root`     | The source root in the repository, as `build --root`. The default is `lua`.    |
| `exclude`  | Globs to skip, as `build --exclude`.                                          |

"Newest stable tag" means the highest tag that parses as a version and has no
pre-release part, so `v0.10.0` is newer than `v0.2.0`, and `v0.11.0-rc1` is
skipped.

### How a dependency is built

A dependency is built exactly as `nvim-bundle build` would build it in a
checkout, with the entry's `entry`, `root`, and `exclude` as the arguments. So
the same rule applies: no `entry` means a registry. The dependency's own
`nvim-bundle.json` is never read, so any Lua repository can be vendored,
whether or not it uses nvim-bundle.

The default alias is the first segment of `entry`, else the one package under
the root. An example is `entry = "plenary.async"`, which vendors as
`vendor/plenary.lua`; `--as` picks another name.

## Manifest: `nvim-bundle.json`

```json
{
  "dependencies": {
    "args": { "entry": "args", "ref": "v0.1.0", "repo": "jrop/args.nvim" },
    "dep": "https://example.com/dep.nvim@main"
  },
  "name": "myplugin"
}
```

| Field          | Meaning                                                                    |
| -------------- | -------------------------------------------------------------------------- |
| `name`         | The module root, i.e., `lua/<name>/`. Inferred from `lua/` when missing.   |
| `dependencies` | Alias → [dependency](#dependencies). The alias names `vendor/<alias>.lua`. |

The commands rewrite the file with sorted keys and two-space indentation, so a
one-dependency change is a one-line diff.

## Lock file: `nvim-bundle.lock.json`

Each entry records what its dependency resolved to:

| Field                     | Meaning                                                        |
| ------------------------- | -------------------------------------------------------------- |
| `source`                  | The URL git cloned, such as `https://github.com/jrop/args.nvim`. |
| `ref`                     | The tag, branch, or SHA, as the manifest names it.             |
| `kind`                    | What `ref` turned out to be: `tag`, `branch`, or `rev`.        |
| `entry`, `root`, `exclude` | The build settings, copied from the manifest entry when it has them. |
| `commit`                  | The commit that was built, which `install` rebuilds to restore. |
| `built_with`              | The nvim-bundle version that built the bundle.                 |
| `sha256`                  | The hash of the vendored file's exact bytes.                   |

`lock_version` is `1`. Commit both files alongside `vendor/`.

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

The generated file defines a module table named `__mods` and returns either the
named module's value or, with no module, a registry table keyed by module id.

- Each module is stored as a function whose field name derives from the module
  id. For example, `myplugin.util` becomes `__mods._myplugin_util`.
- A resolved `require 'myplugin.util'` becomes a direct call to that function.
- A call the linker cannot resolve remains a host `require` call.
- A bundled module is evaluated at most once and caches its value.
- A require cycle raises `loop or previous error loading module '<name>'`.
- A bundle that returns a module evaluates that module, and only what it
  statically requires, when it is required. Installing `build myplugin`'s
  output as `lua/myplugin.lua` makes `require 'myplugin'` behave as it did for
  the source tree.
- A registry contains one loader per bundled module:

  ```lua
  local bundle = require 'myplugin'
  local myplugin = bundle['myplugin']()
  local core = bundle['myplugin.core']()
  ```

- The registry is lazy: creating it evaluates no modules, and calling a loader
  evaluates that module at most once. A loader returns the module's value as a
  static call would.
- A module with no return value yields `true`, exactly as `require` yields for
  the source, whether it is reached by a static call, a loader, or `require`
  on the bundle.
- Indexing the registry with a literal id lets the language server use the
  module's type. This is less ergonomic than a callable `bundle('id')`, but the
  call form would need a written return type for every module; see
  [When to choose a registry](explanation.md#when-to-choose-a-registry).
- In both shapes the bundle's modules are private: the host only caches the
  bundle itself under the bundle's name.
- The header records the shape as `-- returns: <entry>` or
  `-- returns: registry`.

With `--bin`, the file also starts with the shebang
`#!/usr/bin/env -S nvim --clean -l` and a modeline, and carries the executable
bit. The returned module decides whether it is the main script, so executing
the file runs its own `main` guard and requiring it returns its exports.

See [How static linking works](explanation.md#how-static-linking-works) for the
reason behind these rules.

## Programmatic API

### `NvimBundle.build(opts)`

```lua
local NvimBundle = require 'nvim-bundle'
local result = NvimBundle.build { entry = 'myplugin' }
```

`entry` names the returned module; leave it out for a registry. `root` defaults
to `lua`, `out` defaults as in [`build`](#build), and `exclude` defaults to an
empty list. Set `bin = true` to make the output executable, which needs
`entry`.

```lua
{
  out = 'dist/myplugin.lua',
  entry = 'myplugin',
  modules = 12,
}
```

`out` is the output path, `entry` is the returned module id (nil for a
registry), and `modules`
is the number of emitted modules. `build` raises on failure. The process
boundary around it is private; running the script or a `--bin` bundle is the
supported way to get the summary, error, and exit-status behavior.

## Validation

The bundler stops before writing a bundle when:

- The named module is not in the bundle, because no file maps to it or because
  it is excluded.
- `--bin` is given without a module.
- No module is named, no `--out` is given, and the root does not hold exactly
  one package.
- A module has a syntax error. The error names the source file.
- The Lua tree-sitter parser is unavailable.
- The output path is inside the source root.
- Two files map to the same module id.
- An `--exclude` glob is invalid.

Byte-order marks and shebangs are removed from module sources, and a missing
final newline is added.

## Project layout

- `README.md` — tutorial and documentation entry point.
- `lua/nvim-bundle.lua` — the CLI entry point and the public `build` API.
- `lua/nvim-bundle/build.lua` — the bundler core.
- `lua/nvim-bundle/deps.lua` — the `install`, `remove`, `update`, and
  `outdated` commands.
- `lua/nvim-bundle/git.lua` — the git commands that every dependency goes
  through.
- `lua/nvim-bundle/files.lua` — file and JSON I/O.
- `lua/nvim-bundle/version.lua` — the version a checkout reports.
- `lua/nvim-bundle/vendor/args.lua` — vendored args.nvim argument parser.
- `docs/how-to.md` — task-oriented guides.
- `docs/reference.md` — this reference.
- `docs/explanation.md` — design rationale and limitations.
- `spec/nvim-bundle_spec.lua` — black-box tests using temporary fixture trees.
- `library/busted/` — git submodule with type stubs for busted.
- `scripts/env.sh` — exports `PREFIX`, `VIMRUNTIME`, and the luarocks path.
- `dist/` — generated bundles; git-ignored.
