# How-to guides

These guides show how to accomplish a specific task. They assume you know what
you want to do. If you are new to nvim-bundle, start with the
[tutorial](../README.md#tutorial-build-your-first-bundle). For commands and
options, see the [reference](reference.md). For background, see the
[explanation](explanation.md).

## Install nvim-bundle

### With mise

```sh
mise use -g \
  'github:jrop/nvim-bundle[asset_pattern=nvim-bundle,format=raw,bin=nvim-bundle]@0.1.0'
```

Or pin it in `mise.toml`:

```toml
[tools."github:jrop/nvim-bundle"]
version = "0.1.0"
asset_pattern = "nvim-bundle"
format = "raw"
bin = "nvim-bundle"
```

mise verifies the asset and puts `nvim-bundle` on `PATH`.

### From a GitHub release

Download the executable and its checksum, verify the checksum, and install it:

```sh
version=v0.1.0
base="https://github.com/jrop/nvim-bundle/releases/download/$version"
curl -fsSLo nvim-bundle "$base/nvim-bundle"
curl -fsSLo nvim-bundle.sha256 "$base/nvim-bundle.sha256"
sha256sum -c nvim-bundle.sha256   # or: shasum -a 256 -c nvim-bundle.sha256
install -m 755 nvim-bundle ~/.local/bin/nvim-bundle
```

The asset has no `.lua` extension. It carries a modeline, so it still uses Lua
syntax highlighting when you open it in Neovim.

### From a checkout

A checkout runs directly through Neovim:

```sh
git clone https://github.com/jrop/nvim-bundle
cd nvim-bundle
nvim --clean -l lua/nvim-bundle.lua --help
```

For development, initialize the type-stub submodule as described in
[Develop nvim-bundle](#develop-nvim-bundle).

To bundle another project from a checkout, point Neovim at the script:

```sh
nvim --clean -l /path/to/nvim-bundle/lua/nvim-bundle.lua build myplugin
```

The script is executable, so the direct form also works:

```sh
./lua/nvim-bundle.lua build myplugin
```

### As a vendored file

Copy `lua/nvim-bundle.lua` and the `lua/nvim-bundle/` directory into the
project that needs them, preserving their relative layout. The directory holds
the vendored argument parser that the entry requires. Run the entry with
`nvim --clean -l`, or build a self-contained executable as described in
[Build an executable bundle](#build-an-executable-bundle). Keep the files
outside the source root, because every `.lua` file below the source root is
bundled.

## Bundle a plugin

From the root of the plugin you want to bundle:

```sh
nvim-bundle build myplugin
```

With the default options, this scans `lua/` and writes `dist/myplugin.lua`,
which returns `myplugin`'s value. Load the generated file directly:

```lua
local myplugin = dofile('dist/myplugin.lua')
```

Or copy it into a `lua/` directory and load it with `require`:

```sh
mkdir -p ~/.local/share/nvim/site/lua
cp dist/myplugin.lua ~/.local/share/nvim/site/lua/myplugin.lua
```

To use a different module, source root, or output path:

```sh
nvim-bundle build entry --root src --out build/entry.lua
```

## Bundle a library with several entry points

Leave out the module name:

```sh
nvim-bundle build
```

The output is named after the one package under `lua/`, such as
`dist/myplugin.lua`, and returns a registry with one lazy loader per module.
Index it with a literal module id, so the language server keeps that module's
type:

```lua
local bundle = require 'myplugin'
local core = bundle['myplugin.core']()
```

Pass `--out` when `lua/` holds more than one package.

## Build an executable bundle

Pass `--bin` when the bundle is a program rather than a library. An example is
a command-line tool whose entry exports `main`:

```sh
nvim-bundle build mycli --bin --out dist/mycli
./dist/mycli --help
```

The output starts with a shebang and a modeline, carries the executable bit,
and returns the entry module's value. The entry module must detect when it is
the main script, typically by comparing `debug.getinfo(1, 'S').source` with
`arg[0]`; the generated file does not add a second guard. Requiring the same
file returns the entry's exports without running its main path.

## Exclude tests and vendor files

Repeat `--exclude` for each path pattern you want to skip:

```sh
nvim-bundle build myplugin \
  --exclude '**/_test/**' \
  --exclude '**/vendor/**'
```

Patterns match both the path from the current directory and the path relative
to the source root, so `lua/vendor/**` and `vendor/**` select the same files.

## Set build-time values

Read a setting through a name that is safe when nothing defines it, and define
it when you build. `vim.g` suits this, because an unset key reads as `nil`:

```lua
-- lua/myplugin/env.lua
return vim.g.myplugin_env or 'development'
```

```sh
nvim-bundle build myplugin --define 'vim.g.myplugin_env="production"'
```

The source keeps working unbundled, where the module returns `'development'`,
and the bundle contains `return "production" or 'development'`. A branch on a
defined value is removed from the bundle when it can never run:

```lua
if vim.g.myplugin_env == 'production' then
  -- kept, as a `do ... end` block
else
  -- removed from the bundle
end
```
 The value is
Lua code, so a string needs its own quotes. See
[Defines](reference.md#defines) for every rule.

## Use the bundler from Lua

When the repository's `lua/` directory is on `package.path`, require the module
and call `build`:

```lua
local NvimBundle = require 'nvim-bundle'

local result = NvimBundle.build {
  entry = 'myplugin',
  root = 'lua',
  out = 'dist/myplugin.lua',
}

-- result = {
--   out = 'dist/myplugin.lua',
--   entry = 'myplugin',
--   modules = 12,
-- }
```

`build` raises on failure. The process boundary around it is private; the
script and `--bin` bundles are the supported ways to get the printed summary,
stderr errors, and exit status 1 on failure. See the
[Programmatic API](reference.md#programmatic-api).

## Vendor a dependency

Install a dependency from a tag of its repository, naming the module you want
it to return:

```sh
nvim-bundle install jrop/args.nvim@v0.1.0 args
```

nvim-bundle clones the tag, builds it as `nvim-bundle build args`, and writes
the bundle to `lua/<name>/vendor/args.lua`, so your code loads it with:

```lua
local args = require 'myplugin.vendor.args'
```

Leave out the module to vendor a registry of every module in the dependency
instead; see [When to choose a registry](explanation.md#when-to-choose-a-registry).

`owner/repo` is shorthand for a GitHub repository. Any other host takes its git
URL, such as `https://codeberg.org/owner/dep.nvim@v1.0.0`. Pass `--as <alias>`
to choose a different file name, and `--force` to replace a file already in
`vendor/` that nvim-bundle did not write. Commit `vendor/`, `nvim-bundle.json`,
and `nvim-bundle.lock.json` together.

## Vendor an untagged repository

Name a branch after the `@` to follow it, or a full commit SHA to pin it:

```sh
nvim-bundle install owner/dep.nvim@main
nvim-bundle install owner/dep.nvim@3f9c2e1d4b6a8c0e2f4a6b8d0c2e4f6a8b0d2c4e
```

`update` moves a branch to its current head, and leaves a SHA where it is.

When the repository keeps its modules outside `lua/`, or ships files you don't
want, pass the same options `build` takes:

```sh
nvim-bundle install owner/dep.nvim@main dep --root src --exclude '**/_test/**'
```

`nvim-bundle.json` records them, so a later `nvim-bundle install` builds the
dependency the same way.

## Keep vendored files in sync in CI

Run a frozen install before the tests:

```sh
nvim-bundle install --frozen
```

It exits with status 1 and names each dependency that would be resolved,
restored, or removed, i.e., any vendored file that drifted from the lock.
Without `--frozen`, the same command repairs `vendor/` instead.

## Update dependencies

List what has a newer stable tag or branch head, then move to it:

```sh
nvim-bundle outdated
nvim-bundle update          # every dependency
nvim-bundle update args     # one dependency
```

`update` rewrites the tags in `nvim-bundle.json`, and branch commits in the
lock, so review the diff like any
other dependency bump. To drop a dependency, run `nvim-bundle remove args`.

## Develop nvim-bundle

Install the pinned tools and initialize the type-stub submodule:

```sh
mise install
git submodule update --init --recursive
```

Run the checks:

| Command                  | Purpose                                                    |
| ------------------------ | ---------------------------------------------------------- |
| `mise run fmt`           | Format Lua sources with stylua.                            |
| `mise run fmt:check`     | Check formatting without changing files.                   |
| `mise run generate`      | Generate `dto.types.lua` when `dto.lua` is newer.          |
| `mise run lint`          | Generate types, then type-check; warnings are errors.      |
| `mise run test`          | Run the busted suite against Neovim 0.12.6.                |
| `mise run test:version`  | Run the suite against one Neovim version, e.g. `0.10.4`.   |
| `mise run test:all`      | Run the suite against 0.10.4, 0.11.7, 0.12.6, and nightly. |
| `mise run test:fast`     | Run the suite without preparing test dependencies.         |
| `mise run test:coverage` | Run the suite with luacov.                                 |
| `mise run ci`            | Run `fmt:check`, `lint`, and `test:all`.                   |

Run a single spec file after preparing the test dependencies:

```sh
mise run test:prepare
eval "$(luarocks path)"
busted spec/define_spec.lua
```

## Publish a release

Publishing requires a clean working tree, a `v*` tag at `HEAD` that has already
been pushed, and an authenticated `gh` CLI. Create the tag and run the release
task:

```sh
git tag v0.1.0
git push origin v0.1.0
mise run release
```

The task runs `mise run ci` and bundles `lua/` into `dist/nvim-bundle` with
`--bin`. It passes `--define "vim.g.nvim_bundle_version='<tag>'"`, so the
asset's `--version` names the release, while a checkout reports the fallback in
`lua/nvim-bundle/version.lua`. The self-bundle inlines the vendored argument
parser, so the extensionless `nvim-bundle` asset stays a single file while also
being executable.
The task writes `nvim-bundle.sha256` and creates the GitHub release. It refuses
to publish when `HEAD` is not tagged, the tree is dirty, or the remote tag does
not exist.

This publishes a public release, so only a maintainer should run it.

## Troubleshoot a missing Lua parser

If the build stops with:

```text
nvim-bundle: Neovim Lua parser is required for static require resolution
```

use an official Neovim build, which includes the Lua parser, or install an
ABI-compatible Lua parser on the runtime path. The CLI runs with `--clean`, so
it does not load parsers from your user site directory.
