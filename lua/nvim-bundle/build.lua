--- The bundler core: discover a source tree, map files to module ids, run the
--- source transforms, and emit one bundle. It lives apart from the CLI so that
--- `install` can build dependencies without requiring the CLI module, which is
--- still loading while it runs a command.
local dto = require 'nvim-bundle.dto'
local files = require 'nvim-bundle.files'
local transform = require 'nvim-bundle.transform'

local M = {}

local function path_exists(path) return vim.uv.fs_stat(path) ~= nil end

--- @param msg string
--- @return never
local function die(msg) error('nvim-bundle: ' .. msg, 0) end

--- @class nvim-bundle.build.BuildResult
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
--- @param define table<string, string>
--- @return string
local function generate(sources, ids, entry_id, bin, define)
  local fields_by_id = {}
  local taken = {}
  for _, file in ipairs(sources) do
    local id = ids[file.path]
    fields_by_id[id] = field_name(id, taken)
  end

  --- @type nvim-bundle.transform.Build
  local build = { fields_by_id = fields_by_id, define = define }

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
  --
  -- The cache belongs to the file, not to one execution of it. A CLI run with
  -- `nvim -l` leaves `package.loaded` empty, so a spec that requires the same
  -- file executes it again, and a cache per execution would build every module
  -- twice. Both executions resolve the same real path, and the line of the
  -- lookup tells apart a nested bundle, whose source is the outer bundle's
  -- file. The marker is shared too, so one execution recognizes a module that
  -- the other is still loading. A chunk not loaded from a file has no path to
  -- share, so it keeps a private cache, and so does a host without Neovim,
  -- which has no `vim.uv` to resolve the path. `rawget` reads `vim` without
  -- declaring the bundle dependent on Neovim's type stubs.
  emit '---@return { loaded: table<string, any>, LOADING: table }'
  emit 'local function __cache()'
  emit '  local private = { loaded = {}, LOADING = {} }'
  emit "  local nvim, info = rawget(_G, 'vim'), debug.getinfo(1, 'Sl')"
  emit "  if not nvim or not info or info.source:sub(1, 1) ~= '@' then return private end"
  emit '  local path = nvim.uv.fs_realpath(info.source:sub(2))'
  emit '  if not path then return private end'
  emit "  local key = ('nvim-bundle:%s:%d'):format(path, info.currentline)"
  emit '  package.loaded[key] = package.loaded[key] or private'
  emit '  return package.loaded[key]'
  emit 'end'
  emit 'local __cached = __cache()'
  emit 'local __loaded, __LOADING = __cached.loaded, __cached.LOADING'
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
    local src = transform.run(read_source(file.path), file.path, build)

    emit ''
    if id == entry_id then
      -- The entry's body is a named function, because the bundle's last line
      -- calls it without the cache when the file runs again. It takes `arg` as
      -- a parameter, so each caller decides whether the entry is the script.
      -- The wrapper still never changes, so pcall/xpcall can infer the
      -- module's return type through it.
      emit '---@param arg string[]'
      emit 'local function __entry(arg, ...)'
      emit(src)
      emit 'end'
      emit(('__mods.%s = function(...) return __load(%q, __entry, arg, ...) end'):format(field, id))
    else
      emit(('__mods.%s = function(...)'):format(field))
      emit(('  return __load(%q, function(...)'):format(id))
      -- Every module shares the bundle's source path, so a library's main
      -- guard (its source compared with `arg[0]`) would pass when the bundle
      -- runs. Only the entry can be the script, so every other module sees
      -- `arg` as plain plugin code in Neovim does: an empty table. The local
      -- shadows the global lexically, which also covers a check made after
      -- loading and every module of a nested bundle.
      emit '---@type string[]'
      emit 'local arg = {}'
      emit(src)
      emit '  end, ...)'
      emit 'end'
    end
  end

  -- Returning the entry's value makes requiring the bundle behave like
  -- requiring the entry source, and executing a bin bundle lets the entry's own
  -- main guard decide whether to run.
  --
  -- An entry already in the cache means an earlier execution of this file ran
  -- it, so this execution is a `require` of a file that has already run, such
  -- as a spec requiring the CLI that runs it. `require` on unbundled source
  -- evaluates the file again but reuses every library from `package.loaded`,
  -- so the bundle evaluates the entry again with the shared libraries. The
  -- entry then sees an empty `arg`, as a library does, so its main guard does
  -- not start the CLI a second time.
  if entry_id then
    emit ''
    emit(('if __loaded[%q] ~= nil then return __entry({}, ...) end'):format(entry_id))
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

--- `opts.entry` is the module the bundle returns; without one, the bundle
--- returns a registry. The options are validated because this is the public
--- Lua API, so a caller's typo must fail rather than be ignored.
--- @param opts nvim-bundle.dto.BuildOptions
--- @return nvim-bundle.build.BuildResult
function M.build(opts)
  opts = dto.check(dto.BuildOptions, opts, 'build options') --[[@as nvim-bundle.dto.BuildOptions]]
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

  local content = generate(sources, ids, opts.entry, opts.bin, opts.define or {})
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
