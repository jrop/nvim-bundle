--- The shapes of data that cross into nvim-bundle from outside: the manifest
--- and lock files, and the options a Lua caller passes to `build`. Each schema
--- both validates at runtime and, through guard's generator, produces the
--- LuaCATS class of the same name in `dto.types.lua`, so the checks and the
--- types cannot drift apart. Requires nothing but guard, because the generator
--- loads this file on its own.
local guard = require 'nvim-bundle.vendor.guard'

local M = {}

--- Choose one alternative by the input's Lua type, so a failure reports only
--- the shape the user was writing. A plain `one_of` reports every alternative:
--- an object entry with a bad `exclude` would also be told it is not a string.
--- The schema still says `one_of`, so the generator still emits a union.
--- @param alternatives table<type, Guard>
--- @return Guard
local function by_type(alternatives)
  -- Sorted, so the generated union reads the same on every run.
  local kinds = vim.tbl_keys(alternatives)
  table.sort(kinds)
  local guards = vim.tbl_map(function(kind) return alternatives[kind] end, kinds)
  local expected = 'Expected ' .. table.concat(kinds, ' or ')

  return guard.Guard.new({ type = 'one_of', guards = guards }, function(x)
    local chosen = alternatives[type(x)]
    if not chosen then return guard.err(x, guard.problem(expected, x)) end
    return chosen._parse(x)
  end)
end

--- Decode a missing value as `make()`. Wrapping with `:optional()` would make
--- the generated field optional, and then every reader would have to handle a
--- nil that validation has already ruled out.
--- @param inner Guard
--- @param make fun(): any
--- @return Guard
local function default(inner, make)
  return guard.Guard.new(inner._schema, function(x)
    if x == nil then return guard.ok(make()) end
    return inner._parse(x)
  end)
end

--- The fields that say how a dependency is built. They appear in the manifest,
--- in the lock, and in `build` options, so each schema copies them in.
--- @param fields table<string, Guard>
--- @return table<string, Guard>
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
M.ManifestDependency = by_type { string = guard.string(), table = M.DependencyObject }

--- Unknown top-level keys pass through, so a rewrite keeps whatever else the
--- user keeps in the file.
M.Manifest = guard.object {
  name = guard.string():optional(),
  dependencies = default(
    guard.record(guard.string(), M.ManifestDependency),
    function() return {} end
  ),
}

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
  dependencies = default(guard.record(guard.string(), M.LockEntry), function() return {} end),
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
--- `try_parse` is used because `parse` raises at level 2, which would prefix
--- the user-facing message with a source position.
--- @param schema Guard
--- @param value unknown
--- @param what string names the value in the error, such as a file name
--- @return any
function M.check(schema, value, what)
  local result = schema:try_parse(value)
  if result.ok then return result.value end
  -- emmylua does not narrow guard's generic result union on `ok`.
  --- @cast result guard.ParseError
  error(('nvim-bundle: %s: %s'):format(what, result:format()), 0)
end

return M
