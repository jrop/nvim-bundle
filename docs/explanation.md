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

### Why libraries see an empty `arg`

A bundle should give each module the answer that `require` would give it when
the module asks whether it is the main script. Under `require`, a library sees
the same global `arg` as the script, but its own source path differs from
`arg[0]`, so its check is false. In a bundle that difference is gone. An
example of this is guard, which nvim-bundle vendors and which has its own CLI:

1. Every bundled module is defined in the bundle file, so
   `debug.getinfo(1, 'S').source` names the bundle for each of them.
2. Executing the bundle makes the bundle file `arg[0]`.
3. So guard's `is_main` compares two equal paths, and guard would run its CLI
   on nvim-bundle's arguments before nvim-bundle's own `main` ran.

The bundle cannot make the source paths differ again, so it changes the other
side of the comparison instead. Every module except the returned one begins
with `local arg = {}`, and in a registry every module does:

- The local shadows the global lexically, so it also covers a check made after
  the module loads, and it reaches every module of a nested bundle. The
  vendored guard is itself a bundle whose entry keeps the `arg` around it, so
  that entry sees nvim-bundle's empty table.
- An empty table is what plain plugin code sees in Neovim without `-l`, so
  every Neovim library already handles it: `arg[0]` is nil, and a main guard
  that reads it is false. `nil` would instead crash a library that indexes
  `arg` without checking, because Neovim itself never leaves `arg` unset.
- Each module gets its own table, so one library that writes to `arg` cannot
  affect another.

This choice has costs, and one of them is not specific to `arg`:

- A library that reads the script's arguments from the global `arg[1..]` gets
  nothing in a bundle. Argument parsers such as args.nvim take `argv` as a
  parameter, so this affects only a library that already behaves like the
  script.
- `debug.getinfo` is not preserved. Every bundled frame reports the bundle file
  as its source, with line numbers in the bundle, and that also holds for
  tracebacks and error positions. A library that finds its own files relative
  to its source path, for example `vim.fs.dirname(info.source:sub(2))`, finds
  the bundle's directory instead.

The alternatives were rejected because they preserve less or cost more:

- Giving each module a replacement `debug` that reports the module's original
  path would only be correct for the module's own frame. Every other frame
  would still report the bundle, and checks that do not use `debug.getinfo`
  would still be wrong.
- Swapping the global `arg` while a library loads would miss a check made
  after loading. It would also need care to restore `arg` when loading fails,
  and other code could see the swapped global in the meantime.
- Loading each module as its own chunk with its original name would preserve
  `debug.getinfo` exactly. That needs sources stored as strings, which would
  hide their annotations from the language server.

## Why some requires stay dynamic

Some calls cannot be resolved safely at build time. Those calls keep using the
host's `require`, and their values are typed as `any`:

- A computed module name, such as `require(name)`.
- A `require`, `pcall`, or `xpcall` that the module shadows or aliases.
- A module excluded with `--exclude`.
- A module outside the source root.
- A module that the Lua parser cannot parse.

Those calls are external to the bundle. If the generated file is installed as
`lua/myplugin.lua`, a computed `require 'myplugin.util'` does not reach the
bundled copy.

## Source transforms

Every bundled module passes through a short pipeline of transforms before it
is emitted. Each transform, called a pass, takes the module's syntax tree and
returns a new one. The passes are `--define`, dead-code removal, and linking
requires, in that order.

### Why a pass edits text

A tree-sitter tree is a read-only view of its source text, so a pass changes
the text and the tree is parsed again. An example of this is the require
pass, which turns one call into another:

1. The pass finds `require 'myplugin.util'` with a query, i.e., as a node with
   a byte range.
2. It replaces the text in that range with `__mods._myplugin_util("myplugin.util")`.
3. The pipeline parses the new text, so the next pass sees the call it will
   actually emit.

Editing text keeps everything outside the replaced ranges exactly as written:
comments, whitespace, and the `---@` annotations that the language server
reads. A transform that printed code back from a tree would have to work to
preserve them.

### Why every replacement keeps its line count

The bundle keeps each module's lines where the source has them, so an error's
line in the bundle, minus the line where the module begins, is the line in the
source. A pass may still shorten a construct that spans several lines. An
example of this is a `require` call that a formatter split:

1. `require(\n  'dep'\n)` spans three lines, and its replacement
   `__mods._dep("dep")` spans one.
2. So the pipeline puts the two missing line breaks before the replacement,
   i.e., `\n\n__mods._dep("dep")`.
3. The text after the call stays on the line where it was, so every later line
   keeps its number.

The breaks go before the replacement, because a break before an expression is
always valid Lua. A break after one is not: `("x")` followed by a line that
starts with `(1)` would read as a call. A pass that produces more lines than it
replaces has a bug, so the build fails rather than shift the lines.

Shortening a construct is safer than skipping it. A skipped `require` would
stay a host require, which a vendored bundle usually cannot resolve, and a
skipped define would keep the value the build meant to replace.

### Why some values start with `;`

A replacement that starts with `(` can join the line before it. An example of
this is a statement that starts with a defined key:

1. `vim.g.env:upper()` follows `local s = tostring` on the line before.
2. The replacement `("prod"):upper()` makes the two lines read as the call
   `tostring("prod")`, which LuaJIT rejects as ambiguous syntax.
3. So the pipeline writes `;("prod"):upper()`, and the `;` ends the previous
   statement first.

The `;` is added only when another statement precedes the one the
replacement starts, skipping comments, because LuaJIT rejects `;` as the
first statement of a block. Nothing precedes that first statement for the `(`
to join.

### Why the passes run in order

Each pass sees the text that the previous pass produced, so each one builds
on the passes before it. An example of this is a development-only branch:

