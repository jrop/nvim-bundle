--- The bundler core: discover a source tree, map files to module ids, rewrite
--- static requires, and emit one bundle. It lives apart from the CLI so that
--- `install` can build dependencies without requiring the CLI module, which is
--- still loading while it runs a command.
local files = require 'nvim-bundle.files'

local M = {}

local function path_exists(path) return vim.uv.fs_stat(path) ~= nil end

--- @param msg string
--- @return never
local function die(msg) error('nvim-bundle: ' .. msg, 0) end

--- @class NvimBundle.BuildOptions
--- @field entry? string the module the bundle returns; nil returns the registry
--- @field root? string
--- @field out? string
--- @field exclude? string[]
--- @field bin? boolean

--- @class NvimBundle.BuildResult
--- @field out string
--- @field entry? string the returned module id, or nil for a registry
--- @field modules integer

--- The one package under a source root, which names a registry bundle and a
--- vendored dependency. Both `foo.lua` and `foo/` name the same package, so they
--- count once. Callers know how the user should resolve an ambiguous root, so
--- they supply the `hint` for the error.
--- @param root string
--- @param hint string
--- @return string
function M.package_name(root, hint)
  local names = {}
  for entry, kind in vim.fs.dir(root) do
    local name = kind == 'directory' and entry or entry:match '^(.+)%.lua$'
    if name then names[name] = true end
  end
  local found = vim.tbl_keys(names)
  table.sort(found)
  if #found ~= 1 then
    local detail = #found == 0 and 'none' or table.concat(found, ', ')
    die(('cannot name the package under %s (found: %s); %s'):format(root, detail, hint))
  end
  return found[1]
end

