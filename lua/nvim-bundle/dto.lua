--- The shapes of data that cross into nvim-bundle from outside: the manifest
--- and lock files, and the options a Lua caller passes to `build`. Each schema
--- both validates at runtime and, through guard's generator, produces the
--- LuaCATS class of the same name in `dto.types.lua`, so the checks and the
--- types cannot drift apart. Requires nothing but guard, because the generator
--- loads this file on its own.
local guard = require 'nvim-bundle.vendor.guard'

local M = {}

--- Each parse gets its own table, so mutating one manifest never changes another.
--- @return table
local function empty() return {} end

--- The fields that say how a dependency is built. They appear in the manifest,
--- in the lock, and in `build` options, so each schema copies them in.
--- @param fields table<string, guard.Guard<any>>
--- @return table<string, guard.Guard<any>>
local function with_build_settings(fields)
  return vim.tbl_extend('error', fields, {
    entry = guard.string():optional(),
    root = guard.string():optional(),
    exclude = guard.string():array():optional(),
  })
end

--- The settings alone, which `deps` compares between the manifest and the lock.
--- Nothing parses with it; it exists so its generated class can be named.
M.BuildSettings = guard.object(with_build_settings {})

M.RefKind = guard.literal('tag', 'branch', 'rev')

--- The object form of a manifest entry. It is strict, because a misspelled
--- setting would otherwise be dropped and the dependency built without it.
M.DependencyObject = guard.object(
  with_build_settings { repo = guard.string(), ref = guard.string():optional() },
  { strict = true }
)

--- A manifest entry: `repo[@ref]`, or an object when it has build settings.
--- `by_type` keeps an object entry with a bad setting from also being told
--- that it is not a string.
M.ManifestDependency = guard.by_type { string = guard.string(), table = M.DependencyObject }

--- Both sections vendor to `vendor/<alias>.lua`, so one alias in both would
--- name one file twice.
--- @param manifest nvim-bundle.dto.Manifest
--- @return boolean
local function has_disjoint_sections(manifest)
  for alias in pairs(manifest.dev_dependencies) do
    if manifest.dependencies[alias] then return false end
  end
  return true
end

--- Unknown top-level keys pass through, so a rewrite keeps whatever else the
--- user keeps in the file. Each section defaults to empty rather than being
--- optional, so no reader handles a nil that parsing already ruled out.
M.Manifest = guard
  .object({
    name = guard.string():optional(),
    dependencies = guard.record(guard.string(), M.ManifestDependency):default(empty),
    dev_dependencies = guard.record(guard.string(), M.ManifestDependency):default(empty),
  })
  :invariant(
    has_disjoint_sections,
    'An alias is listed in dependencies or dev_dependencies, not both'
  )

--- What one dependency resolved to. The lock is written by nvim-bundle, so an
--- unknown key means the file was edited or comes from another version.
M.LockEntry = guard.object(
  with_build_settings {
    source = guard.string(),
    ref = guard.string(),
    kind = M.RefKind,
    commit = guard.string(),
    built_with = guard.string(),
    sha256 = guard.string(),
  },
  { strict = true }
)

--- The version is checked, so a lock in a format this release does not know
--- is rejected rather than misread.
M.Lock = guard.object {
  lock_version = guard.literal(1),
  dependencies = guard.record(guard.string(), M.LockEntry):default(empty),
}

--- The define pass matches only a global name or a dotted path of plain
--- names, so a key of any other form could never match.
--- @param key string
--- @return boolean
local function is_dotted_name(key)
  for part in (key .. '.'):gmatch '(.-)%.' do
    if not part:match '^[%a_][%w_]*$' then return false end
  end
  return true
end

--- @param key string
--- @return boolean
local function is_unreserved(key)
  local root = key:match '^[^.]+'
  return root ~= 'require' and root ~= 'pcall' and root ~= 'xpcall'
end

--- A value replaces one expression on one line. `return v` rejects a value
--- that would leak past the expression, such as `x) (y`, and `return (v)`
--- rejects a list of values, such as `1, 2`.
--- @param value string
--- @return boolean
local function is_expression(value)
  if value:find '[\r\n]' then return false end
  return loadstring('return ' .. value) ~= nil and loadstring('return (' .. value .. ')') ~= nil
end

M.Define = guard.record(
  guard
    .string()
    :invariant(is_dotted_name, 'Expected a global name or a dotted path, such as vim.g.x')
    :invariant(is_unreserved, 'require, pcall, and xpcall cannot be defined'),
  guard.string():invariant(is_expression, 'Expected one Lua expression on one line')
)

--- Options for the public `build` API. Strict, so a misspelled option fails
--- instead of being silently ignored.
M.BuildOptions = guard.object(
  with_build_settings {
    out = guard.string():optional(),
    bin = guard.boolean():optional(),
    define = M.Define:optional(),
  },
  { strict = true }
)

--- Validate `value` against `schema`, or fail with every problem guard found.
--- These values come from the user, so the message names the file, not the
--- line of nvim-bundle that `parse` would blame.
--- @param schema guard.Guard<any>
--- @param value unknown
--- @param what string names the value in the error, such as a file name
--- @return any
function M.check(schema, value, what)
  local parsed, err = schema:try_parse(value)
  if err then error(('nvim-bundle: %s: %s'):format(what, err), 0) end
  return parsed
end

return M
