--- Replace each expression that a `--define` key names with the key's value,
--- so a module can read a build-time setting as if it were a global.

-- Both node types are captured wherever they occur, including inside each
-- other, so `vim.g.x` yields `vim`, `vim.g`, and `vim.g.x`.
local CANDIDATES = [[ [(identifier) (dot_index_expression)] @node ]]

local DECLARATIONS = [[
  (variable_declaration (variable_list name: (identifier) @name))
  (variable_declaration (assignment_statement (variable_list name: (identifier) @name)))
  (parameters name: (identifier) @name)
  (for_numeric_clause name: (identifier) @name)
  (for_generic_clause (variable_list name: (identifier) @name))
  (function_declaration "local" name: (identifier) @name)
]]

--- The node types whose `table` child is indexed.
local INDEX = {
  dot_index_expression = true,
  bracket_index_expression = true,
  method_index_expression = true,
}

--- @param parent TSNode
--- @param field string
--- @param node TSNode
--- @return boolean
local function is_child(parent, field, node)
  local child = parent:field(field)[1]
  return child ~= nil and child:equal(node)
end

--- `vim.g.x` -> 'vim.g.x' when every part is a plain name. Any other form
--- yields nil, which never matches a key.
--- @param tree nvim-bundle.transform.Tree
--- @param node TSNode?
--- @return string?
local function key_of(tree, node)
  if not node then return nil end
  if node:type() == 'identifier' then return tree:text(node) end
  if node:type() ~= 'dot_index_expression' then return nil end
  local base = key_of(tree, node:field('table')[1])
  local field = node:field('field')[1]
  return base and field and base .. '.' .. tree:text(field)
end

--- Field names (`x.k`, `o:k()`, `{ k = 1 }`), labels, and attributes are
--- identifiers in the tree, but none of them reads a variable.
--- @param node TSNode
--- @return boolean
local function is_name_position(node)
  local parent = node:parent()
  if not parent then return false end
  local kind = parent:type()
  if kind == 'dot_index_expression' then return is_child(parent, 'field', node) end
  if kind == 'method_index_expression' then return is_child(parent, 'method', node) end
  if kind == 'field' then return is_child(parent, 'name', node) end
  return kind == 'label_statement' or kind == 'goto_statement' or kind == 'attribute'
end

--- With `vim.g` and `vim.g.x` both defined, `vim.g.x` is replaced whole, so
--- the `vim.g` inside it is not.
--- @param tree nvim-bundle.transform.Tree
--- @param node TSNode
--- @return boolean
local function inside_longer_key(tree, node)
  local define = tree.build.define
  local parent = node:parent()
  while parent and parent:type() == 'dot_index_expression' and is_child(parent, 'table', node) do
    if define[key_of(tree, parent) or ''] then return true end
    node, parent = parent, parent:parent()
  end
  return false
end

--- Whether the code writes the key, or a field reached through it, such as
--- `k = v`, `k.y = v`, or `function k.f() end`. A module that assigns a value
--- the build fixes contradicts the define, so this is an error.
--- @param node TSNode
--- @return boolean
local function is_assignment_target(node)
  local target, parent = node, node:parent()
  while parent and INDEX[parent:type()] and is_child(parent, 'table', target) do
    target, parent = parent, parent:parent()
  end
  if not parent then return false end
  if parent:type() == 'function_declaration' then return is_child(parent, 'name', target) end
  if parent:type() ~= 'variable_list' then return false end
  -- A `local` declaration and a `for` clause also hold variable lists, but
  -- they declare names rather than assign them.
  local statement = parent:parent()
  if not statement or statement:type() ~= 'assignment_statement' then return false end
  local outer = statement:parent()
  return not outer or outer:type() ~= 'variable_declaration'
end

--- A value that is indexed or called needs parentheses: `"x":upper()` is not
--- valid Lua, but `("x"):upper()` is. Anywhere else the value is inserted
--- bare, so dead-code removal sees the literal itself.
--- @param node TSNode
--- @return boolean
local function in_prefix_position(node)
  local parent = node:parent()
  if not parent then return false end
  if INDEX[parent:type()] then return is_child(parent, 'table', node) end
  return parent:type() == 'function_call' and is_child(parent, 'name', node)
end

--- The text that replaces `node`, or nil when the node is not a read of a
--- defined global.
--- @param tree nvim-bundle.transform.Tree
--- @param node TSNode
--- @param declared table<string, boolean>
--- @return string?
local function replacement(tree, node, declared)
  local key = key_of(tree, node)
  if not key then return nil end
  local value = tree.build.define[key]
  if not value then return nil end
  if declared[key:match '^[^.]+'] then return nil end
  if is_name_position(node) or inside_longer_key(tree, node) then return nil end

  if is_assignment_target(node) then
    error(('nvim-bundle: %s assigns to %s, which --define replaces'):format(tree.path, key), 0)
  end
  if in_prefix_position(node) then return '(' .. value .. ')' end
  return value
end

--- @param tree nvim-bundle.transform.Tree
--- @return nvim-bundle.transform.Tree
return function(tree)
  if not next(tree.build.define) then return tree end

  -- A name the module declares anywhere is not the global in that module.
  -- This is coarse on purpose, as a shadowed `require` keeps every require of
  -- its module dynamic.
  local declared = {}
  for captured in tree:matches(DECLARATIONS) do
    declared[tree:text(captured.name)] = true
  end

  --- @type nvim-bundle.transform.Replacement[]
  local replacements = {}
  for captured in tree:matches(CANDIDATES) do
    local text = replacement(tree, captured.node, declared)
    if text then replacements[#replacements + 1] = { node = captured.node, text = text } end
  end

  -- A key that matches nothing is silent, so one set of defines can serve
  -- modules that use only some of them.
  return tree:replace(replacements)
end