1. `--define '__DEV__=false'` turns `if __DEV__ then` into `if false then`.
2. Dead-code removal sees the literal `false`, so it removes the branch.
3. The require pass runs last, so a `require` inside the removed branch is
   never linked.

The same order links a define value that contains `require 'dep'`. It is also
why a defined value is inserted without parentheses wherever the syntax allows
it: dead-code removal reads the literal itself.

### Why `--define` replaces expressions

A define replaces reads of a name, rather than a whole module, because that is
what dead-code removal builds on. The rules follow from what a read
is:

- Strings, comments, table keys, and field names contain the key's text, but
  they do not read the variable, so they are left alone.
- A module that declares the key's first name, for example
  `local __DEV__ = true`, reads its own variable there. Telling those reads
  apart from reads of the global needs scope analysis, so the module keeps
  all of them, as a module that shadows `require` keeps all of its requires.
- A module that assigns a defined key contradicts the define, because the
  build fixes a value the code means to change. So the build fails rather
  than guess which one should win.
- A key that matches nothing is not an error, because one set of defines
  commonly serves modules that use only some of them.

Defines apply to vendored bundles too, because a vendored bundle is one more
module in the source tree. That matches how a global setting such as
`__DEV__` is usually meant.

### How dead-code removal stays safe

Dead-code removal deletes only a branch that can never run, and it never
changes what the kept code does. So it runs on every build, and no option
turns it off. A branch can never run only when its condition has a fixed
value, which means the condition is built from literals alone:

- `true`, `false`, `nil`, numbers, and strings qualify. `true`, `false`, and
  `nil` are keywords, so no module can shadow them.
- `not`, `==`, `~=`, and parentheses over fixed values qualify.
- `false and f()` and `true or f()` qualify, because the right side never
  runs.
- A variable, a call, or a table constructor does not qualify, because
  evaluating it could have side effects or depend on the program.

A kept branch becomes a `do ... end` block rather than bare statements. An
example of this is `if true then local x = 1; return x end`:

1. Unwrapped, `local x` would reach the code after the statement, and might
   shadow a name there.
2. Unwrapped, `return x` would be followed by more statements, which Lua
   rejects.
3. As `do local x = 1; return x end`, both behave as they did inside the
   branch, and so do labels.

A statement that is removed whole becomes `do end` rather than nothing. Its
neighbors would otherwise meet: a line that starts with `(` would continue the
expression on the line before the removed statement, as the `;` rule above
describes. `do end` is a statement that no expression can absorb. Every removed
part is padded with line breaks like any other replacement, so the lines after
it keep their numbers.

A removed `require` no longer runs, but its module is still bundled, because
nvim-bundle does not drop unused modules. See [`TODO.md`](../TODO.md).

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

Shared dependencies are not deduplicated: a module that two bundles both link
is emitted once in each. An example of this is nvim-bundle itself, which
vendors args.nvim and also vendors guard, whose bundle links its own copy of
args.nvim. So the release carries the parser twice, and each copy has its own
module cache. See [`TODO.md`](../TODO.md) for what deduplicating would need.

### Why the manifest and the lock are validated on load

Every command trusts the manifest and lock values it reads, so both files are
checked against a schema before any command uses them. An example of this is
an object entry whose `exclude` is a string:

1. Without a check, `build` would receive the string where it expects a list.
2. The failure would then surface far from its cause, as an error about globs.
3. With the check, the command stops at load time and names the field, i.e.,
   `` `.dependencies["dep"].exclude`: Expected array ``.

The schemas live in `lua/nvim-bundle/dto.lua` and are written with guard. guard
also generates LuaCATS classes from the same schemas, so the shapes that are
validated are exactly the shapes the type checker sees. The generated
`dto.types.lua` is a build artifact; `mise run generate` creates it.

The schemas describe only what is in the files. Splitting `repo@ref` and
choosing a clone URL stay in `deps.lua`, because they turn a valid entry into a
dependency rather than decide whether the entry is valid.

### Why every dependency is built from source

A dependency is fetched with git and built by the consumer, because git is the
one source of truth that every plugin already has. An example is a plugin with
tags but no release assets: it can be vendored as soon as it has a `lua/`
directory, without its author adopting any publishing convention. So there is
one way to get a dependency, it works on any host git can reach, and it uses the
user's own git credentials rather than an API token. The vendored bytes also
come from a commit anyone can read, rather than from an uploaded file.

### Why vendored files silence their diagnostics

A diagnostic should be reported where someone can fix it, and a vendored file
is not that place. An example of this is a type warning inside guard's code in
`vendor/guard.lua`:

1. The file is generated, and `install` would overwrite a local fix.
2. So the only real fix is upstream, in guard's own repository.
3. In the consuming project, the warning can only fail its lint.

So every vendored file begins with `---@diagnostic disable`. The comment
silences only the file's own diagnostics: code that calls into it is still
checked against its types. An option to turn it off would change the vendored
bytes, so it would need a place in the manifest and the lock, and no consumer
has needed it.

Ignoring the directory instead would not work with emmylua_check. Its
`--ignore`, `ignoreDir`, and `ignoreGlobs` settings also drop the files from
analysis, so a module that uses a vendored dependency's types would no longer
find them.

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
`--bin`, and `--define` sets the version it reports. The `--bin` output inlines the
vendored module, so the published asset remains one file even though the source
tree now contains a `require`.

A source checkout needs one small bootstrap. An example is running
`lua/nvim-bundle.lua` directly: Neovim does not put the script's sibling `lua/`
directory on `package.path`, so the script prepends that directory before
requiring the vendored module. The bootstrap fires only when the script is the
main chunk and the vendor file exists, so a required bundle leaves the host's
`package.path` alone.
