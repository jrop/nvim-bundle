--- The source transforms run on every bundled module: a pipeline of passes
--- that each take a module's tree and return a new one. Tree-sitter trees are
--- read-only, so a pass changes the source text and the tree is parsed again.
--- Passes edit only inside the module source; `build` emits the wrapper.
local dead_code = require 'nvim-bundle.transform.dead_code'
local define = require 'nvim-bundle.transform.define'
local link = require 'nvim-bundle.transform.require'

--- @param msg string
--- @return never
local function die(msg) error('nvim-bundle: ' .. msg, 0) end

--- What the build knows that a pass needs. A pass is only a function of its
--- tree, so the build travels with the tree.
--- @class nvim-bundle.transform.Build
--- @field fields_by_id table<string, string> module id -> `__mods` field
--- @field define table<string, string> key -> Lua expression

--- @class nvim-bundle.transform.Replacement
--- @field node TSNode
--- @field text string

--- @alias nvim-bundle.transform.Pass fun(tree: nvim-bundle.transform.Tree): nvim-bundle.transform.Tree

--------------------------------------------------------------------------------
-- Tree
--------------------------------------------------------------------------------

--- @class nvim-bundle.transform.Tree
--- @field src string
--- @field root TSNode
--- @field path string names the module in an error
--- @field build nvim-bundle.transform.Build
local Tree = {}
Tree.__index = Tree

--- @param src string
--- @param path string
--- @param build nvim-bundle.transform.Build
--- @return nvim-bundle.transform.Tree? nil when the source cannot be parsed
local function parse(src, path, build)
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
  if not ok then return nil end
  local trees = parser:parse()
  local tree = trees and trees[1]
  if not tree then return nil end
  local root = tree:root()
  if root:has_error() then return nil end
  return setmetatable({ src = src, root = root, path = path, build = build }, Tree)
end

--- Neovim 0.12 returns each capture as a list of nodes, while 0.10 returns
--- the node directly. Every query captures one node per name, so the first
--- element is the node in both shapes.
--- @param value TSNode|TSNode[]
--- @return TSNode
local function capture_node(value)
  -- A capture appears in a match only when it captured a node.
  if type(value) == 'table' then
    return value[1] --[[@as TSNode]]
  end
  return value
end

--- Iterate the matches of the query `source` as capture name -> node tables.
--- Neovim caches each parsed query, so a pass can keep its query as a string.
--- @param source string a Lua tree-sitter query
--- @return fun(): table<string, TSNode>?
function Tree:matches(source)
  local query = vim.treesitter.query.parse('lua', source)
  local iter = query:iter_matches(self.root, self.src)
  return function()
    local _, match = iter()
    if not match then return nil end
    local captured = {}
    for capture, value in pairs(match) do
      captured[query.captures[capture]] = capture_node(value)
    end
    return captured
  end
end

--- @param node TSNode
--- @return string
function Tree:text(node) return vim.treesitter.get_node_text(node, self.src) end

--- The value of a number or string literal. The node is a literal, so
--- evaluating its text cannot run user code.
--- @param node TSNode
--- @return boolean known, any value
function Tree:literal(node)
  local chunk = loadstring('return ' .. self:text(node))
  if not chunk then return false, nil end
  local ok, value = pcall(chunk)
  return ok, value
end

--------------------------------------------------------------------------------
-- Replacement
--------------------------------------------------------------------------------

--- @param s string
--- @return integer
local function newlines(s) return select(2, s:gsub('\n', '')) end

--- @param node TSNode
--- @return integer
local function byte_of(node) return select(3, node:start()) end

