--- Link each static `require` of a bundled module to its `__mods` function.
--- Calls that cannot be resolved here stay host requires.

local REQUIRE_CALLS = [[
  ((function_call
    name: (identifier) @fn
    arguments: (arguments
      (string) @module) @args) @call
   (#eq? @fn "require"))
]]

local PROTECTED_CALLS = [[
  ((function_call
    name: (identifier) @fn
    arguments: (arguments) @args) @call
   (#any-of? @fn "pcall" "xpcall"))
]]

local GLOBALS = [[
  ((identifier) @id
   (#any-of? @id "require" "pcall" "xpcall"))
]]

--- A `require`, `pcall`, or `xpcall` identifier is safe to leave in place only
--- when it refers to the global function. Any other position means the module
--- binds or aliases the name.
--- @param tree nvim-bundle.transform.Tree
--- @param node TSNode
--- @return boolean
local function is_allowed_global(tree, node)
  local parent = node:parent()
  if not parent then return false end

  if parent:type() == 'function_call' then
    local name = parent:field('name')[1]
    if name and name:equal(node) then return true end
  end

  if tree:text(node) ~= 'require' or parent:type() ~= 'arguments' then return false end

  local call = parent:parent()
  if not call or call:type() ~= 'function_call' then return false end

  local name = call:field('name')[1]
  if not name or name:type() ~= 'identifier' then return false end

  local name_text = tree:text(name)
  if name_text ~= 'pcall' and name_text ~= 'xpcall' then return false end

  local first = parent:named_child(0)
  return first ~= nil and first:equal(node)
end

--- @param tree nvim-bundle.transform.Tree
--- @return boolean
local function shadows_globals(tree)
  for captured in tree:matches(GLOBALS) do
    if not is_allowed_global(tree, captured.id) then return true end
  end
  return false
end

--- @param tree nvim-bundle.transform.Tree
--- @param node TSNode a string literal
--- @return string?
local function string_value(tree, node)
  local known, value = tree:literal(node)
  if not known or type(value) ~= 'string' then return nil end
  return value
end

--- @param tree nvim-bundle.transform.Tree
--- @return nvim-bundle.transform.Tree
return function(tree)
  -- A module that binds or aliases one of these names keeps every require
  -- dynamic, because its uses may not be the global functions.
  if shadows_globals(tree) then return tree end

  local fields_by_id = tree.build.fields_by_id
  --- @type nvim-bundle.transform.Replacement[]
  local replacements = {}

  for captured in tree:matches(REQUIRE_CALLS) do
    local module = string_value(tree, captured.module)
    local field = module and fields_by_id[module]
    if field and captured.args:named_child_count() == 1 then
      replacements[#replacements + 1] =
        { node = captured.call, text = ('__mods.%s(%q)'):format(field, module) }
    end
  end

  for captured in tree:matches(PROTECTED_CALLS) do
    local args = captured.args
    local first = args:named_child(0)
    -- `xpcall(require, handler, name)` puts the name after the handler.
    local module_index = tree:text(captured.fn) == 'pcall' and 1 or 2
    local module_node = args:named_child(module_index)
    if
      first
      and first:type() == 'identifier'
      and tree:text(first) == 'require'
      and module_node
      and module_node:type() == 'string'
    then
      local module = string_value(tree, module_node)
      local field = module and fields_by_id[module]
      -- pcall/xpcall infer a type from an anonymous function more reliably
      -- than from a table-field function, so forward the arguments through one.
      if field then
        replacements[#replacements + 1] =
          { node = first, text = ('function(...) return __mods.%s(...) end'):format(field) }
      end
    end
  end

  return tree:replace(replacements)
end
