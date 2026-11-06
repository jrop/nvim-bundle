#!/usr/bin/env -S nvim --clean -l
-- vim: set ft=lua:
-- nvim-bundle: build a single-file Lua bundle from lua/**/*.lua.
--
-- Resolvable `require` calls are linked directly to the bundled module
-- functions. Calls that cannot be resolved (computed names, a shadowed
-- `require`, an unparsable module, or a module outside the bundle) remain
-- ordinary host `require` calls.

local M = {}

local USAGE = [[
Usage: nvim-bundle <entry> [options]

Options:
  --root <dir>       Source root to scan (default: lua)
  --out <file>       Output bundle (default: dist/<entry>.lua)
  --exclude <glob>   Skip paths matching <glob> (repeatable)
  -h, --help         Show this help

Examples:
  nvim-bundle myplugin
  nvim-bundle myplugin --exclude '**/_test/**'
]]

--- @param msg string
--- @return never
local function die(msg) error('nvim-bundle: ' .. msg, 0) end

local function path_exists(path) return vim.uv.fs_stat(path) ~= nil end

local function parse_args(argv)
  local opts = { root = 'lua', exclude = {} }
  local entry
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == '--root' then
      i = i + 1
      opts.root = argv[i] or die '--root needs a value'
    elseif a == '--out' then
      i = i + 1
      opts.out = argv[i] or die '--out needs a value'
    elseif a == '--exclude' then
      i = i + 1
      opts.exclude[#opts.exclude + 1] = argv[i] or die '--exclude needs a value'
    elseif a == '--help' or a == '-h' then
      return { help = true }
    elseif a:sub(1, 1) == '-' then
      die('unknown option ' .. a)
    elseif entry then
      die('unexpected argument ' .. a)
    else
      entry = a
    end
    i = i + 1
  end
  if not entry then die 'missing entry module (for example: morph)' end
  opts.entry = entry
  opts.root = opts.root:gsub('/+$', '')
  opts.out = opts.out or ('dist/' .. entry .. '.lua')
  return opts
end

local function resolve_entry(root, entry)
  local rel = entry:gsub('%.', '/')
  local candidates = {
    root .. '/' .. rel .. '.lua',
    root .. '/' .. rel .. '/init.lua',
  }
  for _, path in ipairs(candidates) do
    if path_exists(path) then return path end
  end
  die(('entry %q not found; tried %s'):format(entry, table.concat(candidates, ', ')))
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
  if not path_exists(root) then die('source root not found: ' .. root) end
  local files = {}
  -- math.huge is unbounded, but emmylua types `depth` as integer.
  --- @diagnostic disable-next-line: param-type-mismatch
  for rel, kind in vim.fs.dir(root, { depth = math.huge }) do
    if kind == 'file' and rel:sub(-4) == '.lua' then
      local file = { rel = rel, path = root .. '/' .. rel }
      if not is_excluded(file, patterns) then files[#files + 1] = file end
    end
  end
  table.sort(files, function(a, b) return a.rel < b.rel end)
  return files
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

--- @class NvimBundleQueries
--- @field require_calls vim.treesitter.Query
--- @field protected_calls vim.treesitter.Query
--- @field identifiers vim.treesitter.Query

--- @type NvimBundleQueries?
local queries

--- @return NvimBundleQueries
local function get_queries()
  if queries then return queries end

  local built = {
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

  queries = built
  return built
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
--- @return boolean
local function shadows_globals(root, src)
  local found = get_queries()
  for _, match in found.identifiers:iter_matches(root, src) do
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
--- @return string
local function rewrite_requires(src, fields)
  local ok_parser, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
  if not ok_parser then return src end

  local trees = parser:parse()
  local tree = trees and trees[1]
  if not tree then return src end

  local root = tree:root()
  if root:has_error() then return src end
  if shadows_globals(root, src) then return src end

  local replacements = {}
  local function replace(node, text)
    local _, _, start_byte, _, _, end_byte = node:range(true)
    replacements[#replacements + 1] = {
      start_byte = start_byte,
      end_byte = end_byte,
      text = text,
    }
  end

  local found = get_queries()

  --- @param match table<integer, TSNode|TSNode[]>
  local function rewrite_require_call(match)
    local captured = captures(found.require_calls, match)
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
    local captured = captures(found.protected_calls, match)
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

  for _, match in found.require_calls:iter_matches(root, src) do
    rewrite_require_call(match)
  end

  for _, match in found.protected_calls:iter_matches(root, src) do
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

local function generate(root, files, ids, entry_id)
  local fields_by_id = {}
  local taken = {}
  for _, file in ipairs(files) do
    local id = ids[file.path]
    fields_by_id[id] = field_name(id, taken)
  end

  local out = {}
  local function emit(line) out[#out + 1] = line end
  emit '-- Generated by nvim-bundle; do not edit.'
  emit('-- entry: ' .. entry_id)
  emit('-- source root: ' .. root)
  emit 'local __mods = {}'
  emit 'local __loading = {}'
  emit 'local __loaded = {}'

  for _, file in ipairs(files) do
    local id = ids[file.path]
    local field = fields_by_id[id]
    local src = rewrite_requires(read_source(file.path), fields_by_id)
    local message = "loop or previous error loading module '" .. id .. "'"

    -- The cached value is a block-local upvalue rather than a reassigned
    -- function. Keeping the function value stable lets pcall/xpcall infer the
    -- module's return type, and one block per module avoids Lua's 200-local
    -- limit on a single chunk.
    emit ''
    emit 'do'
    emit '  local value'
    emit(('  __mods.%s = function(...)'):format(field))
    emit(('    if __loaded.%s then return value end'):format(field))
    emit(('    if __loading.%s then error(%q, 2) end'):format(field, message))
    emit(('    __loading.%s = true'):format(field))
    emit '    local M = (function(...)'
    emit(src)
    emit '    end)(...)'
    emit(('    __loading.%s = false'):format(field))
    emit(('    __loaded.%s = true'):format(field))
    emit '    value = M'
    emit '    return M'
    emit '  end'
    emit 'end'
  end

  emit ''
  emit(('return __mods.%s(%q)'):format(fields_by_id[entry_id], entry_id))
  return table.concat(out, '\n')
end

local function write_output(path, content)
  local dir = vim.fs.dirname(path)
  if dir and dir ~= '.' then vim.fn.mkdir(dir, 'p') end
  local f, err = io.open(path, 'wb')
  if not f then die(('cannot write %s: %s'):format(path, err)) end
  f:write(content)
  f:close()
end

function M.run(argv)
  local opts = parse_args(argv)
  if opts.help then return { help = true } end

  local entry_path = resolve_entry(opts.root, opts.entry)
  local patterns = compile_excludes(opts.exclude)
  local files = list_lua_files(opts.root, patterns)

  local ids = {}
  local by_id = {}
  for _, file in ipairs(files) do
    local id = module_id(opts.root, file.rel)
    local other = by_id[id]
    if other then
      die(('module id collision: %s and %s both map to %s'):format(other, file.path, id))
    end
    by_id[id] = file.path
    ids[file.path] = id
  end

  local entry_id = ids[entry_path]
  if not entry_id then die('entry is excluded or missing from the bundle: ' .. entry_path) end

  local out_abs = vim.fs.normalize(vim.fn.fnamemodify(opts.out, ':p'))
  local root_abs = vim.fs.normalize(vim.fn.fnamemodify(opts.root, ':p'))
  if out_abs:sub(1, #root_abs + 1) == root_abs .. '/' then
    die('--out must be outside the source root (' .. opts.root .. ')')
  end

  -- 0.10 returns no value from language.add on success, while newer versions
  -- return true, so exercise the parser instead of checking the return value.
  local has_parser = pcall(function()
    vim.treesitter.language.add 'lua'
    local parser = vim.treesitter.get_string_parser('return 1\n', 'lua')
    parser:parse()
  end)
  if not has_parser then die 'Neovim Lua parser is required for static require resolution' end

  local content = generate(opts.root, files, ids, entry_id)
  local chunk, err = loadstring(content, '@' .. opts.out)
  if not chunk then die('generated bundle has a syntax error: ' .. err) end
  write_output(opts.out, content)
  return { out = opts.out, entry = entry_id, modules = #files }
end

function M.main(argv)
  local ok, result = pcall(M.run, argv)
  if not ok then
    io.stderr:write(tostring(result) .. '\n')
    os.exit(1)
  end
  if result.help then
    io.stdout:write(USAGE)
    return
  end
  io.stdout:write(
    ('bundled %d modules into %s (entry %s)\n'):format(result.modules, result.out, result.entry)
  )
end

local function is_main()
  local info = debug.getinfo(1, 'S')
  local argv0 = arg and arg[0]
  if not info or not argv0 or info.source:sub(1, 1) ~= '@' then return false end
  local this = vim.fs.normalize(vim.fn.fnamemodify(info.source:sub(2), ':p'))
  return this == vim.fs.normalize(vim.fn.fnamemodify(argv0, ':p'))
end

if is_main() then M.main(arg) end

return M
