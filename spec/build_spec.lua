--- @diagnostic disable: undefined-field

local h = require 'spec.helpers'

local fixture = h.fixture
local slurp = h.slurp
local run_ok = h.run_ok
local run_fail = h.run_fail
local load_bundle = h.load_bundle
local compile_bundle = h.compile_bundle
local main_guarded = h.main_guarded
local stub_host_module = h.stub_host_module

after_each(h.remove_created)

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
    stub_host_module('bundle_host_probe', 'from-host')
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
      ['entry.lua'] = main_guarded(
        'local M = {}',
        'function M.main() io.stdout:write("entry-main\\n") end'
      ),
    }
    local _, result = compile_bundle(root, 'entry', { bin = true })
    local proc = vim.system({ 'nvim', '--clean', '-l', result.out }, { text = true }):wait()

    assert.are.equal(0, proc.code, proc.stderr)
    assert.are.equal('entry-main\n', proc.stdout)
  end)

  it('returns the entry module when loaded as a library', function()
    local root = fixture {
      ['entry.lua'] = main_guarded(
        'local M = { marker = "entry" }',
        'function M.main() error("main must not run") end'
      ),
    }
    local _, result = compile_bundle(root, 'entry', { bin = true })
    local entry = load_bundle(result.out)()

    assert.are.equal('entry', entry.marker)
    assert.is_function(entry.main)
  end)

  it('runs only the entry main guard, and gives libraries an empty arg', function()
    local root = fixture {
      ['entry.lua'] = main_guarded(
        'local lib = require "lib"',
        'local M = {}',
        'function M.main()',
        '  io.stdout:write(("entry-main %s\\n"):format(arg[1]))',
        '  io.stdout:write(("lib-arg %s\\n"):format(vim.inspect(lib.arg)))',
        'end'
      ),
      ['lib.lua'] = main_guarded(
        'local M = { arg = arg }',
        'function M.main() io.stdout:write("lib-main\\n") end'
      ),
    }
    local _, result = compile_bundle(root, 'entry', { bin = true })
    local proc = vim.system({ 'nvim', '--clean', '-l', result.out, 'x' }, { text = true }):wait()

    assert.are.equal(0, proc.code, proc.stderr)
    assert.are.equal('entry-main x\nlib-arg {}\n', proc.stdout)
  end)

  it('keeps a nested bundle from running its main guard', function()
    -- The inner bundle's entry keeps whatever `arg` encloses it, so the outer
    -- bundle's empty table must reach it.
    local lib = fixture {
      ['lib.lua'] = main_guarded(
        'local M = {}',
        'function M.main() io.stdout:write("lib-main\\n") end'
      ),
    }
    local _, inner = compile_bundle(lib, 'lib')
    local root = fixture {
      ['entry.lua'] = main_guarded(
        'require "vendor.lib"',
        'local M = {}',
        'function M.main() io.stdout:write("entry-main\\n") end'
      ),
      ['vendor/lib.lua'] = slurp(inner.out),
    }
    local _, result = compile_bundle(root, 'entry', { bin = true })
    local proc = vim.system({ 'nvim', '--clean', '-l', result.out }, { text = true }):wait()

    assert.are.equal(0, proc.code, proc.stderr)
    assert.are.equal('entry-main\n', proc.stdout)
  end)

  it('runs no main guard when a registry is executed', function()
    local root = fixture {
      ['lib.lua'] = main_guarded(
        'local M = {}',
        'function M.main() io.stdout:write("lib-main\\n") end'
      ),
      ['run.lua'] = 'require "lib"\nreturn true\n',
    }
    local _, result = compile_bundle(root, nil)
    -- A registry loads nothing on its own, so a wrapper script executes it
    -- under the bundle's own path and then loads the module from it.
    local runner = root .. '-out/runner.lua'
    local f = assert(io.open(runner, 'wb'))
    f:write(('arg[0] = %q\nreturn dofile(arg[0]).lib()\n'):format(result.out))
    f:close()
    local proc = vim.system({ 'nvim', '--clean', '-l', runner }, { text = true }):wait()

    assert.are.equal(0, proc.code, proc.stderr)
    assert.are.equal('', proc.stdout)
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
    assert.is_truthy((proc.stdout or ''):match '^nvim%-bundle %d+%.%d+%.%d+ %(Neovim %d+%.%d+%.%d+')

    local entry = load_bundle(out)()
    assert.is_function(entry.build)
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
    stub_host_module('dep', 'host-dep')
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
