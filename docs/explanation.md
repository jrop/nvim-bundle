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

The generated file returns a registry keyed by module id. Each value is a lazy
loader that calls the module's function, so requiring the bundle evaluates no
module:

```lua
return {
  ['myplugin'] = function() return __mods._myplugin('myplugin') end,
  ['myplugin.util'] = function() return __mods._myplugin_util('myplugin.util') end,
}
```

Indexing the registry with a literal id lets the language server follow that
module's type. The registry itself is the only value the host's `require`
caches.

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
calls, the language server can follow nested modules. A consumer that indexes
the registry with a literal id sees that module's type, not `any`.

`pcall` and `xpcall` propagate the type as well. EmmyLua marks the value from
`pcall` as optional because the call can fail.

## Modules with no return value

Static calls are ordinary function calls, so a module with no return value
yields `nil` when its loader is called. The registry itself is always a table,
so requiring the bundle never triggers Lua's `nil -> true` normalization.

## Static linking versus runtime loaders

A runtime bundler installs a loader that resolves modules while the plugin
runs. `nvim-bundle` resolves modules at build time instead, in the same spirit
as a static linker or Rollup. The output has no runtime `require` searcher for
its own submodules, and resolved calls are direct function calls.

This design favors predictable output and type visibility. It also makes the
bundle's modules private: the host caches the registry under the bundle's name,
and the individual modules live only in the bundle's own cache. That is the
intended boundary, not a missing feature.

### Reaching a bundled module

The bundle returns a registry of lazy loaders, so a consumer reaches the entry
or a submodule by key:

```lua
local bundle = require 'img'
local entry = bundle['img']()
local placement = bundle['img.placement']()
```

The registry holds one lazy loader per bundled module, so it needs no extra
files and installs no host searcher. Calling a loader resolves that module
through the bundle's own map and caches it like a static call. Indexing with a
literal id lets the language server pick the loader and follow the module's
return type; a computed id cannot select one specific loader. The registry is
lazy because each entry is a function: creating it evaluates no modules, and
only the loader you call runs.

A callable bundle, such as `bundle('img.placement')`, would read more naturally.
EmmyLua can type that shape with `@overload`, but each overload has to name the
module's return type. The bundler does not know that name for an anonymous
module like `img.placement`, and the pinned EmmyLua does not support `typeof` to
refer to the inferred type. The registry instead leaves each thunk visible, so
the language server infers its return type from the loader body. That type
information is why the indexed form was chosen over the more ergonomic call
form.

The bundler is not a tree-shaker. It includes every `.lua` file below the
source root, minus excludes, whether or not the entry reaches it. This keeps
the module-id mapping predictable and avoids building a separate module graph,
at the cost of carrying unused files in the output.