--- Whether `node` begins a statement that follows another statement in its
--- block. A comment between them does not end the earlier statement.
--- @param node TSNode
--- @return boolean
local function follows_statement(node)
  local start = byte_of(node)
  local statement = node
  local parent = statement:parent()
  -- Climb while the ancestor begins where the node begins, so `vim.g.env` in
  -- `vim.g.env:upper()` reaches the call statement it starts.
  while parent and parent:type() ~= 'chunk' and parent:type() ~= 'block' do
    if byte_of(parent) ~= start then return false end
    statement, parent = parent, parent:parent()
  end
  local previous = statement:prev_named_sibling()
  while previous and previous:type() == 'comment' do
    previous = previous:prev_named_sibling()
  end
  return previous ~= nil
end

--- The text that actually replaces `node`, made safe wherever it lands. The
--- bundle keeps every module's line numbers, so an error's line, minus the
--- module's offset in the bundle, is the line in the source. So the text is
--- padded to the line count of `old`, and text with more lines is a bug in
--- its pass.
--- @param tree nvim-bundle.transform.Tree
--- @param node TSNode
--- @param old string the text being replaced
--- @param text string what the pass asked for
--- @return string
local function placed(tree, node, old, text)
  local missing = newlines(old) - newlines(text)
  if missing < 0 then die('a transform added lines to ' .. tree.path) end
  -- The missing line breaks go first: a break before an expression is always
  -- valid, while one after it can split a call (`("x")\n(1)`), and the text
  -- after the node then stays on the line where it was.
  local padded = string.rep('\n', missing) .. text
  -- A `(` at the start of a statement continues the previous line's
  -- expression, which LuaJIT rejects as ambiguous. The `;` ends that
  -- statement first. It cannot go before the first statement of a block,
  -- where nothing precedes the `(` to continue.
  if text:sub(1, 1) == '(' and follows_statement(node) then return ';' .. padded end
  return padded
end

--- Replace each node's text and return the tree of the result.
--- @param replacements nvim-bundle.transform.Replacement[]
--- @return nvim-bundle.transform.Tree
function Tree:replace(replacements)
  if #replacements == 0 then return self end
  local spans = vim.tbl_map(function(r)
    local _, _, start_byte, _, _, end_byte = r.node:range(true)
    return { node = r.node, start_byte = start_byte, end_byte = end_byte, text = r.text }
  end, replacements)
  -- Passes produce spans in query-match order, and a pass with two queries
  -- interleaves them. Spans that share a start overlap, so ties need no order.
  table.sort(spans, function(a, b) return a.start_byte < b.start_byte end)

  local pieces, pos = {}, 0 -- `pos` is the byte after the last copied piece
  for _, span in ipairs(spans) do
    if span.start_byte < pos then die('overlapping replacements in ' .. self.path) end
    local old = self.src:sub(span.start_byte + 1, span.end_byte)
    pieces[#pieces + 1] = self.src:sub(pos + 1, span.start_byte)
    pieces[#pieces + 1] = placed(self, span.node, old, span.text)
    pos = span.end_byte
  end
  pieces[#pieces + 1] = self.src:sub(pos + 1)

  -- A pass that produced invalid Lua has a bug. Failing here names the module,
  -- rather than the generated bundle.
  return parse(table.concat(pieces), self.path, self.build)
    or die('a transform produced invalid Lua in ' .. self.path)
end

--------------------------------------------------------------------------------
-- Pipeline
--------------------------------------------------------------------------------

local M = {}

-- Each pass sees the source the previous pass produced. Define runs first, so
-- dead-code removal sees the literals it inserts, and a define value that
-- contains a `require` is still linked. Require runs last, so a require in a
-- removed branch is never linked.
--- @type nvim-bundle.transform.Pass[]
local PASSES = { define, dead_code, link }

--- @param src string
--- @param path string
--- @param build nvim-bundle.transform.Build
--- @return string
function M.run(src, path, build)
  local tree = parse(src, path, build)
  -- An unparsable module stays as written, so all of its requires stay host
  -- requires.
  if not tree then return src end
  for _, pass in ipairs(PASSES) do
    tree = pass(tree)
  end
  return tree.src
end

return M
