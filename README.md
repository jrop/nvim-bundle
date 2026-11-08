# nvim-bundle

Statically link a Neovim plugin's Lua modules into one file.

`nvim-bundle` resolves `require 'literal'` calls at build time, so the generated
file calls bundled module functions directly. Module sources stay Lua code, so
LuaLS and EmmyLua annotations remain visible. Calls the linker cannot resolve
stay ordinary host `require` calls. The generated file exports a registry of
lazy module loaders keyed by module id.

## Requirements

- Neovim 0.10 or newer
- A LuaJIT-based Neovim (the default)
- Neovim's bundled Lua tree-sitter parser

Official builds include the Lua parser. A custom build with
`USE_BUNDLED_TS_PARSERS=OFF` needs an ABI-compatible parser on the runtime path.

## Install

With mise:

```sh
mise use -g \
  'github:jrop/nvim-bundle[asset_pattern=nvim-bundle,format=raw,bin=nvim-bundle]@0.1.0'
```

For release downloads, checksum verification, checkout runs, and vendored
installs, see [Install nvim-bundle](docs/how-to.md#install-nvim-bundle).

## Tutorial: build your first bundle

In this tutorial, we will create a small plugin, bundle it, and load the
generated file. We will use the `nvim-bundle` command from `PATH`.

1. Create a scratch plugin:

   ```sh
   mkdir -p demo-plugin/lua/demo
   cd demo-plugin

   cat > lua/demo/init.lua <<'EOF'
   local util = require 'demo.util'
   return { greet = util.greet }
   EOF

   cat > lua/demo/util.lua <<'EOF'
   local M = {}

   function M.greet(name)
     return 'hello, ' .. name
   end

   return M
   EOF
   ```

2. Bundle the entry module:

   ```sh
   nvim-bundle demo
   ```

   The output should look like:

   ```text
   bundled 2 modules into dist/demo.lua (entry demo)
   ```

3. Load the generated file in Neovim:

   ```sh
   nvim --clean --headless \
     +'lua local bundle = dofile("dist/demo.lua"); print(bundle["demo"]().greet("world"))' \
     +'qa!'
   ```

   Neovim prints:

   ```text
   hello, world
   ```

4. Open `dist/demo.lua`. Notice that the `require` in `demo/init.lua` became a
   direct call to the bundled `demo.util` module, and that the file contains one
   function per module. For why that shape preserves types and what stays
   dynamic, see
   [How static linking works](docs/explanation.md#how-static-linking-works).

   The generated file returns a registry keyed by module id. Each value is a
   lazy loader, so a literal key preserves that module's type:

   ```lua
   local bundle = require 'demo'
   local demo = bundle['demo']()
   local util = bundle['demo.util']()
   ```

   Calling a loader evaluates that module at most once, like a static
   `require`.

We have built a bundle from two modules and loaded it without installing the
plugin.

For a command-line tool, pass `--bin` to produce an executable instead of a
library bundle. It adds a shebang, sets the executable bit, and returns the
entry module. See
[Build an executable bundle](docs/how-to.md#build-an-executable-bundle).

## Documentation

| I want to...                                                        | Read                               |
| ------------------------------------------------------------------- | ---------------------------------- |
| Bundle a plugin, build an executable, or use the Lua API            | [How-to guides](docs/how-to.md)    |
| Look up commands, options, module ids, or errors                    | [Reference](docs/reference.md)     |
| Understand static linking, executable bundles, and type propagation | [Explanation](docs/explanation.md) |

## License

MIT License

Copyright (c) 2026 Jonathan Apodaca

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
