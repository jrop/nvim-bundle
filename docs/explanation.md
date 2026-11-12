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
protected and gives the language server a function whose return type it can
infer.

Each module is evaluated at most once, by one generic `__load` function that
plays the part of `package.loaded`. The generic is what keeps types intact: a
cache the type checker sees assigned only after its first read looks empty, so
every `require` of the bundle would look like it might return `nil`. The
loader's `fun(...): T` parameter instead hands each module's own return type
back to the caller. A require cycle raises
`loop or previous error loading module '<name>'` instead of recursing forever.

The file's last line decides what requiring it returns. Naming a module ends
the file with a call to that module's function, so the bundle behaves like
`require` on the source:

```lua
return __mods._myplugin('myplugin')
```

Naming none ends it with a registry, a table of lazy loaders, so requiring the
bundle evaluates no module:

```lua
return {
  ['myplugin'] = function() return __mods._myplugin('myplugin') end,
  ['myplugin.util'] = function() return __mods._myplugin_util('myplugin.util') end,
}
```

Either way, the language server follows the returned call or the indexed
loader to the module's type, and the bundle itself is the only value the
host's `require` caches.

### Field names

Each module's function name derives from its module id. Dots and other
non-identifier characters become underscores, and every name gets a leading
underscore, so `myplugin.util` becomes `_myplugin_util`. The prefix keeps names
valid even when the module id is a Lua keyword or starts with a digit. Names
that still collide gain a numeric suffix.

## Executable bundles

An executable bundle should behave like its entry source: requiring it returns
the entry's exports, and running it invokes the entry's main behavior. A named
module already gives the first half, so `--bin` only adds the shebang and the
executable bit, and it refuses to build a registry, which has no main behavior
to run.

An example is nvim-bundle's own entry. Its source computes `running_as_main`
with `is_main`, which compares the chunk that defined it with `arg[0]`, and its
final block runs the CLI only when that value is true. In a `--bin` bundle the
entry's chunk is the bundle file, so executing the bundle makes the comparison
true and runs the CLI; a plugin that requires the same file makes `arg[0]` its
own script, so the comparison is false and `require` returns the module table.

The bundler deliberately does not generate its own `is_main` guard. A generated
guard would call the entry unconditionally, which evaluates the entry on
library require and duplicates the entry's own check. Keeping the check in the
entry means one implementation and one place to change.

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
calls, the language server can follow nested modules. A consumer of a returned
module, or of a registry indexed with a literal id, sees that module's type,
not `any`.

`pcall` and `xpcall` can propagate the type as well, but EmmyLua does not do
so reliably: `emmylua_check` 0.25.1 infers the module's type through `pcall` in
only about half its runs, and reports `unknown` in the rest.

## Modules with no return value

A module with no return value yields `true`, because that is what `require`
yields for it. The loader caches `true` in its place, the same way
`package.loaded` does, so a static call, a registry loader, and `require` on
the bundle all agree with `require` on the source.

## Static linking versus runtime loaders

A runtime bundler installs a loader that resolves modules while the plugin
runs. `nvim-bundle` resolves modules at build time instead, in the same spirit
as a static linker or Rollup. The output has no runtime `require` searcher for
its own submodules, and resolved calls are direct function calls.

This design favors predictable output and type visibility. It also makes the
bundle's modules private: the host caches the bundle under its own name, and
the individual modules live only in the bundle's own cache. That is the
intended boundary, not a missing feature.

### When to choose a registry

Name a module when the bundle replaces one package's `require`: a plugin
shipped as one file, a vendored dependency, or an executable. Choose a
registry when consumers pick among several entry points, because the registry
is the only shape that exposes more than one module. A consumer reaches each
module by key:

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

## Vendoring dependencies as bundles

A vendored dependency is one bundle file, not a copied source tree, because a
bundle stays correct wherever it is placed. An example of this is `args.nvim`,
whose modules `require 'args.util'` internally:

1. Copied as a tree to `lua/myplugin/vendor/args/`, the module would now be
   `myplugin.vendor.args.util`.
2. So every internal `require 'args.util'` would miss, unless each one were
   rewritten.
3. A bundle has already linked those requires statically, so the file can sit
   at any path and still load.

The dependency's own `vendor/` is linked into its bundle the same way, so a
consumer never resolves transitive dependencies.

### Why every dependency is built from source

A dependency is fetched with git and built by the consumer, because git is the
one source of truth that every plugin already has. An example is a plugin with
tags but no release assets: it can be vendored as soon as it has a `lua/`
directory, without its author adopting any publishing convention. So there is
one way to get a dependency, it works on any host git can reach, and it uses the
user's own git credentials rather than an API token. The vendored bytes also
come from a commit anyone can read, rather than from an uploaded file.

### Why `install` takes `build`'s arguments

Vendoring a repository produces exactly what `nvim-bundle build` would produce
in a checkout of it, with the consumer's arguments. An example is
`install jrop/args.nvim@v0.1.0 args`, which bundles like `build args` and so
returns `args`, while `install jrop/args.nvim@v0.1.0` bundles like `build` and
so returns a registry. So there is one rule for what a bundle returns, and one
set of options, whichever command builds it.

The consumer decides, not the dependency's author: the dependency's own
`nvim-bundle.json` is never read. That is because the consumer is the one who
writes the `require`, so the consumer knows which module it wants back. It also
means a dependency needs no nvim-bundle configuration of its own to be
vendored.

### Why the manifest and the lock are separate

The manifest records what you asked for, and the lock records what that request
resolved to. An example is editing `@v0.1.0` to `@v0.2.0` in
`nvim-bundle.json`: the lock then names a different tag, so `install` knows to
resolve that one entry again, while every other entry is left alone.

The lock records the commit that was built and the file's `sha256`. So a
missing file is restored by rebuilding that commit, not the tag or branch, and a
moved tag or an advanced branch cannot change what comes back. When every hash
already matches, `install` runs no git command at all, which keeps
`install --frozen` in CI fast and offline.

### Why the lock records `built_with`

A dependency is built on your machine, so its hash only means something if a
build is reproducible. Discovery sorts its files, and the bundle records no
path, so the same commit produces the same bytes from any temporary directory.
A newer nvim-bundle may still emit slightly different bytes, so the lock
records the version that built them. A restore that fails its hash check then
names both versions, rather than reporting a bare mismatch.

## Dogfooding the argument parser

nvim-bundle parses its own command line with a vendored copy of args.nvim, and
the release task builds nvim-bundle with nvim-bundle. An example is the release
asset: the task runs the checkout's own `lua/nvim-bundle.lua` over `lua/` with
`--bin`, then stamps the tag into the built file. The `--bin` output inlines the
vendored module, so the published asset remains one file even though the source
tree now contains a `require`.

A source checkout needs one small bootstrap. An example is running
`lua/nvim-bundle.lua` directly: Neovim does not put the script's sibling `lua/`
directory on `package.path`, so the script prepends that directory before
requiring the vendored module. The bootstrap fires only when the script is the
main chunk and the vendor file exists, so a required bundle leaves the host's
`package.path` alone.
