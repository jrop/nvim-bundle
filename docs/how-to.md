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
nvim --clean -l /path/to/nvim-bundle/lua/nvim-bundle.lua myplugin
```

The script is executable, so the direct form also works:

```sh
./lua/nvim-bundle.lua myplugin
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
nvim-bundle myplugin
```

With the default options, this scans `lua/`, uses `myplugin` as the entry
module, and writes `dist/myplugin.lua`. Load the generated file directly:

```lua
local myplugin = dofile('dist/myplugin.lua')
```

Or copy it into a `lua/` directory and load it with `require`:

```sh
mkdir -p ~/.local/share/nvim/site/lua
cp dist/myplugin.lua ~/.local/share/nvim/site/lua/myplugin.lua
```

To use a different entry, source root, or output path:

```sh
nvim-bundle entry --root src --out build/entry.lua
```

## Build an executable bundle

Pass `--bin` when the bundle is a program rather than a library. An example is
a command-line tool whose entry exports `main`:

```sh
nvim-bundle mycli --bin --out dist/mycli
./dist/mycli --help
```

The output starts with a shebang and a modeline, carries the executable bit,
and returns the entry module's value. The entry module must detect when it is
the main script, typically by comparing `debug.getinfo(1, 'S').source` with
`arg[0]`; the generated file does not add a second guard. Requiring the same
file returns the entry's exports without running its main path. A `--bin`
bundle does not return the module registry, so submodules are reachable only
through the entry's static requires.

## Exclude tests and vendor files

Repeat `--exclude` for each path pattern you want to skip:

```sh
nvim-bundle myplugin \
  --exclude '**/_test/**' \
  --exclude '**/vendor/**'
```

Patterns match both the path from the current directory and the path relative
to the source root, so `lua/vendor/**` and `vendor/**` select the same files.

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
| `mise run lint`          | Type-check with `emmylua_check`; warnings are errors.      |
| `mise run test`          | Run the busted suite against Neovim 0.12.6.                |
| `mise run test:all`      | Run the suite against 0.10.4, 0.11.7, 0.12.6, and nightly. |
| `mise run test:coverage` | Run the suite with luacov.                                 |
| `mise run ci`            | Run `fmt:check`, `lint`, and `test:all`.                   |

Run a single spec file after preparing the test dependencies:

```sh
mise run test:prepare
eval $(nvimv env 0.12.6)
busted spec/nvim-bundle_spec.lua
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

The task runs `mise run ci`, bundles `lua/` into `dist/nvim-bundle` with
`--bin`, and stamps the tag into the built file. The self-bundle inlines the
vendored argument parser, so the extensionless `nvim-bundle` asset stays a
single file while also being executable, and its `--version` names the release
even though a checkout reports the `VERSION` constant in `lua/nvim-bundle.lua`.
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
