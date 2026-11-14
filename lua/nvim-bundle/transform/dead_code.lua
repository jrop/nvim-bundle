--- Remove the branches of `if` and `while` statements whose conditions have a
--- fixed value at build time, such as the literals that `--define` inserts.
--- A kept body stays a `do ... end` block, so its locals, `return`, and labels
--- behave as they did, and a removed statement becomes `do end`, which no
--- neighboring expression can absorb.

--- The type of an operator or keyword token, skipping comments, which the
--- tree also holds as children.
--- @param node TSNode
--- @return string?
local function operator_of(node)
  for child in node:iter_children() do
    if not child:named() then return child:type() end
  end
  return nil
end

--- @param node TSNode
--- @return TSNode?
local function inner_expression(node)
  for child in node:iter_children() do
    if child:named() and child:type() ~= 'comment' then return child end
  end
  return nil
end

--- The value `node` always has, found without running anything. Only literals
--- and operators over literals qualify: anything else could have side effects
--- or depend on the program, so removing it could change what runs.
--- @param tree nvim-bundle.transform.Tree
--- @param node TSNode?
--- @return boolean known, any value
local function static_value(tree, node)
  if not node then return false, nil end
  local kind = node:type()
  if kind == 'true' then return true, true end
  if kind == 'false' then return true, false end
  if kind == 'nil' then return true, nil end
  if kind == 'number' or kind == 'string' then return tree:literal(node) end
  if kind == 'parenthesized_expression' then return static_value(tree, inner_expression(node)) end

  if kind == 'unary_expression' then
    if operator_of(node) ~= 'not' then return false, nil end
    local known, value = static_value(tree, node:field('operand')[1])
    return known, not value
  end
  if kind ~= 'binary_expression' then return false, nil end

  local op = operator_of(node)
  local left_known, left = static_value(tree, node:field('left')[1])
  if not left_known then return false, nil end
  -- When the left side decides `and` or `or`, the right side never runs, so
  -- it needs no fixed value.
  if op == 'and' and not left then return true, left end
  if op == 'or' and left then return true, left end
  local right_known, right = static_value(tree, node:field('right')[1])
  if not right_known then return false, nil end
  if op == 'and' or op == 'or' then return true, right end
  if op == '==' then return true, left == right end
  if op == '~=' then return true, left ~= right end
  return false, nil
end

--- @alias nvim-bundle.transform.dead_code.Truth 'true' | 'false' | 'unknown'

--- @param tree nvim-bundle.transform.Tree
--- @param condition TSNode? nil for `else`, which always runs once reached
--- @return nvim-bundle.transform.dead_code.Truth
local function truth(tree, condition)
  if not condition then return 'true' end
  local known, value = static_value(tree, condition)
  if not known then return 'unknown' end
  return value and 'true' or 'false'
end

--- One arm of an if statement. The first arm's parts are children of the if
--- statement itself, while each later arm has a node of its own.
--- @class nvim-bundle.transform.dead_code.Clause
--- @field own? TSNode the `elseif` or `else` node; nil for the first arm
--- @field keyword TSNode the `if`, `elseif`, or `else` token
--- @field condition? TSNode
--- @field then_? TSNode the `then` token
--- @field body? TSNode
--- @field truth nvim-bundle.transform.dead_code.Truth

--- The keyword, condition, `then`, and body of one arm.
--- @param tree nvim-bundle.transform.Tree
--- @param node TSNode the if statement for the first arm, else the arm's own node
--- @return nvim-bundle.transform.dead_code.Clause
local function clause_of(tree, node)
  local clause = {}
  for child, field in node:iter_children() do
    local kind = child:type()
    if kind == 'if' or kind == 'elseif' or kind == 'else' then clause.keyword = child end
    if kind == 'then' then clause.then_ = child end
    if field == 'condition' then clause.condition = child end
    if field == 'consequence' or field == 'body' then clause.body = child end
  end
  if node:type() ~= 'if_statement' then clause.own = node end
  clause.truth = truth(tree, clause.condition)
  return clause
