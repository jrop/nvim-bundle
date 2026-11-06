# Explanation

Background on how nvim-bundle works, why it is shaped this way, and what that
means for your plugin.

## How static linking works

`nvim-bundle` parses each module with Neovim's Lua tree-sitter parser. When a
`require` argument is a string literal that names a bundled module, the bundler
rewrites the call at build time to call the module's function directly. An
example is an entry that requires a submodule:

```lua
-- source: lua/myplugin.lua
local util = require 'myplugin.util'
return { util = util }
```

The generated bundle contains:

```lua
local util = __mods._myplugin_util("myplugin.util")
```

Because the rewritten call is a direct function call, the language server can
follow the submodule's return type. The bundle does not install a runtime
searcher or a private loader for its submodules.

`pcall(require, 'x')` and `xpcall(require, handler, 'x')` are resolved too. The
`require` argument becomes a forwarding function, which keeps the call
protected and lets the language server infer the module's return type through
`pcall`.

Each module is evaluated at most once. Its value is cached in a block-local
upvalue, and a require cycle raises
`loop or previous error loading module '<name>'` instead of recursing forever.

### Field names

Each module's function name derives from its module id. Dots and other
non-identifier characters become underscores, and every name gets a leading
underscore, so `myplugin.util` becomes `_myplugin_util`. The prefix keeps names
valid even when the module id is a Lua keyword or starts with a digit. Names
that still collide gain a numeric suffix.

## Why some requires stay dynamic

Some calls cannot be resolved safely at build time. Those calls keep using the
host's `require`, and their values are typed as `any`:

- A computed module name, such as `require(name)`.
- A `require`, `pcall`, or `xpcall` that the module shadows or aliases.
- A multi-line `require`. Rewriting it would shift the generated file's line
  numbers, so it is left alone.
- A module excluded with `--exclude`.
- A module outside the source root.
- A module that the Lua parser cannot parse.

Those calls are external to the bundle. If the generated file is installed as
`lua/myplugin.lua`, a computed `require 'myplugin.util'` does not reach the
bundled copy.

## Why type information survives

Module sources are emitted as Lua code, not as strings. Their annotations stay
visible to LuaLS and EmmyLua, and because resolvable requires become direct
calls, the language server can follow nested modules. A consumer that requires
the bundle sees the submodule's type, not `any`.

`pcall` and `xpcall` propagate the type as well. EmmyLua marks the value from
`pcall` as optional because the call can fail.

## Modules with no return value

Static calls are ordinary function calls, so a module with no return value
yields `nil` when called statically. When the bundle's entry itself returns
`nil`, the host's `require` still follows Lua's `nil -> true` normalization.

## Static linking versus runtime loaders

A runtime bundler installs a loader that resolves modules while the plugin
runs. `nvim-bundle` resolves modules at build time instead, in the same spirit
as a static linker or Rollup. The output has no runtime `require` searcher for
its own submodules, and resolved calls are direct function calls.

This design favors predictable output and type visibility. It also makes
bundled submodules private: only the entry participates in the host's module
cache. That is the intended boundary, not a missing feature.

The bundler is not a tree-shaker. It includes every `.lua` file below the
source root, minus excludes, whether or not the entry reaches it. This keeps
the module-id mapping predictable and avoids building a separate module graph,
at the cost of carrying unused files in the output.
