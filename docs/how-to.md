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

Copy `lua/nvim-bundle.lua` into the project that needs it, for example at
`scripts/nvim-bundle.lua`, and run it with `nvim --clean -l`. Keep the file
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
and call `run`:

```lua
local NvimBundle = require 'nvim-bundle'

local result = NvimBundle.run {
  'myplugin',
  '--root',
  'lua',
  '--out',
  'dist/myplugin.lua',
}

-- result = { out = 'dist/myplugin.lua', entry = 'myplugin', modules = 12 }
```

`run` raises on failure. `main` is the CLI wrapper: it prints the summary,
writes errors to stderr, and exits with status 1 on failure. See the
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
been pushed, and an authenticated `gh` CLI. Run the release task:

```sh
git tag v0.1.0
git push origin v0.1.0
mise run release
```

The task runs `mise run ci`, copies `lua/nvim-bundle.lua` to the extensionless
`nvim-bundle` asset, writes `nvim-bundle.sha256`, and creates the GitHub
release. The task refuses to publish when `HEAD` is not tagged, the tree is
dirty, or the remote tag does not exist.

This publishes a public release, so only a maintainer should run it.

## Troubleshoot a missing Lua parser

If the build stops with:

```text
nvim-bundle: Neovim Lua parser is required for static require resolution
```

use an official Neovim build, which includes the Lua parser, or install an
ABI-compatible Lua parser on the runtime path. The CLI runs with `--clean`, so
it does not load parsers from your user site directory.
