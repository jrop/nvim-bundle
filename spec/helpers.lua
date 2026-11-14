--- @diagnostic disable: need-check-nil
--- @diagnostic disable: undefined-field

-- Under `busted --coverage`, luacov's tick interval flushes every 100 hits, but
-- the parent test process exits through Neovim rather than Lua's os.exit, so
-- the final partial batch would be lost without this save.
if package.loaded['luacov.runner'] then
  ---@type { save_stats: fun() }
  local runner = package.loaded['luacov.runner']
  vim.api.nvim_create_autocmd('VimLeavePre', {
    callback = function() runner.save_stats() end,
  })
end

-- Busted gives `assert` its matchers only inside spec files, while a module
-- they require sees the plain Lua function. The type stubs declare only the
-- global, so the module itself does not resolve.
---@diagnostic disable-next-line: unresolved-require
local assert = require 'luassert'

--- What every spec file shares: fixture trees, the CLI run in a child Neovim,
--- and local git remotes. Each case writes a small source tree to a temporary
--- directory, runs the CLI, and then executes or inspects the output.

--- @class spec.helpers.CliResult
--- @field out string
--- @field returns string the returned module id, or `registry`
--- @field modules number

--- Temporary paths created by the current test, removed in after_each.
local created = {}

--- @param path string
local function track(path) created[#created + 1] = path end

--- Write `files` (relative path -> contents) into a fresh temporary directory.
--- The matching "-out" directory is reserved for bundles, keeping generated
--- files outside the source root, which `--out` requires.
--- @param files table<string, string>
--- @return string root
local function fixture(files)
  local root = vim.fn.tempname()
  track(root)
  track(root .. '-out')
  vim.fn.mkdir(root, 'p')
  for rel, content in pairs(files) do
    local path = root .. '/' .. rel
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local f = assert(io.open(path, 'wb'))
    f:write(content)
    f:close()
  end
  return root
end

--- @param path string
--- @return string
local function slurp(path)
  local f = assert(io.open(path, 'rb'))
  local content = f:read '*a'
  f:close()
  return content
end

--- Run the CLI in a child Neovim, so every test exercises the same entry point
--- a user does.
--- @param argv string[]
--- @param env table<string, string>? extra environment for the child
--- @return vim.SystemCompleted
local function cli(argv, env)
  local cmd = { 'nvim', '--clean' }
  -- Under `busted --coverage`, instrument the child so its CLI lines count.
  if package.loaded['luacov.runner'] then
    cmd[#cmd + 1] = '--cmd'
    cmd[#cmd + 1] = 'lua require("luacov")'
    -- The child runs too few instrumented lines to reach luacov's tick
    -- interval, and Neovim does not exit through Lua's os.exit, so save at the
    -- event Neovim does emit.
    cmd[#cmd + 1] = '--cmd'
    cmd[#cmd + 1] = 'autocmd VimLeavePre * lua require("luacov.runner").save_stats()'
  end
  cmd[#cmd + 1] = '-l'
  -- Keep this relative. luacov keys stats by the path string a chunk was loaded
  -- from, so the parent's relative `lua/nvim-bundle.lua` and the child's
  -- absolute path would appear as two files in the coverage report.
  cmd[#cmd + 1] = 'lua/nvim-bundle.lua'
  for _, arg in ipairs(argv) do
    cmd[#cmd + 1] = arg
  end
  return vim.system(cmd, { text = true, env = env }):wait()
end

--- @param stdout string
--- @return spec.helpers.CliResult
local function parse_summary(stdout)
  local modules, out, shape = stdout:match '^bundled (%d+) modules into (.-)%s+%((.-)%)%s*$'
  assert.is_truthy(modules, ('unexpected CLI output: %q'):format(stdout))
  --- @cast modules string
  --- @cast out string
  --- @cast shape string
  return {
    modules = assert(tonumber(modules)),
    out = out,
    returns = shape:match '^returns (.+)$' or shape,
  }
end

--- @param argv string[]
--- @return spec.helpers.CliResult
local function run_ok(argv)
  local proc = cli(argv)
  assert.are.equal(0, proc.code, proc.stderr)
  return parse_summary(proc.stdout or '')
end

--- @param argv string[]
--- @return string
local function run_help(argv)
  local proc = cli(argv)
  assert.are.equal(0, proc.code, proc.stderr)
  local stdout = proc.stdout or ''
  assert.is_truthy(stdout:find('Usage:', 1, true), stdout)
  return stdout
end

--- @param argv string[]
--- @param pattern string
local function run_fail(argv, pattern)
  local proc = cli(argv)
  assert.are.equal(1, proc.code, proc.stdout)
  local stderr = proc.stderr or ''
  assert.is_truthy(
    stderr:find(pattern, 1, true),
    ('expected %q in error %q'):format(pattern, stderr)
  )
end

--- Load the module under test directly with the same relative chunk name that
--- the `.busted` lpath and the CLI child use, so luacov merges every run into
--- one report row.
--- @return table
local function load_module()
  local chunk, err = loadfile 'lua/nvim-bundle.lua'
  assert.is_truthy(chunk, err)
  --- @cast chunk function
  return chunk()
end

--- @param path string
--- @return function
local function load_bundle(path)
  local chunk, err = loadstring(slurp(path), '@' .. path)
  assert.is_truthy(chunk, err)
  --- @cast chunk function
  return chunk
end

--- Bundle `root` and compile the generated file. Naming `entry` makes the
--- chunk return that module; omitting it makes the chunk return the registry.
--- The caller decides whether executing the chunk should succeed.
--- @param root string
--- @param entry string?
--- @param opts { bin?: boolean, exclude?: string[], define?: table<string, string> }?
--- @return function chunk, spec.helpers.CliResult result
local function compile_bundle(root, entry, opts)
  opts = opts or {}
  local out = root .. '-out/' .. (entry or 'registry') .. '.lua'
  local argv = { 'build', '--root', root, '--out', out }
  if opts.bin then argv[#argv + 1] = '--bin' end
  for _, glob in ipairs(opts.exclude or {}) do
    argv[#argv + 1] = '--exclude'
    argv[#argv + 1] = glob
  end
  local keys = vim.tbl_keys(opts.define or {})
  table.sort(keys)
  for _, key in ipairs(keys) do
    argv[#argv + 1] = '--define'
    argv[#argv + 1] = key .. '=' .. opts.define[key]
  end
  argv[#argv + 1] = entry

  local result = run_ok(argv)
  return load_bundle(result.out), result
end

--- Source for a module that calls `M.main()` only when it is the script, with
--- the source-versus-`arg[0]` check that real CLI modules use.
--- @param ... string lines that define `M` and `M.main` before the check
--- @return string
local function main_guarded(...)
  local lines = { ... }
  vim.list_extend(lines, {
    'local info = debug.getinfo(1, "S")',
    'local argv0 = arg and arg[0]',
    'if info and argv0 and info.source:sub(1, 1) == "@" then',
    '  local this = vim.fs.normalize(vim.fn.fnamemodify(info.source:sub(2), ":p"))',
    '  local invoked = vim.fs.normalize(vim.fn.fnamemodify(argv0, ":p"))',
    '  if this == invoked then M.main() end',
    'end',
    'return M',
    '',
  })
  return table.concat(lines, '\n')
end

--- @param path string
--- @return any
local function read_json(path) return vim.json.decode(slurp(path)) end

--- @param path string
--- @param value table
local function write_json(path, value)
  local f = assert(io.open(path, 'wb'))
  f:write(vim.json.encode(value))
  f:close()
end

--- @param cwd string
--- @param argv string[]
--- @return string stdout
local function git(cwd, argv)
  local cmd = { 'git', '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'commit.gpgsign=false' }
  vim.list_extend(cmd, argv)
  local proc = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert.are.equal(0, proc.code, proc.stderr)
  return vim.trim(proc.stdout or '')
end

--- @class spec.helpers.Remote
--- @field url string a `file://` URL, so dependency specs clone offline
--- @field commit fun(files: table<string, string>, tag?: string): string
--- @field branch fun(name: string) creates or moves `name` to the current commit

--- A local repository standing in for a dependency's remote. Each commit
--- writes `files` on top of the previous tree, so a test can tag several
--- versions or advance the `main` branch.
--- @param dir string? where to create it (default: a fresh temporary directory)
--- @return spec.helpers.Remote
local function remote(dir)
  dir = dir or fixture {}
  vim.fn.mkdir(dir, 'p')
  git(dir, { 'init', '-q', '-b', 'main' })
  return {
    url = 'file://' .. dir,
    commit = function(files, tag)
      for rel, content in pairs(files) do
        local path = dir .. '/' .. rel
        vim.fn.mkdir(vim.fs.dirname(path), 'p')
        local f = assert(io.open(path, 'wb'))
        f:write(content)
        f:close()
      end
      git(dir, { 'add', '-A' })
      git(dir, { 'commit', '-q', '--allow-empty', '-m', tag or 'commit' })
      if tag then git(dir, { 'tag', '-f', '-a', tag, '-m', tag }) end
      return git(dir, { 'rev-parse', 'HEAD' })
    end,
    branch = function(name) git(dir, { 'branch', '-f', name }) end,
  }
end

--- @return string
local function cli_version()
  local found = ((cli { '--version' }).stdout or ''):match '^nvim%-bundle (%S+)'
  return assert(found)
end

--- Require package `alias` from the registry vendored under that alias, for
--- specs about which commit was vendored rather than the bundle's shape.
--- @param project string
--- @param alias string
local function require_vendored(project, alias)
  return load_bundle(('%s/lua/myplug/vendor/%s.lua'):format(project, alias))()[alias]()
end

--- Run `install` in `project` and require it to succeed.
--- @param project string
--- @param argv string[]
--- @param env table<string, string>?
local function install(project, argv, env)
  local cmd = { '-C', project, 'install' }
  vim.list_extend(cmd, argv)
  local proc = cli(cmd, env)
  assert.are.equal(0, proc.code, proc.stderr)
end

--- Pre-load a host module, which a bundle must fall back to for any require it
--- cannot link. `rawset` keeps emmylua from inferring `package.loaded`'s value
--- type from these strings, which would flag every real module assigned there.
--- @param name string
--- @param value any
local function stub_host_module(name, value) rawset(package.loaded, name, value) end

--- Bundle `src` as the entry module `entry`, with `files` beside it, and run
--- the bundle. Returns what the module returned or the error it raised, the
--- module's emitted source, and, for an error, its line in `src`. The emitted
--- source starts on the line after the module's `__load` line, so subtracting
--- that line maps a bundle line to a source line.
--- @param src string
--- @param define table<string, string>?
--- @param files table<string, string>? other fixture files
--- @return any value, string module, number? error_line
local function run_entry(src, define, files)
  local root = fixture(vim.tbl_extend('error', { ['entry.lua'] = src }, files or {}))
  local chunk, result = compile_bundle(root, 'entry', { define = define })
  local lines = vim.split(slurp(result.out), '\n', { plain = true })
  local header = vim.fn.index(lines, '  return __load("entry", function(...)') + 1
  assert(header > 0, 'no entry module in ' .. result.out)
  -- `index` counts from 0 and `header` from 1, so this search starts on the
  -- line after the header.
  local footer = vim.fn.index(lines, '  end, ...)', header) + 1
  local module = table.concat(lines, '\n', header + 1, footer - 1)

  local ok, value = pcall(chunk)
  if ok then return value, module, nil end
  local bundle_line = assert(tonumber(tostring(value):match ':(%d+):'), tostring(value))
  return value, module, bundle_line - header
end

--- Delete every temporary path the current test created. Each spec file runs
--- this after each test.
local function remove_created()
  for _, path in ipairs(created) do
    vim.fn.delete(path, 'rf')
  end
  created = {}
end

return {
  fixture = fixture,
  slurp = slurp,
  cli = cli,
  run_ok = run_ok,
  run_help = run_help,
  run_fail = run_fail,
  load_module = load_module,
  load_bundle = load_bundle,
  compile_bundle = compile_bundle,
  main_guarded = main_guarded,
  read_json = read_json,
  write_json = write_json,
  remote = remote,
  cli_version = cli_version,
  require_vendored = require_vendored,
  install = install,
  stub_host_module = stub_host_module,
  run_entry = run_entry,
  remove_created = remove_created,
}
