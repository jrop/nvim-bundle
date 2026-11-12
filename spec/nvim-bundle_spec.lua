--- @diagnostic disable: duplicate-set-field
--- @diagnostic disable: missing-fields
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

--- Black-box tests for the bundler. Every case writes a small source tree to a
--- temporary directory, runs the CLI, and then executes or inspects the output.

--- @class CliResult
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
--- @return CliResult
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
--- @return CliResult
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
--- @param opts { bin?: boolean, exclude?: string[] }?
--- @return function chunk, CliResult result
local function compile_bundle(root, entry, opts)
  opts = opts or {}
  local out = root .. '-out/' .. (entry or 'registry') .. '.lua'
  local argv = { 'build', '--root', root, '--out', out }
  if opts.bin then argv[#argv + 1] = '--bin' end
  for _, glob in ipairs(opts.exclude or {}) do
    argv[#argv + 1] = '--exclude'
    argv[#argv + 1] = glob
  end
  argv[#argv + 1] = entry

  local result = run_ok(argv)
  return load_bundle(result.out), result
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

--- @class Remote
--- @field url string a `file://` URL, so dependency specs clone offline
--- @field commit fun(files: table<string, string>, tag?: string): string
--- @field branch fun(name: string) creates or moves `name` to the current commit

--- A local repository standing in for a dependency's remote. Each commit
--- writes `files` on top of the previous tree, so a test can tag several
--- versions or advance the `main` branch.
--- @param dir string? where to create it (default: a fresh temporary directory)
--- @return Remote
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

describe('nvim-bundle', function()
  after_each(function()
    for _, path in ipairs(created) do
      vim.fn.delete(path, 'rf')
    end
    created = {}
  end)

  describe('public API', function()
    it('exposes build and not run or main', function()
      local NvimBundle = load_module()
      local keys = vim.tbl_keys(NvimBundle)
      table.sort(keys)

      assert.are.same({ 'build' }, keys)
      assert.is_function(NvimBundle.build)
      assert.is_nil(NvimBundle.run)
      assert.is_nil(NvimBundle.main)
    end)

    it('builds a fixture through build', function()
      local root = fixture { ['entry.lua'] = 'return 1\n' }
      local out = root .. '-out/entry.lua'
      local result = load_module().build { root = root, out = out, entry = 'entry' }

      assert.are.equal(out, result.out)
      assert.are.equal(1, result.modules)
      assert.is_truthy(vim.uv.fs_stat(out))
    end)
  end)

  describe('arguments', function()
    it('requires an entry for --bin', function()
      local root = fixture { ['entry.lua'] = 'return 1\n' }
      run_fail(
        { 'build', '--bin', '--root', root, '--out', root .. '-out/x' },
        '--bin needs an entry (for example: nvim-bundle build mycli --bin)'
      )
    end)

    it(
      'rejects an unknown option',
      function() run_fail({ 'build', '--nope', 'entry' }, 'unknown or unexpected option: --nope') end
    )

    it('accepts an inline long-option value', function()
      local root = fixture { ['entry.lua'] = 'return 1\n' }
      local out = root .. '-out/entry.lua'
      local result = run_ok { 'build', '--root=' .. root, '--out=' .. out, 'entry' }

      assert.are.equal(out, result.out)
    end)

    it(
      'rejects an option with no value',
      function() run_fail({ 'build', '--root' }, 'option requires argument: --root') end
    )

    it(
      'rejects extra positional arguments',
      function() run_fail({ 'build', 'entry', 'extra' }, 'unexpected argument extra') end
    )

    it('lists the subcommands in the top-level help', function()
      for _, flag in ipairs { '--help', '-h' } do
        local help = run_help { flag }
        assert.is_truthy(help:find('Usage: nvim-bundle <command>', 1, true), help)
        assert.is_truthy(help:find('build', 1, true), help)
      end
    end)

    it('returns build help without bundling', function()
      for _, flag in ipairs { '--help', '-h' } do
        local help = run_help { 'build', flag }
        assert.is_truthy(help:find('Usage: nvim-bundle build [<entry>]', 1, true), help)
        assert.is_truthy(help:find('--root', 1, true), help)
      end
    end)

    it('rejects an entry given without a subcommand', function()
      local root = fixture { ['entry.lua'] = 'return 1\n' }
      run_fail({ '--root', root, 'entry' }, 'unknown or unexpected option: --root')
      run_fail({ 'entry' }, 'unknown command: entry')
    end)

    it(
      'requires a subcommand',
      function() run_fail({}, 'missing command (for example: nvim-bundle build myplugin)') end
    )

    it('prints both versions', function()
      for _, flag in ipairs { '--version', '-V' } do
        local proc = cli { flag }
        assert.are.equal(0, proc.code, proc.stderr)
        local stdout = proc.stdout or ''
        assert.is_truthy(stdout:match '^nvim%-bundle %d+%.%d+%.%d+ %(Neovim %d+%.%d+%.%d+', stdout)
      end
    end)

    it('reports an entry file that is not on disk', function()
      local root = fixture { ['present.lua'] = 'return 1\n' }
      run_fail({ 'build', '--root', root, 'missing' }, 'module "missing" is not in the bundle')
    end)
  end)

  describe('output', function()
    it('returns the named module', function()
      local root = fixture { ['entry.lua'] = 'return { answer = 42 }\n' }
      local chunk, result = compile_bundle(root, 'entry')

      assert.are.equal('entry', result.returns)
      assert.are.equal(42, chunk().answer)
      assert.is_truthy(slurp(result.out):find('\n-- returns: entry\n', 1, true))
    end)

    it('returns a registry with a loader for each module when none is named', function()
      local root = fixture { ['entry.lua'] = 'return { answer = 42 }\n' }
      local chunk, result = compile_bundle(root)
      local registry = chunk()

      assert.are.equal('registry', result.returns)
      assert.is_function(registry['entry'])
      assert.are.equal(42, registry['entry']().answer)
      assert.is_truthy(slurp(result.out):find('\n-- returns: registry\n', 1, true))
    end)

    it('names a registry after the one package under the root', function()
      local project = fixture { ['lua/pkg/init.lua'] = 'return 1\n' }
      local result = run_ok { '-C', project, 'build' }

      assert.are.equal('dist/pkg.lua', result.out)
      assert.are.equal('registry', result.returns)
    end)

    it('asks for --out when a registry has no single package name', function()
      local project = fixture { ['lua/a.lua'] = 'return 1\n', ['lua/b.lua'] = 'return 2\n' }
      run_fail({ '-C', project, 'build' }, 'pass --out')
    end)

    it('resolves an entry given as a dotted module path', function()
      local root = fixture { ['pkg/mod.lua'] = "return 'pkg-mod'\n" }
      local chunk = compile_bundle(root, 'pkg.mod')
      assert.are.equal('pkg-mod', chunk())
    end)

    it('resolves an entry directory via init.lua', function()
      local root = fixture { ['pkg/init.lua'] = "return 'pkg-init'\n" }
      local chunk = compile_bundle(root, 'pkg')
      assert.are.equal('pkg-init', chunk())
    end)

    it('strips a UTF-8 BOM and a shebang from module sources', function()
      local root = fixture {
        ['entry.lua'] = '\239\187\191#!/usr/bin/env -S nvim --clean -l\nreturn 7\n',
      }
      local chunk = compile_bundle(root, 'entry')
      assert.are.equal(7, chunk())
    end)

    it('bundles required modules instead of using the host searcher', function()
      local root = fixture {
        ['entry.lua'] = "return require 'dep'\n",
        ['dep.lua'] = "return { from = 'fixture' }\n",
      }
      local entry = compile_bundle(root, 'entry')()
      assert.are.equal('fixture', entry.from)
    end)

    it('falls back to the host require for unknown modules', function()
      package.loaded['bundle_host_probe'] = 'from-host'
      local ok, value = pcall(function()
        local root = fixture { ['entry.lua'] = "return require 'bundle_host_probe'\n" }
        return compile_bundle(root, 'entry')()
      end)
      package.loaded['bundle_host_probe'] = nil
      assert.is_true(ok, tostring(value))
      assert.are.equal('from-host', value)
    end)

    it('keeps a flat module and a same-named init module distinct', function()
      local root = fixture {
        ['entry.lua'] = "return { flat = require 'shadow', init = require 'shadow.init' }\n",
        ['shadow.lua'] = "return 'flat'\n",
        ['shadow/init.lua'] = "return 'init'\n",
      }
      local entry = compile_bundle(root, 'entry')()
      assert.are.equal('flat', entry.flat)
      assert.are.equal('init', entry.init)
    end)

    it('reports a require cycle instead of recursing forever', function()
      local root = fixture {
        ['entry.lua'] = "return require 'loop'\n",
        ['loop.lua'] = "return require 'loop'\n",
      }
      local chunk = compile_bundle(root, 'entry')
      local ok, err = pcall(function() return chunk() end)
      assert.is_false(ok)
      assert.is_truthy(
        tostring(err):find("loop or previous error loading module 'loop'", 1, true),
        tostring(err)
      )
    end)
  end)

  describe('bin bundles', function()
    it('starts with a shebang and modeline', function()
      local root = fixture { ['entry.lua'] = 'return 1\n' }
      local _, result = compile_bundle(root, 'entry', { bin = true })
      local first, second = slurp(result.out):match '^([^\n]*)\n([^\n]*)\n'

      assert.are.equal('#!/usr/bin/env -S nvim --clean -l', first)
      assert.are.equal('-- vim: set ft=lua:', second)
    end)

    it('runs the entry module when executed as the main script', function()
      local root = fixture {
        ['entry.lua'] = table.concat({
          'local M = {}',
          'function M.main() io.stdout:write("entry-main\\n") end',
          'local info = debug.getinfo(1, "S")',
          'local argv0 = arg and arg[0]',
          'if info and argv0 and info.source:sub(1, 1) == "@" then',
          '  local this = vim.fs.normalize(vim.fn.fnamemodify(info.source:sub(2), ":p"))',
          '  local invoked = vim.fs.normalize(vim.fn.fnamemodify(argv0, ":p"))',
          '  if this == invoked then M.main() end',
          'end',
          'return M',
          '',
        }, '\n'),
      }
      local _, result = compile_bundle(root, 'entry', { bin = true })
      local proc = vim.system({ 'nvim', '--clean', '-l', result.out }, { text = true }):wait()

      assert.are.equal(0, proc.code, proc.stderr)
      assert.are.equal('entry-main\n', proc.stdout)
    end)

    it('returns the entry module when loaded as a library', function()
      local root = fixture {
        ['entry.lua'] = table.concat({
          'local M = { marker = "entry" }',
          'function M.main() error("main must not run") end',
          'local info = debug.getinfo(1, "S")',
          'local argv0 = arg and arg[0]',
          'if info and argv0 and info.source:sub(1, 1) == "@" then',
          '  local this = vim.fs.normalize(vim.fn.fnamemodify(info.source:sub(2), ":p"))',
          '  local invoked = vim.fs.normalize(vim.fn.fnamemodify(argv0, ":p"))',
          '  if this == invoked then M.main() end',
          'end',
          'return M',
          '',
        }, '\n'),
      }
      local _, result = compile_bundle(root, 'entry', { bin = true })
      local entry = load_bundle(result.out)()

      assert.are.equal('entry', entry.marker)
      assert.is_function(entry.main)
    end)

    it('makes the output executable', function()
      local root = fixture { ['entry.lua'] = 'return 1\n' }
      local _, result = compile_bundle(root, 'entry', { bin = true })
      local stat = assert(vim.uv.fs_stat(result.out))

      assert.is_truthy(bit.band(stat.mode, 64) ~= 0)
    end)

    it('bundles nvim-bundle itself into a working executable', function()
      local out = fixture {} .. '-out/nvim-bundle'
      run_ok { 'build', '--root', 'lua', '--out', out, '--bin', 'nvim-bundle' }

      local proc = vim.system({ 'nvim', '--clean', '-l', out, '--version' }, { text = true }):wait()
      assert.are.equal(0, proc.code, proc.stderr)
      assert.is_truthy(
        (proc.stdout or ''):match '^nvim%-bundle %d+%.%d+%.%d+ %(Neovim %d+%.%d+%.%d+'
      )

      local entry = load_bundle(out)()
      assert.is_function(entry.build)
    end)
  end)

  describe('static requires', function()
    it('resolves pcall(require, ...) to a bundled module', function()
      local root = fixture {
        ['entry.lua'] = "local ok, dep = pcall(require, 'dep')\nreturn { ok = ok, dep = dep }\n",
        ['dep.lua'] = "return 'dep'\n",
      }
      local entry = compile_bundle(root, 'entry')()
      assert.is_true(entry.ok)
      assert.are.equal('dep', entry.dep)
    end)

    it('resolves xpcall(require, handler, ...) to a bundled module', function()
      local root = fixture {
        ['entry.lua'] = "local ok, dep = xpcall(require, function(err) return err end, 'dep')\n"
          .. 'return { ok = ok, dep = dep }\n',
        ['dep.lua'] = "return 'dep'\n",
      }
      local entry = compile_bundle(root, 'entry')()
      assert.is_true(entry.ok)
      assert.are.equal('dep', entry.dep)
    end)

    it('leaves a shadowed require dynamic', function()
      local root = fixture {
        ['entry.lua'] = "local function require(name) return 'local-' .. name end\n"
          .. "return require 'dep'\n",
        ['dep.lua'] = "return 'bundled'\n",
      }
      assert.are.equal('local-dep', compile_bundle(root, 'entry')())
    end)

    it('leaves a multi-line require dynamic', function()
      local root = fixture {
        ['entry.lua'] = "return require(\n  'dep'\n)\n",
        ['dep.lua'] = "return 'bundled'\n",
      }
      package.loaded.dep = 'host-dep'
      local ok, value = pcall(function() return compile_bundle(root, 'entry')() end)
      package.loaded.dep = nil
      assert.is_true(ok, tostring(value))
      assert.are.equal('host-dep', value)
    end)

    it('resolves escaped and long-string literals', function()
      local root = fixture {
        ['entry.lua'] = "return { escaped = require 'pkg\\46util', long = require [[pkg.util]] }\n",
        ['pkg/util.lua'] = "return { name = 'util' }\n",
      }
      local value = compile_bundle(root, 'entry')()
      assert.are.equal('util', value.escaped.name)
      assert.are.equal(value.escaped, value.long)
    end)

    it('passes the module id as a vararg', function()
      local root = fixture {
        ['entry.lua'] = "return require 'dep'\n",
        ['dep.lua'] = 'return ...\n',
      }
      assert.are.equal('dep', compile_bundle(root, 'entry')())
    end)

    it('returns true for a module with no return value, as require does', function()
      local root = fixture {
        ['entry.lua'] = "return require 'side_effect'\n",
        ['side_effect.lua'] = 'local value = 1\n',
      }
      assert.is_true(compile_bundle(root, 'entry')())
    end)
  end)

  describe('registry', function()
    it('loads each bundled module once and returns its value', function()
      local root = fixture {
        ['entry.lua'] = "local dep = require 'dep'\nreturn { dep = dep }\n",
        ['dep.lua'] = "return { name = 'dep' }\n",
      }
      local registry = compile_bundle(root)()

      assert.are.equal(registry['entry']().dep, registry['dep']())
      assert.are.equal('dep', registry['dep']().name)
    end)

    it('contains every bundled module id', function()
      local root = fixture {
        ['entry.lua'] = "return { dep = require 'dep' }\n",
        ['dep.lua'] = "return 'dep'\n",
      }
      local registry = compile_bundle(root)()

      assert.is_function(registry['entry'])
      assert.is_function(registry['dep'])
      assert.is_nil(registry['bundle_entry_host_probe'])
    end)

    it('returns true for a bundled module with no return value', function()
      local root = fixture {
        ['entry.lua'] = "return { side = require 'side_effect' }\n",
        ['side_effect.lua'] = 'local value = 1\n',
      }
      local registry = compile_bundle(root)()

      assert.is_true(registry['entry']().side)
      assert.is_true(registry['side_effect']())
    end)
  end)

  describe('module function names', function()
    it('derives each name from the module id', function()
      local root = fixture {
        ['entry.lua'] = "return { util = require 'myplugin.util', math = require 'my-plugin.math' }\n",
        ['myplugin/util.lua'] = "return 'util'\n",
        ['my-plugin/math.lua'] = "return 'math'\n",
      }
      local _, result = compile_bundle(root, 'entry')
      local content = slurp(result.out)

      assert.is_truthy(content:find('__mods._entry = function', 1, true))
      assert.is_truthy(content:find('__mods._myplugin_util = function', 1, true))
      assert.is_truthy(content:find('__mods._my_plugin_math = function', 1, true))
      assert.is_truthy(content:find('__mods._myplugin_util("myplugin.util")', 1, true))
    end)

    it('disambiguates ids that sanitize to the same name', function()
      local root = fixture {
        ['entry.lua'] = "return { dotted = require 'a.b', underscored = require 'a_b' }\n",
        ['a/b.lua'] = "return 'dotted'\n",
        ['a_b.lua'] = "return 'underscored'\n",
      }
      local chunk, result = compile_bundle(root, 'entry')
      local content = slurp(result.out)

      assert.is_truthy(content:find('__mods._a_b = function', 1, true))
      assert.is_truthy(content:find('__mods._a_b_2 = function', 1, true))
      local entry = chunk()
      assert.are.equal('dotted', entry.dotted)
      assert.are.equal('underscored', entry.underscored)
    end)

    it('escapes a name that would start with a digit', function()
      local root = fixture {
        ['entry.lua'] = "return require '3d'\n",
        ['3d.lua'] = "return '3d'\n",
      }
      local _, result = compile_bundle(root, 'entry')
      assert.is_truthy(slurp(result.out):find('__mods._3d = function', 1, true))
    end)

    it('escapes a Lua keyword used as a module name', function()
      local root = fixture {
        ['entry.lua'] = "return require 'end'\n",
        ['end.lua'] = "return 'end'\n",
      }
      local _, result = compile_bundle(root, 'entry')
      assert.is_truthy(slurp(result.out):find('__mods._end = function', 1, true))
    end)
  end)

  describe('excludes', function()
    it('skips files matching an exclude glob', function()
      local root = fixture {
        ['entry.lua'] = "return { dep = require 'dep', skip = require 'vendor.skip' }\n",
        ['dep.lua'] = "return 'bundled-dep'\n",
        ['vendor/skip.lua'] = "return 'bundled-skip'\n",
      }
      package.loaded.dep = 'host-dep'
      local ok, value = pcall(function()
        local chunk, result = compile_bundle(root, 'entry', { exclude = { 'dep.lua' } })
        assert.are.equal(2, result.modules)
        return chunk()
      end)
      package.loaded.dep = nil
      assert.is_true(ok, tostring(value))
      assert.are.equal('host-dep', value.dep)
      assert.are.equal('bundled-skip', value.skip)
    end)

    it('rejects an entry that is excluded', function()
      local root = fixture { ['entry.lua'] = 'return 1\n' }
      run_fail({
        'build',
        '--root',
        root,
        '--out',
        root .. '-out/entry.lua',
        '--exclude',
        'entry.lua',
        'entry',
      }, 'module "entry" is not in the bundle')
    end)

    it('rejects an invalid exclude glob', function()
      -- Neovim 0.10 and 0.11 accept "[" as a literal, so only newer versions
      -- can reach the validation error.
      if pcall(vim.glob.to_lpeg, '[') then return end
      local root = fixture { ['entry.lua'] = 'return 1\n' }
      run_fail({ 'build', '--root', root, '--exclude', '[', 'entry' }, 'invalid --exclude glob')
    end)
  end)

  describe('output path', function()
    it('creates missing output directories', function()
      local root = fixture { ['entry.lua'] = 'return 1\n' }
      local out = root .. '-out/nested/deeper/entry.lua'
      local result = run_ok { 'build', '--root', root, '--out', out, 'entry' }
      assert.are.equal(out, result.out)
      assert.is_truthy(vim.uv.fs_stat(out))
    end)

    it('rejects an output path inside the source root', function()
      local root = fixture { ['entry.lua'] = 'return 1\n' }
      run_fail(
        { 'build', '--root', root, '--out', root .. '/dist/entry.lua', 'entry' },
        'must be outside the source root'
      )
    end)
  end)

  describe('validation', function()
    it('names the source file of a syntax error', function()
      local root = fixture {
        ['entry.lua'] = 'return 1\n',
        ['broken.lua'] = 'return {\n',
      }
      run_fail(
        { 'build', '--root', root, '--out', root .. '-out/entry.lua', 'entry' },
        'syntax error in ' .. root .. '/broken.lua'
      )
    end)
  end)

  describe('types', function()
    --- @param bundle string
    --- @param consumer string
    --- @return string
    local function check_types(bundle, consumer)
      local workspace = fixture {
        ['.emmyrc.json'] = '{ "runtime": { "version": "LuaJIT" } }\n',
        ['lua/bundled_lib.lua'] = bundle,
        ['consumer.lua'] = consumer,
      }

      local proc = vim.system({ 'emmylua_check', '.' }, { cwd = workspace, text = true }):wait()
      return (proc.stdout or '') .. '\n' .. (proc.stderr or '')
    end

    --- @return boolean
    local function can_check_types()
      if vim.fn.executable 'emmylua_check' == 0 then
        pending 'emmylua_check is not installed'
        return false
      end
      return true
    end

    local consumer = table.concat({
      "local lib = require 'bundled_lib'",
      '---@type string',
      'local s = lib.util.answer',
      'print(s)',
      '',
    }, '\n')

    local util = '---@class Util\n---@field answer integer\nreturn { answer = 42 }\n'

    it('preserves the type of a required module in the entry', function()
      if not can_check_types() then return end

      local root = fixture {
        ['entry.lua'] = "local util = require 'util'\nreturn { util = util }\n",
        ['util.lua'] = util,
      }
      local _, result = compile_bundle(root, 'entry')
      local output = check_types(slurp(result.out), consumer)

      assert.is_truthy(output:find('consumer.lua', 1, true), output)
      assert.is_truthy(output:find('assign-type-mismatch', 1, true), output)
    end)

    it('types a required bundle as its entry, never nil', function()
      if not can_check_types() then return end

      local root = fixture {
        ['entry.lua'] = "local util = require 'util'\nreturn { util = util }\n",
        ['util.lua'] = util,
      }
      local _, result = compile_bundle(root, 'entry')
      local output = check_types(
        slurp(result.out),
        "local lib = require 'bundled_lib'\nprint(lib.util.answer + 1)\n"
      )

      assert.is_nil(output:find('need-check-nil', 1, true), output)
    end)

    it('preserves types through pcall(require, ...)', function()
      -- emmylua_check 0.25.1 infers a module's type through pcall in only
      -- about half its runs, with any cache shape and on one thread, so a
      -- result here would say nothing about the bundle.
      pending 'emmylua_check is nondeterministic through pcall'
      if not can_check_types() then return end

      local root = fixture {
        ['entry.lua'] = "local ok, util = pcall(require, 'util')\nreturn { ok = ok, util = util }\n",
        ['util.lua'] = util,
      }
      local _, result = compile_bundle(root, 'entry')
      local output = check_types(slurp(result.out), consumer)

      assert.is_truthy(output:find('consumer.lua', 1, true), output)
      assert.is_truthy(
        output:find('assign-type-mismatch', 1, true) or output:find('need-check-nil', 1, true),
        output
      )
    end)

    it('preserves the type of a module through the registry', function()
      if not can_check_types() then return end

      local root = fixture {
        ['entry.lua'] = "local util = require 'util'\nreturn { util = util }\n",
        ['util.lua'] = util,
      }
      local _, result = compile_bundle(root)
      local output = check_types(
        slurp(result.out),
        table.concat({
          "local bundle = require 'bundled_lib'",
          '---@type string',
          "local s = bundle['util']().answer",
          'print(s)',
          '',
        }, '\n')
      )

      assert.is_truthy(output:find('consumer.lua', 1, true), output)
      assert.is_truthy(output:find('assign-type-mismatch', 1, true), output)
    end)
  end)

  describe('determinism', function()
    -- Dependencies are built locally and pinned by hash, so the same tree must
    -- produce the same bytes wherever it is checked out.
    it('builds identical bytes from two checkouts of the same tree', function()
      local files = {
        ['lua/pkg/init.lua'] = 'return require "pkg.a_b" .. require "pkg.a.b"\n',
        ['lua/pkg/a_b.lua'] = 'return "underscore"\n',
        ['lua/pkg/a/b.lua'] = 'return "dotted"\n',
        ['lua/pkg/z/deep/mod.lua'] = 'return 1\n',
      }
      local outputs = {}
      for i = 1, 2 do
        local checkout = fixture(files)
        local out = checkout .. '-out/pkg.lua'
        run_ok { 'build', '--root', checkout .. '/lua', '--out', out, 'pkg' }
        outputs[i] = slurp(out)
      end

      assert.are.equal(outputs[1], outputs[2])
    end)
  end)

  describe('install', function()
    it('vendors a dependency built from its tag', function()
      local dep = remote()
      local commit = dep.commit({
        ['lua/dep/init.lua'] = 'return { util = require "dep.util" }\n',
        ['lua/dep/util.lua'] = 'return "dep-util"\n',
      }, 'v1.0.0')
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

      install(project, { dep.url .. '@v1.0.0' })

      -- With no entry, the bundle is a registry, as `build` makes, and
      -- `dep.util` resolves statically although the host cannot see it.
      local vendored = project .. '/lua/myplug/vendor/dep.lua'
      assert.are.equal('dep-util', load_bundle(vendored)()['dep']().util)
      assert.are.same({
        name = 'myplug',
        dependencies = { dep = dep.url .. '@v1.0.0' },
      }, read_json(project .. '/nvim-bundle.json'))
      assert.are.same({
        lock_version = 1,
        dependencies = {
          dep = {
            source = dep.url,
            ref = 'v1.0.0',
            kind = 'tag',
            commit = commit,
            built_with = cli_version(),
            sha256 = vim.fn.sha256(slurp(vendored)),
          },
        },
      }, read_json(project .. '/nvim-bundle.lock.json'))
    end)

    it("ignores the dependency's own nvim-bundle.json", function()
      local dep = remote()
      dep.commit({
        ['nvim-bundle.json'] = vim.json.encode {
          name = 'other',
          build = { entry = 'dep', bin = true },
        },
        ['lua/dep/init.lua'] = 'return "dep"\n',
      }, 'v1.0.0')
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
      install(project, { dep.url .. '@v1.0.0' })

      local vendored = project .. '/lua/myplug/vendor/dep.lua'
      assert.is_nil(slurp(vendored):match '^#!')
      assert.are.equal('dep', require_vendored(project, 'dep'))
    end)

    it('expands owner/repo to its GitHub URL', function()
      -- git rewrites the GitHub URL to a local directory, so the shorthand is
      -- tested through the same clone a real install runs.
      local hub = fixture {}
      local dep = remote(hub .. '/jrop/dep.nvim')
      dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
      local env = {
        GIT_CONFIG_COUNT = '1',
        GIT_CONFIG_KEY_0 = 'url.file://' .. hub .. '/.insteadOf',
        GIT_CONFIG_VALUE_0 = 'https://github.com/',
      }
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

      install(project, { 'jrop/dep.nvim@v1.0.0' }, env)

      assert.are.equal('dep', require_vendored(project, 'dep'))
      assert.are.equal(
        'jrop/dep.nvim@v1.0.0',
        read_json(project .. '/nvim-bundle.json').dependencies.dep
      )
      assert.are.equal(
        'https://github.com/jrop/dep.nvim',
        read_json(project .. '/nvim-bundle.lock.json').dependencies.dep.source
      )
    end)

    it('resolves a missing tag to the newest stable tag', function()
      local dep = remote()
      dep.commit({ ['lua/dep/init.lua'] = 'return "v0.2.0"\n' }, 'v0.2.0')
      dep.commit({ ['lua/dep/init.lua'] = 'return "v0.10.0"\n' }, 'v0.10.0')
      dep.commit({ ['lua/dep/init.lua'] = 'return "v0.11.0-rc1"\n' }, 'v0.11.0-rc1')
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

      install(project, { dep.url })

      assert.are.equal('v0.10.0', require_vendored(project, 'dep'))
      assert.are.equal(
        dep.url .. '@v0.10.0',
        read_json(project .. '/nvim-bundle.json').dependencies.dep
      )
    end)

    it('follows a branch named after @', function()
      local dep = remote()
      local old = dep.commit { ['lua/dep/init.lua'] = 'return "old"\n' }
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
      install(project, { dep.url .. '@main' })

      local locked = read_json(project .. '/nvim-bundle.lock.json').dependencies.dep
      assert.are.equal('main', locked.ref)
      assert.are.equal('branch', locked.kind)
      assert.are.equal(old, locked.commit)

      local new = dep.commit { ['lua/dep/init.lua'] = 'return "new"\n' }
      local proc = cli { '-C', project, 'update' }
      assert.are.equal(0, proc.code, proc.stderr)

      assert.are.equal(('updated dep %s -> %s\n'):format(old:sub(1, 7), new:sub(1, 7)), proc.stdout)
      assert.are.equal('new', require_vendored(project, 'dep'))
      assert.are.equal(
        dep.url .. '@main',
        read_json(project .. '/nvim-bundle.json').dependencies.dep
      )
    end)

    it('pins a full commit SHA named after @', function()
      local dep = remote()
      local first = dep.commit { ['lua/dep/init.lua'] = 'return "first"\n' }
      dep.commit { ['lua/dep/init.lua'] = 'return "second"\n' }
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

      install(project, { dep.url .. '@' .. first })

      assert.are.equal('first', require_vendored(project, 'dep'))
      local locked = read_json(project .. '/nvim-bundle.lock.json').dependencies.dep
      assert.are.equal('rev', locked.kind)
      assert.are.equal(first, locked.commit)
      local proc = cli { '-C', project, 'outdated' }
      assert.are.equal(('dep is pinned to %s\n'):format(first:sub(1, 7)), proc.stdout)
    end)

    it('prefers the tag when a tag and a branch share a name', function()
      local dep = remote()
      dep.commit({ ['lua/dep/init.lua'] = 'return "tag"\n' }, 'same')
      dep.commit { ['lua/dep/init.lua'] = 'return "branch"\n' }
      dep.branch 'same'
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

      install(project, { dep.url .. '@same' })

      assert.are.equal('tag', require_vendored(project, 'dep'))
      assert.are.equal('tag', read_json(project .. '/nvim-bundle.lock.json').dependencies.dep.kind)
    end)

    it('rejects an @ref that is neither a tag nor a branch', function()
      local dep = remote()
      dep.commit { ['lua/dep/init.lua'] = 'return "dep"\n' }
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

      run_fail(
        { '-C', project, 'install', dep.url .. '@nope' },
        'nope is neither a tag nor a branch of ' .. dep.url
      )
    end)

    it('builds with the entry, root, and excludes given on the command line', function()
      local dep = remote()
      local commit = dep.commit({
        ['src/dep/init.lua'] = 'return { core = require "dep.core" }\n',
        ['src/dep/core.lua'] = 'return "core"\n',
        ['src/dep/_test/core_spec.lua'] = 'error "bundled a test"\n',
      }, 'v1.0.0')
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

      local proc = cli {
        '-C',
        project,
        'install',
        dep.url .. '@v1.0.0',
        'dep.core',
        '--root',
        'src',
        '--exclude',
        '**/_test/**',
      }
      assert.are.equal(0, proc.code, proc.stderr)
      assert.are.equal('installed dep into lua/myplug/vendor/dep.lua\n', proc.stdout)

      local vendored = project .. '/lua/myplug/vendor/dep.lua'
      assert.are.equal('core', load_bundle(vendored)())
      assert.is_nil(slurp(vendored):find('bundled a test', 1, true))
      local settings = { entry = 'dep.core', root = 'src', exclude = { '**/_test/**' } }
      assert.are.same(
        vim.tbl_extend('error', settings, { repo = dep.url, ref = 'v1.0.0' }),
        read_json(project .. '/nvim-bundle.json').dependencies.dep
      )
      assert.are.same(
        vim.tbl_extend('error', settings, {
          source = dep.url,
          ref = 'v1.0.0',
          kind = 'tag',
          commit = commit,
          built_with = cli_version(),
          sha256 = vim.fn.sha256(slurp(vendored)),
        }),
        read_json(project .. '/nvim-bundle.lock.json').dependencies.dep
      )

      -- The recorded settings rebuild the same bytes from the lock.
      local bytes = slurp(vendored)
      os.remove(vendored)
      install(project, {})
      assert.are.equal(bytes, slurp(vendored))
    end)

    it('builds with the settings an object entry records', function()
      local dep = remote()
      dep.commit({
        ['src/dep/init.lua'] = 'return { core = require "dep.core" }\n',
        ['src/dep/core.lua'] = 'return "core"\n',
      }, 'v1.0.0')
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
      write_json(project .. '/nvim-bundle.json', {
        dependencies = {
          dep = { repo = dep.url, ref = 'v1.0.0', root = 'src', entry = 'dep.core' },
        },
      })

      install(project, {})

      assert.are.equal('core', load_bundle(project .. '/lua/myplug/vendor/dep.lua')())
    end)

    it('refuses to overwrite a vendored file that install did not create', function()
      local dep = remote()
      dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
      local project = fixture {
        ['lua/myplug/init.lua'] = 'return {}\n',
        ['lua/myplug/vendor/dep.lua'] = 'return "mine"\n',
      }

      run_fail(
        { '-C', project, 'install', dep.url .. '@v1.0.0' },
        'lua/myplug/vendor/dep.lua exists but is not in the lock; move it, pass --as, or pass --force'
      )
      assert.are.equal('return "mine"\n', slurp(project .. '/lua/myplug/vendor/dep.lua'))
    end)

    it('overwrites a vendored file that install did not create under --force', function()
      local dep = remote()
      dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
      local project = fixture {
        ['lua/myplug/init.lua'] = 'return {}\n',
        ['lua/myplug/vendor/dep.lua'] = 'return "mine"\n',
      }

      install(project, { dep.url .. '@v1.0.0', '--force' })

      assert.are.equal('dep', require_vendored(project, 'dep'))
      assert.is_truthy(read_json(project .. '/nvim-bundle.lock.json').dependencies.dep)
    end)
  end)

  describe('install without arguments', function()
    it('rebuilds a missing vendored file from its locked commit', function()
      local dep = remote()
      dep.commit({ ['lua/dep/init.lua'] = 'return "original"\n' }, 'v1.0.0')
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
      install(project, { dep.url .. '@v1.0.0' })
      local vendored = project .. '/lua/myplug/vendor/dep.lua'
      local original = slurp(vendored)

      -- Moving the tag must not change what the lock restores.
      dep.commit({ ['lua/dep/init.lua'] = 'return "moved"\n' }, 'v1.0.0')
      os.remove(vendored)
      install(project, {})

      assert.are.equal(original, slurp(vendored))
    end)

    it('resolves an entry whose manifest tag was edited', function()
      local dep = remote()
      dep.commit({ ['lua/dep/init.lua'] = 'return "v0.1.0"\n' }, 'v0.1.0')
      dep.commit({ ['lua/dep/init.lua'] = 'return "v0.2.0"\n' }, 'v0.2.0')
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
      install(project, { dep.url .. '@v0.1.0' })

      local manifest = read_json(project .. '/nvim-bundle.json')
      manifest.dependencies.dep = dep.url .. '@v0.2.0'
      write_json(project .. '/nvim-bundle.json', manifest)
      install(project, {})

      assert.are.equal('v0.2.0', require_vendored(project, 'dep'))
      assert.are.equal(
        'v0.2.0',
        read_json(project .. '/nvim-bundle.lock.json').dependencies.dep.ref
      )
    end)

    it('needs no network when every vendored file matches the lock', function()
      local dep = remote()
      dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
      install(project, { dep.url .. '@v1.0.0' })
      vim.fn.delete((dep.url:gsub('^file://', '')), 'rf')

      local proc = cli { '-C', project, 'install' }
      assert.are.equal(0, proc.code, proc.stderr)
      assert.are.equal('dependencies are up to date\n', proc.stdout)
    end)

    it('fails under --frozen instead of changing anything', function()
      local dep = remote()
      dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
      install(project, { dep.url .. '@v1.0.0' })
      install(project, { '--frozen' })

      local vendored = project .. '/lua/myplug/vendor/dep.lua'
      local f = assert(io.open(vendored, 'wb'))
      f:write 'return "edited"\n'
      f:close()
      local lock = slurp(project .. '/nvim-bundle.lock.json')

      run_fail({ '-C', project, 'install', '--frozen' }, 'would restore dep')
      assert.are.equal('return "edited"\n', slurp(vendored))
      assert.are.equal(lock, slurp(project .. '/nvim-bundle.lock.json'))
    end)

    it('removes a vendored file whose dependency left the manifest', function()
      local keep, drop = remote(), remote()
      keep.commit({ ['lua/keep/init.lua'] = 'return "keep"\n' }, 'v1.0.0')
      drop.commit({ ['lua/drop/init.lua'] = 'return "drop"\n' }, 'v1.0.0')
      local project = fixture {
        ['lua/myplug/init.lua'] = 'return {}\n',
        ['lua/myplug/vendor/handwritten.lua'] = 'return "mine"\n',
      }
      install(project, { keep.url .. '@v1.0.0' })
      install(project, { drop.url .. '@v1.0.0' })

      write_json(project .. '/nvim-bundle.json', {
        name = 'myplug',
        dependencies = { keep = keep.url .. '@v1.0.0' },
      })
      install(project, {})

      local vendor_dir = project .. '/lua/myplug/vendor/'
      assert.is_nil(vim.uv.fs_stat(vendor_dir .. 'drop.lua'))
      assert.is_truthy(vim.uv.fs_stat(vendor_dir .. 'keep.lua'))
      assert.is_truthy(vim.uv.fs_stat(vendor_dir .. 'handwritten.lua'))
      assert.are.same(
        { 'keep' },
        vim.tbl_keys(read_json(project .. '/nvim-bundle.lock.json').dependencies)
      )
    end)
  end)

  describe('remove', function()
    it('deletes the vendored file and both entries', function()
      local dep = remote()
      dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
      install(project, { dep.url .. '@v1.0.0' })

      local proc = cli { '-C', project, 'remove', 'dep' }
      assert.are.equal(0, proc.code, proc.stderr)

      assert.is_nil(vim.uv.fs_stat(project .. '/lua/myplug/vendor/dep.lua'))
      assert.is_nil(next(read_json(project .. '/nvim-bundle.json').dependencies))
      assert.is_nil(next(read_json(project .. '/nvim-bundle.lock.json').dependencies))
    end)

    it(
      'rejects an alias that is not a dependency',
      function() run_fail({ '-C', fixture {}, 'remove', 'nope' }, 'nope is not a dependency') end
    )
  end)

  describe('update', function()
    it('moves a tagged dependency to its newest stable tag', function()
      local dep = remote()
      dep.commit({ ['lua/dep/init.lua'] = 'return "v0.1.0"\n' }, 'v0.1.0')
      dep.commit({ ['lua/dep/init.lua'] = 'return "v0.2.0"\n' }, 'v0.2.0')
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
      install(project, { dep.url .. '@v0.1.0' })

      local proc = cli { '-C', project, 'update' }
      assert.are.equal(0, proc.code, proc.stderr)

      assert.are.equal('updated dep v0.1.0 -> v0.2.0\n', proc.stdout)
      assert.are.equal('v0.2.0', require_vendored(project, 'dep'))
      assert.are.equal(
        dep.url .. '@v0.2.0',
        read_json(project .. '/nvim-bundle.json').dependencies.dep
      )
    end)

    it('moves a branch to its new head and leaves a rev alone', function()
      local tracked, pinned = remote(), remote()
      local old = tracked.commit { ['lua/tracked/init.lua'] = 'return "old"\n' }
      local rev = pinned.commit { ['lua/pinned/init.lua'] = 'return "pinned"\n' }
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
      write_json(project .. '/nvim-bundle.json', {
        dependencies = {
          tracked = tracked.url .. '@main',
          pinned = pinned.url .. '@' .. rev,
        },
      })
      install(project, {})
      local new = tracked.commit { ['lua/tracked/init.lua'] = 'return "new"\n' }
      pinned.commit { ['lua/pinned/init.lua'] = 'return "later"\n' }

      local proc = cli { '-C', project, 'update' }
      assert.are.equal(0, proc.code, proc.stderr)

      assert.are.equal(
        ('updated tracked %s -> %s\n'):format(old:sub(1, 7), new:sub(1, 7)),
        proc.stdout
      )
      assert.are.equal('new', require_vendored(project, 'tracked'))
      assert.are.equal('pinned', require_vendored(project, 'pinned'))
    end)
  end)

  describe('outdated', function()
    it('lists newer tags and branch heads without changing anything', function()
      local tagged, tracked, pinned = remote(), remote(), remote()
      tagged.commit({ ['lua/tagged/init.lua'] = 'return 1\n' }, 'v0.1.0')
      tagged.commit({ ['lua/tagged/init.lua'] = 'return 2\n' }, 'v0.2.0')
      local old = tracked.commit { ['lua/tracked/init.lua'] = 'return 1\n' }
      local rev = pinned.commit { ['lua/pinned/init.lua'] = 'return 1\n' }
      local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
      write_json(project .. '/nvim-bundle.json', {
        dependencies = {
          tagged = tagged.url .. '@v0.1.0',
          tracked = tracked.url .. '@main',
          pinned = pinned.url .. '@' .. rev,
        },
      })
      install(project, {})
      local new = tracked.commit { ['lua/tracked/init.lua'] = 'return 2\n' }
      local manifest = slurp(project .. '/nvim-bundle.json')

      local proc = cli { '-C', project, 'outdated' }
      assert.are.equal(0, proc.code, proc.stderr)

      assert.are.equal(
        ('pinned is pinned to %s\ntagged v0.1.0 -> v0.2.0\ntracked %s -> %s\n'):format(
          rev:sub(1, 7),
          old:sub(1, 7),
          new:sub(1, 7)
        ),
        proc.stdout
      )
      assert.are.equal(manifest, slurp(project .. '/nvim-bundle.json'))
    end)
  end)
end)
