--- @diagnostic disable: duplicate-set-field
--- @diagnostic disable: missing-fields
--- @diagnostic disable: need-check-nil
--- @diagnostic disable: undefined-field

--- Black-box tests for the bundler. Every case writes a small source tree to a
--- temporary directory, runs the CLI, and then executes or inspects the output.

--- @class CliResult
--- @field out string
--- @field entry string
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
--- @return vim.SystemCompleted
local function cli(argv)
  local cmd = { 'nvim', '--clean' }
  -- Under `busted --coverage`, instrument the child so its CLI lines count.
  if package.loaded['luacov.runner'] then
    cmd[#cmd + 1] = '--cmd'
    cmd[#cmd + 1] = 'lua require("luacov")'
  end
  cmd[#cmd + 1] = '-l'
  cmd[#cmd + 1] = vim.fn.fnamemodify('lua/nvim-bundle.lua', ':p')
  for _, arg in ipairs(argv) do
    cmd[#cmd + 1] = arg
  end
  return vim.system(cmd, { text = true }):wait()
end

--- @param stdout string
--- @return CliResult
local function parse_summary(stdout)
  local modules, out, entry = stdout:match '^bundled (%d+) modules into (.-)%s+%(entry (.-)%)%s*$'
  assert.is_truthy(modules, ('unexpected CLI output: %q'):format(stdout))
  --- @cast modules string
  --- @cast out string
  --- @cast entry string
  return {
    modules = assert(tonumber(modules)),
    out = out,
    entry = entry,
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

--- Load the module under test directly, so its chunk name is absolute and
--- matches the CLI child process in coverage reports.
--- @return table
local function load_module()
  local path = vim.fn.fnamemodify('lua/nvim-bundle.lua', ':p')
  local chunk, err = loadfile(path)
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

--- Bundle `root`'s `entry` and compile the generated file. The caller decides
--- whether executing the chunk should succeed.
--- @param root string
--- @param entry string
--- @param opts { bin?: boolean, exclude?: string[] }?
--- @return function chunk, CliResult result
local function compile_bundle(root, entry, opts)
  opts = opts or {}
  local out = root .. '-out/' .. entry .. '.lua'
  local argv = { '--root', root, '--out', out }
  if opts.bin then argv[#argv + 1] = '--bin' end
  for _, glob in ipairs(opts.exclude or {}) do
    argv[#argv + 1] = '--exclude'
    argv[#argv + 1] = glob
  end
  argv[#argv + 1] = entry

  local result = run_ok(argv)
  return load_bundle(result.out), result
end

--- Load one bundled module from a compiled registry.
--- @param chunk function
--- @param id string
--- @return any
local function module_value(chunk, id) return chunk()[id]() end

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
    it('rejects a missing entry', function()
      run_fail({}, 'missing entry module (for example: myplugin)')
      run_fail({ '--root', 'lua' }, 'missing entry module (for example: myplugin)')
    end)

    it(
      'rejects an unknown option',
      function() run_fail({ '--nope', 'entry' }, 'unknown or unexpected option: --nope') end
    )

    it('accepts an inline long-option value', function()
      local root = fixture { ['entry.lua'] = 'return 1\n' }
      local out = root .. '-out/entry.lua'
      local result = run_ok { '--root=' .. root, '--out=' .. out, 'entry' }

      assert.are.equal(out, result.out)
    end)

    it(
      'rejects an option with no value',
      function() run_fail({ '--root' }, 'option requires argument: --root') end
    )

    it(
      'rejects extra positional arguments',
      function() run_fail({ 'entry', 'extra' }, 'unexpected argument extra') end
    )

    it('returns help without bundling', function()
      for _, flag in ipairs { '--help', '-h' } do
        local help = run_help { flag }
        assert.is_truthy(help:find('Usage: nvim-bundle <entry>', 1, true), help)
        assert.is_truthy(help:find('--root', 1, true), help)
      end
    end)

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
      run_fail({ '--root', root, 'missing' }, 'entry "missing" not found')
    end)
  end)

  describe('output', function()
    it('returns a registry with a loader for each bundled module', function()
      local root = fixture { ['entry.lua'] = 'return { answer = 42 }\n' }
      local registry = compile_bundle(root, 'entry')()

      assert.is_function(registry['entry'])
      assert.are.equal(42, registry['entry']().answer)
    end)

    it('resolves an entry given as a dotted module path', function()
      local root = fixture { ['pkg/mod.lua'] = "return 'pkg-mod'\n" }
      local chunk = compile_bundle(root, 'pkg.mod')
      assert.are.equal('pkg-mod', module_value(chunk, 'pkg.mod'))
    end)

    it('resolves an entry directory via init.lua', function()
      local root = fixture { ['pkg/init.lua'] = "return 'pkg-init'\n" }
      local chunk = compile_bundle(root, 'pkg')
      assert.are.equal('pkg-init', module_value(chunk, 'pkg'))
    end)

    it('strips a UTF-8 BOM and a shebang from module sources', function()
      local root = fixture {
        ['entry.lua'] = '\239\187\191#!/usr/bin/env -S nvim --clean -l\nreturn 7\n',
      }
      local chunk = compile_bundle(root, 'entry')
      assert.are.equal(7, module_value(chunk, 'entry'))
    end)

    it('bundles required modules instead of using the host searcher', function()
      local root = fixture {
        ['entry.lua'] = "return require 'dep'\n",
        ['dep.lua'] = "return { from = 'fixture' }\n",
      }
      local entry = module_value(compile_bundle(root, 'entry'), 'entry')
      assert.are.equal('fixture', entry.from)
    end)

    it('falls back to the host require for unknown modules', function()
      package.loaded['bundle_host_probe'] = 'from-host'
      local ok, value = pcall(function()
        local root = fixture { ['entry.lua'] = "return require 'bundle_host_probe'\n" }
        return module_value(compile_bundle(root, 'entry'), 'entry')
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
      local entry = module_value(compile_bundle(root, 'entry'), 'entry')
      assert.are.equal('flat', entry.flat)
      assert.are.equal('init', entry.init)
    end)

    it('reports a require cycle instead of recursing forever', function()
      local root = fixture {
        ['entry.lua'] = "return require 'loop'\n",
        ['loop.lua'] = "return require 'loop'\n",
      }
      local chunk = compile_bundle(root, 'entry')
      local ok, err = pcall(function() return module_value(chunk, 'entry') end)
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
      run_ok { '--root', 'lua', '--out', out, '--bin', 'nvim-bundle' }

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
      local entry = module_value(compile_bundle(root, 'entry'), 'entry')
      assert.is_true(entry.ok)
      assert.are.equal('dep', entry.dep)
    end)

    it('resolves xpcall(require, handler, ...) to a bundled module', function()
      local root = fixture {
        ['entry.lua'] = "local ok, dep = xpcall(require, function(err) return err end, 'dep')\n"
          .. 'return { ok = ok, dep = dep }\n',
        ['dep.lua'] = "return 'dep'\n",
      }
      local entry = module_value(compile_bundle(root, 'entry'), 'entry')
      assert.is_true(entry.ok)
      assert.are.equal('dep', entry.dep)
    end)

    it('leaves a shadowed require dynamic', function()
      local root = fixture {
        ['entry.lua'] = "local function require(name) return 'local-' .. name end\n"
          .. "return require 'dep'\n",
        ['dep.lua'] = "return 'bundled'\n",
      }
      assert.are.equal('local-dep', module_value(compile_bundle(root, 'entry'), 'entry'))
    end)

    it('leaves a multi-line require dynamic', function()
      local root = fixture {
        ['entry.lua'] = "return require(\n  'dep'\n)\n",
        ['dep.lua'] = "return 'bundled'\n",
      }
      package.loaded.dep = 'host-dep'
      local ok, value = pcall(
        function() return module_value(compile_bundle(root, 'entry'), 'entry') end
      )
      package.loaded.dep = nil
      assert.is_true(ok, tostring(value))
      assert.are.equal('host-dep', value)
    end)

    it('resolves escaped and long-string literals', function()
      local root = fixture {
        ['entry.lua'] = "return { escaped = require 'pkg\\46util', long = require [[pkg.util]] }\n",
        ['pkg/util.lua'] = "return { name = 'util' }\n",
      }
      local value = module_value(compile_bundle(root, 'entry'), 'entry')
      assert.are.equal('util', value.escaped.name)
      assert.are.equal(value.escaped, value.long)
    end)

    it('passes the module id as a vararg', function()
      local root = fixture {
        ['entry.lua'] = "return require 'dep'\n",
        ['dep.lua'] = 'return ...\n',
      }
      assert.are.equal('dep', module_value(compile_bundle(root, 'entry'), 'entry'))
    end)

    it('returns nil for a module with no return value', function()
      local root = fixture {
        ['entry.lua'] = "return require 'side_effect'\n",
        ['side_effect.lua'] = 'local value = 1\n',
      }
      assert.is_nil(module_value(compile_bundle(root, 'entry'), 'entry'))
    end)
  end)

  describe('registry', function()
    it('loads each bundled module once and returns its value', function()
      local root = fixture {
        ['entry.lua'] = "local dep = require 'dep'\nreturn { dep = dep }\n",
        ['dep.lua'] = "return { name = 'dep' }\n",
      }
      local registry = compile_bundle(root, 'entry')()

      assert.are.equal(registry['entry']().dep, registry['dep']())
      assert.are.equal('dep', registry['dep']().name)
    end)

    it('contains every bundled module id', function()
      local root = fixture {
        ['entry.lua'] = "return { dep = require 'dep' }\n",
        ['dep.lua'] = "return 'dep'\n",
      }
      local registry = compile_bundle(root, 'entry')()

      assert.is_function(registry['entry'])
      assert.is_function(registry['dep'])
      assert.is_nil(registry['bundle_entry_host_probe'])
    end)

    it('returns nil for a bundled module with no return value', function()
      local root = fixture {
        ['entry.lua'] = "return { side = require 'side_effect' }\n",
        ['side_effect.lua'] = 'local value = 1\n',
      }
      local registry = compile_bundle(root, 'entry')()

      assert.is_nil(registry['entry']().side)
      assert.is_nil(registry['side_effect']())
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
      local entry = module_value(chunk, 'entry')
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
        return module_value(chunk, 'entry')
      end)
      package.loaded.dep = nil
      assert.is_true(ok, tostring(value))
      assert.are.equal('host-dep', value.dep)
      assert.are.equal('bundled-skip', value.skip)
    end)

    it('rejects an entry that is excluded', function()
      local root = fixture { ['entry.lua'] = 'return 1\n' }
      run_fail({
        '--root',
        root,
        '--out',
        root .. '-out/entry.lua',
        '--exclude',
        'entry.lua',
        'entry',
      }, 'entry is excluded or missing from the bundle')
    end)

    it('rejects an invalid exclude glob', function()
      -- Neovim 0.10 and 0.11 accept "[" as a literal, so only newer versions
      -- can reach the validation error.
      if pcall(vim.glob.to_lpeg, '[') then return end
      local root = fixture { ['entry.lua'] = 'return 1\n' }
      run_fail({ '--root', root, '--exclude', '[', 'entry' }, 'invalid --exclude glob')
    end)
  end)

  describe('output path', function()
    it('creates missing output directories', function()
      local root = fixture { ['entry.lua'] = 'return 1\n' }
      local out = root .. '-out/nested/deeper/entry.lua'
      local result = run_ok { '--root', root, '--out', out, 'entry' }
      assert.are.equal(out, result.out)
      assert.is_truthy(vim.uv.fs_stat(out))
    end)

    it('rejects an output path inside the source root', function()
      local root = fixture { ['entry.lua'] = 'return 1\n' }
      run_fail(
        { '--root', root, '--out', root .. '/dist/entry.lua', 'entry' },
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
        { '--root', root, '--out', root .. '-out/entry.lua', 'entry' },
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
      "local bundle = require 'bundled_lib'",
      "local lib = bundle['entry']()",
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

    it('preserves types through pcall(require, ...)', function()
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
      local _, result = compile_bundle(root, 'entry')
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
end)
