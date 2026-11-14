# TODO

## Deduplicate shared dependencies across bundles

A vendored dependency is a bundle with its own dependencies already linked in,
so a module that two bundles share is emitted once per bundle. An example of
this is args.nvim in nvim-bundle's own release:

1. nvim-bundle vendors args.nvim as `nvim-bundle.vendor.args`.
2. nvim-bundle also vendors guard, whose bundle links its own copy of
   args.nvim as `guard._vendor.args`.
3. So the release executable carries two copies of the same parser, and each
   copy keeps its own module cache.

The duplication is harmless today, because neither copy holds state that the
other must see. Deduplicating would require nvim-bundle to recognize that two
inlined modules are the same source at the same version, and to link both
module ids to one function. Any design must keep each bundle loadable on its
own, because a vendored file is placed and required independently.

## Drop modules that nothing requires

Dead-code removal deletes a `require` that can never run, but the module it
named is still emitted. An example of this is a development-only helper:

1. `if __DEV__ then require('myplugin.devtools').start() end` is the only use
   of `myplugin.devtools`.
2. With `--define '__DEV__=false'`, the branch and its `require` are removed.
3. So `myplugin.devtools` is emitted but can never load.

Dropping such a module would require finding every module reachable from the
entry through linked requires. A registry bundle has no entry, and a computed
`require(name)` can reach any module, so either case would keep every module.
