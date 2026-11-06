--- @diagnostic disable: duplicate-set-field
--- @diagnostic disable: missing-fields
--- @diagnostic disable: need-check-nil
--- @diagnostic disable: undefined-field

--- Black-box tests for the bundler. Every case writes a small source tree to a
--- temporary directory, runs the CLI, and then executes or inspects the output.

local NvimBundle = require 'nvim-bundle'

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

--- @param argv string[]
--- @return { out: string, entry: string, modules: integer }
local function run_ok(argv)
  local ok, result = pcall(NvimBundle.run, argv)
  assert.is_true(ok, tostring(result))
  --- @cast result { out: string, entry: string, modules: integer }
  return result
end

--- @param argv string[]
--- @param pattern string
local function run_fail(argv, pattern)
  local ok, err = pcall(NvimBundle.run, argv)
  assert.is_false(ok, 'expected the bundler to fail')
  assert.is_truthy(
    tostring(err):find(pattern, 1, true),
    ('expected %q in error %q'):format(pattern, tostring(err))
  )
end

--- Bundle `root`'s `entry` and compile the generated file. The caller decides
--- whether executing the chunk should succeed.
--- @param root string
--- @param entry string
--- @param opts { exclude?: string[] }?
--- @return function chunk, { out: string, entry: string, modules: integer } result
local function compile_bundle(root, entry, opts)
  opts = opts or {}
  local out = root .. '-out/' .. entry .. '.lua'
  local argv = { '--root', root, '--out', out }
  for _, glob in ipairs(opts.exclude or {}) do
    argv[#argv + 1] = '--exclude'
    argv[#argv + 1] = glob
  end
  argv[#argv + 1] = entry

  local result = run_ok(argv)
  local chunk, err = loadstring(slurp(result.out), '@' .. result.out)
  assert.is_truthy(chunk, err)
  --- @cast chunk function
  return chunk, result
end

describe('nvim-bundle', function()
  after_each(function()
    for _, path in ipairs(created) do
      vim.fn.delete(path, 'rf')
    end
    created = {}
  end)

  describe('arguments', function()
    it(
      'rejects a missing entry',
      function() run_fail({ '--root', 'lua' }, 'missing entry module') end
    )

    it(
      'rejects an unknown option',
      function() run_fail({ '--nope', 'entry' }, 'unknown option --nope') end
    )

    it(
      'rejects an option with no value',
      function() run_fail({ '--root' }, '--root needs a value') end
    )

    it('returns help without bundling', function()
      local ok, result = pcall(NvimBundle.run, { '--help' })
      assert.is_true(ok, tostring(result))
      assert.is_true(result.help)
    end)

    it('reports an entry file that is not on disk', function()
      local root = fixture { ['present.lua'] = 'return 1\n' }
      run_fail({ '--root', root, 'missing' }, 'entry "missing" not found')
    end)
  end)

  describe('output', function()
    it('returns the entry module value', function()
      local root = fixture { ['entry.lua'] = 'return { answer = 42 }\n' }
      local chunk = compile_bundle(root, 'entry')
      assert.are.same({ answer = 42 }, chunk())
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
      local chunk = compile_bundle(root, 'entry')
      assert.are.same({ from = 'fixture' }, chunk())
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
      local chunk = compile_bundle(root, 'entry')
      assert.are.same({ flat = 'flat', init = 'init' }, chunk())
    end)

    it('reports a require cycle instead of recursing forever', function()
      local root = fixture {
        ['entry.lua'] = "return require 'loop'\n",
        ['loop.lua'] = "return require 'loop'\n",
      }
      local chunk = compile_bundle(root, 'entry')
      local ok, err = pcall(chunk)
      assert.is_false(ok)
      assert.is_truthy(
        tostring(err):find("loop or previous error loading module 'loop'", 1, true),
        tostring(err)
      )
    end)
  end)

  describe('static requires', function()
    it('resolves pcall(require, ...) to a bundled module', function()
      local root = fixture {
        ['entry.lua'] = "local ok, dep = pcall(require, 'dep')\nreturn { ok = ok, dep = dep }\n",
        ['dep.lua'] = "return 'dep'\n",
      }
      assert.are.same({ ok = true, dep = 'dep' }, compile_bundle(root, 'entry')())
    end)

    it('resolves xpcall(require, handler, ...) to a bundled module', function()
      local root = fixture {
        ['entry.lua'] = "local ok, dep = xpcall(require, function(err) return err end, 'dep')\n"
          .. 'return { ok = ok, dep = dep }\n',
        ['dep.lua'] = "return 'dep'\n",
      }
      assert.are.same({ ok = true, dep = 'dep' }, compile_bundle(root, 'entry')())
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

    it('returns nil for a module with no return value', function()
      local root = fixture {
        ['entry.lua'] = "return require 'side_effect'\n",
        ['side_effect.lua'] = 'local value = 1\n',
      }
      assert.is_nil(compile_bundle(root, 'entry')())
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
      assert.are.same({ dotted = 'dotted', underscored = 'underscored' }, chunk())
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
      assert.are.same({ dep = 'host-dep', skip = 'bundled-skip' }, value)
    end)

    it('rejects an entry that is excluded', function()
      local root = fixture { ['entry.lua'] = 'return 1\n' }
      run_fail(
        { '--root', root, '--out', root .. '-out/entry.lua', '--exclude', 'entry.lua', 'entry' },
        'entry is excluded or missing from the bundle'
      )
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
  end)
end)