local function compile_excludes(globs)
  local patterns = {}
  for _, glob in ipairs(globs) do
    local ok, pattern = pcall(vim.glob.to_lpeg, glob)
    if not ok then die(('invalid --exclude glob %q: %s'):format(glob, pattern)) end
    patterns[#patterns + 1] = pattern
  end
  return patterns
end

local function is_excluded(file, patterns)
  for _, pattern in ipairs(patterns) do
    -- Match both the path from the cwd and the path relative to the source
    -- root, so "lua/vendor/**" and "vendor/**" both work.
    if pattern:match(file.path) or pattern:match(file.rel) then return true end
  end
  return false
end

local function list_lua_files(root, patterns)
  local found = {}
  -- math.huge is unbounded, but emmylua types `depth` as integer.
  --- @diagnostic disable-next-line: param-type-mismatch
  for rel, kind in vim.fs.dir(root, { depth = math.huge }) do
    if kind == 'file' and rel:sub(-4) == '.lua' then
      local file = { rel = rel, path = root .. '/' .. rel }
      if not is_excluded(file, patterns) then found[#found + 1] = file end
    end
  end
  table.sort(found, function(a, b) return a.rel < b.rel end)
  return found
end

local function module_id(root, rel)
  local stem = rel:gsub('%.lua$', '')
  if stem == 'init' then return 'init' end
  local parent = stem:match '^(.*)/init$'
  if parent then
    local parent_id = parent:gsub('/', '.')
    -- Match Neovim's lookup order: lua/foo.lua shadows lua/foo/init.lua for
    -- require 'foo', so the init file is reachable as foo.init in that case.
    if path_exists(root .. '/' .. parent .. '.lua') then return parent_id .. '.init' end
    return parent_id
  end
  return (stem:gsub('/', '.'))
end

local function read_source(path)
  local f, err = io.open(path, 'rb')
  if not f then die(('cannot read %s: %s'):format(path, err)) end
  local src = f:read '*a'
  f:close()
  src = src:gsub('^\239\187\191', '') -- UTF-8 BOM
  src = src:gsub('^#![^\n]*\n', '') -- shebang
  if src == '' or src:sub(-1) ~= '\n' then src = src .. '\n' end
  -- Compile at build time so syntax errors name the source file, not the
  -- generated bundle.
  local chunk, load_err = loadstring(src, '@' .. path)
  if not chunk then die(('syntax error in %s: %s'):format(path, load_err)) end
  return src
end

--- @class NvimBundle.Queries
--- @field require_calls vim.treesitter.Query
--- @field protected_calls vim.treesitter.Query
--- @field identifiers vim.treesitter.Query

--- Parsed once per build, after the parser check, and passed to every module
--- rewrite.
--- @return NvimBundle.Queries
local function parse_queries()
  return {
    require_calls = vim.treesitter.query.parse(
      'lua',
      [[
        ((function_call
          name: (identifier) @fn
          arguments: (arguments
            (string) @module) @args) @call
         (#eq? @fn "require"))
      ]]
    ),
    protected_calls = vim.treesitter.query.parse(
      'lua',
      [[
        ((function_call
          name: (identifier) @fn
          arguments: (arguments) @args) @call
         (#any-of? @fn "pcall" "xpcall"))
      ]]
    ),
    identifiers = vim.treesitter.query.parse(
      'lua',
      [[
        ((identifier) @id
         (#any-of? @id "require" "pcall" "xpcall"))
      ]]
    ),
  }
end

--- Neovim 0.12 returns each capture as a list of nodes, while 0.10 returns
--- the node directly. Our queries capture one node per name, so the first
--- element is the node in both shapes.
--- @param value TSNode|TSNode[]
--- @return TSNode?
local function capture_node(value)
  if type(value) == 'table' then return value[1] end
  return value
end

--- Name -> node map for one query match, normalized across Neovim versions.
--- @param query vim.treesitter.Query
--- @param match table<integer, TSNode|TSNode[]>
--- @return table<string, TSNode?>
local function captures(query, match)
  local result = {}
  for capture, value in pairs(match) do
    result[query.captures[capture]] = capture_node(value)
  end
  return result
end

--- A `require`, `pcall`, or `xpcall` identifier is safe to leave in place only
--- when it refers to the global function. Any other position means the module
--- binds or aliases the name, so the module keeps all of its requires dynamic.
--- @param node TSNode
--- @param text string
--- @param src string
--- @return boolean
local function is_allowed_global(node, text, src)
  local parent = node:parent()
  if not parent then return false end

  if parent:type() == 'function_call' then
    local name = parent:field('name')[1]
    if name and name:equal(node) then return true end
  end

  if text ~= 'require' or parent:type() ~= 'arguments' then return false end

  local call = parent:parent()
  if not call or call:type() ~= 'function_call' then return false end

  local name = call:field('name')[1]
  if not name or name:type() ~= 'identifier' then return false end

  local name_text = vim.treesitter.get_node_text(name, src)
  if name_text ~= 'pcall' and name_text ~= 'xpcall' then return false end

  local first = parent:named_child(0)
  return first ~= nil and first:equal(node)
end

--- @param root TSNode
--- @param src string
--- @param queries NvimBundle.Queries
--- @return boolean
local function shadows_globals(root, src, queries)
  for _, match in queries.identifiers:iter_matches(root, src) do
    for _, value in pairs(match) do
      local node = capture_node(value)
      if node and not is_allowed_global(node, vim.treesitter.get_node_text(node, src), src) then
        return true
      end
    end
  end
  return false
end

--- @param node TSNode
--- @param src string
--- @return string?
local function eval_string(node, src)
  local raw = vim.treesitter.get_node_text(node, src)
  -- The node is a string literal, so evaluating it cannot run user code.
  local chunk = loadstring('return ' .. raw)
  if not chunk then return nil end
  local ok, value = pcall(chunk)
  if not ok or type(value) ~= 'string' then return nil end
  return value
end

--- @param src string
--- @param fields table<string, string>
--- @param queries NvimBundle.Queries
--- @return string
local function rewrite_requires(src, fields, queries)
  local ok_parser, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
  if not ok_parser then return src end

  local trees = parser:parse()
  local tree = trees and trees[1]
  if not tree then return src end

  local root = tree:root()
  if root:has_error() then return src end
  if shadows_globals(root, src, queries) then return src end

  local replacements = {}
  local function replace(node, text)
    local _, _, start_byte, _, _, end_byte = node:range(true)
    replacements[#replacements + 1] = {
      start_byte = start_byte,
      end_byte = end_byte,
      text = text,
    }
  end

  --- @param match table<integer, TSNode|TSNode[]>
  local function rewrite_require_call(match)
    local captured = captures(queries.require_calls, match)
    local args = captured.args
    local module_node = captured.module
    local call = captured.call
    if not args or not module_node or not call then return end
    if args:named_child_count() ~= 1 then return end

    local module = eval_string(module_node, src)
    local field = module and fields[module]
    if not field then return end

    -- Replacing a multi-line call with a one-line call would shift the
    -- generated file's line numbers, so those calls keep using host require.
    local start_row, _, _, end_row = call:range(true)
    if start_row ~= end_row then return end

    replace(call, ('__mods.%s(%q)'):format(field, module))
  end

  --- @param match table<integer, TSNode|TSNode[]>
  local function rewrite_protected_call(match)
    local captured = captures(queries.protected_calls, match)
    local args = captured.args
    local name = captured.fn
    if not args or not name then return end

    local name_text = vim.treesitter.get_node_text(name, src)
    local first = args:named_child(0)
    if not first or first:type() ~= 'identifier' then return end
    if vim.treesitter.get_node_text(first, src) ~= 'require' then return end

    local module_index = name_text == 'pcall' and 1 or 2
    if args:named_child_count() <= module_index then return end

    local module_node = args:named_child(module_index)
    if not module_node or module_node:type() ~= 'string' then return end

    local module = eval_string(module_node, src)
    local field = module and fields[module]
    if not field then return end

    -- pcall/xpcall infer a type from an anonymous function more reliably than
    -- from a table-field function, so forward the arguments through one.
    replace(first, ('function(...) return __mods.%s(...) end'):format(field))
  end

  for _, match in queries.require_calls:iter_matches(root, src) do
    rewrite_require_call(match)
  end

  for _, match in queries.protected_calls:iter_matches(root, src) do
    rewrite_protected_call(match)
  end

  table.sort(replacements, function(a, b) return a.start_byte > b.start_byte end)
  for _, replacement in ipairs(replacements) do
    src = src:sub(1, replacement.start_byte)
      .. replacement.text
      .. src:sub(replacement.end_byte + 1)
  end
  return src
end

--- Turn a module id into a valid, readable Lua field name. For example,
--- `myplugin.util` becomes `_myplugin_util`. The leading underscore keeps
--- keywords, leading digits, and the empty name valid. Distinct ids can
--- sanitize to the same name, so the caller supplies the set of names already
--- taken and the collision gets a numeric suffix.
--- @param id string
--- @param taken table<string, boolean>
--- @return string
local function field_name(id, taken)
  local base = '_' .. id:gsub('[^%w_]', '_')
  local name = base
  local suffix = 2
  while taken[name] do
    name = base .. '_' .. suffix
    suffix = suffix + 1
  end
  taken[name] = true
  return name
end

--- The output records no path, so the same tree produces the same bytes from
--- any checkout, which is what lets a vendored dependency be pinned by hash.
--- @param sources { rel: string, path: string }[]
--- @param ids table<string, string>
--- @param entry_id string? the returned module, or nil for a registry
--- @param bin boolean?
--- @param queries NvimBundle.Queries
--- @return string
local function generate(sources, ids, entry_id, bin, queries)
  local fields_by_id = {}
  local taken = {}
  for _, file in ipairs(sources) do
    local id = ids[file.path]
    fields_by_id[id] = field_name(id, taken)
  end

  local out = {}
  local function emit(line) out[#out + 1] = line end
  if bin then
    emit '#!/usr/bin/env -S nvim --clean -l'
    emit '-- vim: set ft=lua:'
  end
  emit '-- Generated by nvim-bundle; do not edit.'
  emit('-- returns: ' .. (entry_id or 'registry'))
  emit 'local __mods = {}'
  -- One loader owns caching and cycle detection for every module, the way
  -- `require` owns `package.loaded`: a module that returns nothing is cached
  -- as `true`, and a module still loading holds a marker. The generic `T`
  -- carries each module's return type through the loader, which the type
  -- checker could not infer from a cache it sees assigned only later.
  emit 'local __loaded = {}'
  emit 'local __LOADING = {}'
  emit '---@generic T'
  emit '---@param id string'
  emit '---@param load fun(...): T'
  emit '---@return T'
  emit 'local function __load(id, load, ...)'
  emit '  local cached = __loaded[id]'
  emit '  if cached == __LOADING then'
  emit [[    error("loop or previous error loading module '" .. id .. "'", 2)]]
  emit '  end'
  emit '  if cached ~= nil then return cached end'
  emit '  __loaded[id] = __LOADING'
  emit '  local value = load(...)'
  emit '  if value == nil then value = true end'
  emit '  __loaded[id] = value'
  emit '  return value'
  emit 'end'

  for _, file in ipairs(sources) do
    local id = ids[file.path]
    local field = fields_by_id[id]
    local src = rewrite_requires(read_source(file.path), fields_by_id, queries)

    -- The function value never changes, so pcall/xpcall can infer the
    -- module's return type through it.
    emit ''
    emit(('__mods.%s = function(...)'):format(field))
    emit(('  return __load(%q, function(...)'):format(id))
    emit(src)
    emit '  end, ...)'
    emit 'end'
  end

  -- Returning the entry's value makes requiring the bundle behave like
  -- requiring the entry source, and executing a bin bundle lets the entry's own
  -- main guard decide whether to run.
  if entry_id then
    emit ''
    emit(('return __mods.%s(%q)'):format(fields_by_id[entry_id], entry_id))
    return table.concat(out, '\n')
  end

  -- The returned table maps module ids to lazy loaders. Each loader calls the
  -- bundled module function, so creating the table evaluates nothing.
  emit ''
  emit 'return {'
  for _, file in ipairs(sources) do
    local id = ids[file.path]
    emit(('  [%q] = function() return __mods.%s(%q) end,'):format(id, fields_by_id[id], id))
  end
  emit '}'
  return table.concat(out, '\n')
end

--- @param opts NvimBundle.BuildOptions
--- @return NvimBundle.BuildResult
function M.build(opts)
  local root = (opts.root or 'lua'):gsub('/+$', '')
  if not path_exists(root) then die('source root not found: ' .. root) end
  if opts.bin and not opts.entry then
    die '--bin needs an entry (for example: nvim-bundle build mycli --bin)'
  end
  -- A registry returns no single module, so its default file is named after
  -- the root's one package.
  local out = opts.out or ('dist/%s.lua'):format(opts.entry or M.package_name(root, 'pass --out'))
  local exclude = opts.exclude or {}

  local patterns = compile_excludes(exclude)
  local sources = list_lua_files(root, patterns)

  local ids = {}
  local by_id = {}
  for _, file in ipairs(sources) do
    local id = module_id(root, file.rel)
    local other = by_id[id]
    if other then
      die(('module id collision: %s and %s both map to %s'):format(other, file.path, id))
    end
    by_id[id] = file.path
    ids[file.path] = id
  end

  -- Module ids already encode Neovim's lookup order, so the entry is found by
  -- id, and an excluded or absent file is simply not among them.
  if opts.entry and not by_id[opts.entry] then
    die(
      ('module %q is not in the bundle (no such file under %s, or excluded)'):format(
        opts.entry,
        root
      )
    )
  end

  local out_abs = vim.fs.normalize(vim.fn.fnamemodify(out, ':p'))
  local root_abs = vim.fs.normalize(vim.fn.fnamemodify(root, ':p'))
  if out_abs:sub(1, #root_abs + 1) == root_abs .. '/' then
    die('--out must be outside the source root (' .. root .. ')')
  end

  -- 0.10 returns no value from language.add on success, while newer versions
  -- return true, so exercise the parser instead of checking the return value.
  local has_parser = pcall(function()
    vim.treesitter.language.add 'lua'
    local parser = vim.treesitter.get_string_parser('return 1\n', 'lua')
    parser:parse()
  end)
  if not has_parser then die 'Neovim Lua parser is required for static require resolution' end

  local content = generate(sources, ids, opts.entry, opts.bin, parse_queries())
  local chunk, err = loadstring(content, '@' .. out)
  if not chunk then die('generated bundle has a syntax error: ' .. err) end
  files.write(out, content)
  if opts.bin then
    local ok, chmod_err = vim.uv.fs_chmod(out, 493)
    if not ok then die(('cannot make %s executable: %s'):format(out, tostring(chmod_err))) end
  end
  return { out = out, entry = opts.entry, modules = #sources }
end

return M