end

--- @param tree nvim-bundle.transform.Tree
--- @param statement TSNode
--- @return nvim-bundle.transform.dead_code.Clause[]
local function clauses_of(tree, statement)
  local clauses = { clause_of(tree, statement) }
  for child, field in statement:iter_children() do
    if field == 'alternative' then clauses[#clauses + 1] = clause_of(tree, child) end
  end
  return clauses
end

--- @param out nvim-bundle.transform.Replacement[]
--- @param node TSNode?
--- @param text string
local function put(out, node, text)
  if node then out[#out + 1] = { node = node, text = text } end
end

--- Delete `clause` from its statement.
--- @param clause nvim-bundle.transform.dead_code.Clause
--- @param out nvim-bundle.transform.Replacement[]
local function drop(clause, out)
  if clause.own then return put(out, clause.own, '') end
  put(out, clause.keyword, '')
  put(out, clause.condition, '')
  put(out, clause.then_, '')
  put(out, clause.body, '')
end

--- Turn `clause` into an arm that always runs, headed by `keyword`.
--- @param clause nvim-bundle.transform.dead_code.Clause
--- @param keyword string `do` or `else`
--- @param out nvim-bundle.transform.Replacement[]
local function unconditional(clause, keyword, out)
  put(out, clause.keyword, keyword)
  put(out, clause.condition, '')
  put(out, clause.then_, '')
end

--- Fold one if statement, and return the kept parts that may hold more
--- statements, such as a function in an unknown condition.
--- @param tree nvim-bundle.transform.Tree
--- @param statement TSNode
--- @param out nvim-bundle.transform.Replacement[]
--- @return TSNode[]
local function fold_if(tree, statement, out)
  local clauses = clauses_of(tree, statement)
  local kept = {}
  for _, clause in ipairs(clauses) do
    if clause.truth ~= 'false' then kept[#kept + 1] = clause end
    -- An arm that always runs ends the chain: no later arm can run.
    if clause.truth == 'true' then break end
  end

  if #kept == 0 then
    put(out, statement, 'do end')
    return {}
  end
  for _, clause in ipairs(clauses) do
    if not vim.list_contains(kept, clause) then drop(clause, out) end
  end

  -- `kept` is not empty past the early return above.
  local first = kept[1] --[[@as nvim-bundle.transform.dead_code.Clause]]
  local last = kept[#kept] --[[@as nvim-bundle.transform.dead_code.Clause]]
  if first.truth == 'true' then
    -- The statement's own `end` closes the block.
    unconditional(first, 'do', out)
  else
    -- The first arm was dropped, so the first kept `elseif` leads the chain.
    if first.own then put(out, first.keyword, 'if') end
    if last.truth == 'true' and last.condition then unconditional(last, 'else', out) end
  end

  local children = {}
  for _, clause in ipairs(kept) do
    if clause.truth == 'unknown' then children[#children + 1] = clause.condition end
    if clause.body then children[#children + 1] = clause.body end
  end
  return children
end

--- Walk top-down, so code inside a removed branch is never visited and its
--- replacements cannot overlap the branch's own.
--- @param tree nvim-bundle.transform.Tree
--- @param node TSNode
--- @param out nvim-bundle.transform.Replacement[]
local function visit(tree, node, out)
  local kind = node:type()
  if kind == 'if_statement' then
    for _, child in ipairs(fold_if(tree, node, out)) do
      visit(tree, child, out)
    end
    return
  end
  if kind == 'while_statement' and truth(tree, node:field('condition')[1]) == 'false' then
    return put(out, node, 'do end')
  end
  for child in node:iter_children() do
    visit(tree, child, out)
  end
end

--- @param tree nvim-bundle.transform.Tree
--- @return nvim-bundle.transform.Tree
return function(tree)
  --- @type nvim-bundle.transform.Replacement[]
  local replacements = {}
  visit(tree, tree.root, replacements)
  return tree:replace(replacements)
end
