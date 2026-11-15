local Test = require 'nvim-bundle.vendor.test'
local h = require 'spec.helpers'
local describe, it, after_each = Test.describe, Test.it, Test.after_each
local assert = Test.assert

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

    assert.equal(result.returns, 'entry')
    assert.equal(chunk().answer, 42)
    assert.contains(slurp(result.out), '\n-- returns: entry\n')
  end)

  it('returns a registry with a loader for each module when none is named', function()
    local root = fixture { ['entry.lua'] = 'return { answer = 42 }\n' }
    local chunk, result = compile_bundle(root)
    local registry = chunk()

    assert.equal(result.returns, 'registry')
    assert.equal(type(registry['entry']), 'function')
    assert.equal(registry['entry']().answer, 42)
    assert.contains(slurp(result.out), '\n-- returns: registry\n')
  end)

  it('names a registry after the one package under the root', function()
    local project = fixture { ['lua/pkg/init.lua'] = 'return 1\n' }
    local result = run_ok { '-C', project, 'build' }

    assert.equal(result.out, 'dist/pkg.lua')
    assert.equal(result.returns, 'registry')
  end)

  it('asks for --out when a registry has no single package name', function()
    local project = fixture { ['lua/a.lua'] = 'return 1\n', ['lua/b.lua'] = 'return 2\n' }
    run_fail({ '-C', project, 'build' }, 'pass --out')
  end)

  it('resolves an entry given as a dotted module path', function()
    local root = fixture { ['pkg/mod.lua'] = "return 'pkg-mod'\n" }
    local chunk = compile_bundle(root, 'pkg.mod')
    assert.equal(chunk(), 'pkg-mod')
  end)

  it('resolves an entry directory via init.lua', function()
    local root = fixture { ['pkg/init.lua'] = "return 'pkg-init'\n" }
    local chunk = compile_bundle(root, 'pkg')
    assert.equal(chunk(), 'pkg-init')
  end)

  it('strips a UTF-8 BOM and a shebang from module sources', function()
    local root = fixture {
      ['entry.lua'] = '\239\187\191#!/usr/bin/env -S nvim --clean -l\nreturn 7\n',
    }
    local chunk = compile_bundle(root, 'entry')
    assert.equal(chunk(), 7)
  end)

  it('bundles required modules instead of using the host searcher', function()
    local root = fixture {
      ['entry.lua'] = "return require 'dep'\n",
      ['dep.lua'] = "return { from = 'fixture' }\n",
    }
    local entry = compile_bundle(root, 'entry')()
    assert.equal(entry.from, 'fixture')
  end)

  it('falls back to the host require for unknown modules', function()
    stub_host_module('bundle_host_probe', 'from-host')
    local ok, value = pcall(function()
      local root = fixture { ['entry.lua'] = "return require 'bundle_host_probe'\n" }
      return compile_bundle(root, 'entry')()
    end)
    package.loaded['bundle_host_probe'] = nil
    assert.equal(ok, true, tostring(value))
    assert.equal(value, 'from-host')
  end)

  it('keeps a flat module and a same-named init module distinct', function()
    local root = fixture {
      ['entry.lua'] = "return { flat = require 'shadow', init = require 'shadow.init' }\n",
      ['shadow.lua'] = "return 'flat'\n",
      ['shadow/init.lua'] = "return 'init'\n",
    }
    local entry = compile_bundle(root, 'entry')()
    assert.equal(entry.flat, 'flat')
    assert.equal(entry.init, 'init')
  end)

  it('reports a require cycle instead of recursing forever', function()
    local root = fixture {
      ['entry.lua'] = "return require 'loop'\n",
      ['loop.lua'] = "return require 'loop'\n",
    }
    local chunk = compile_bundle(root, 'entry')
    local ok, err = pcall(function() return chunk() end)
    assert.equal(ok, false)
    assert.contains(tostring(err), "loop or previous error loading module 'loop'")
  end)
end)

describe('bin bundles', function()
  it('starts with a shebang and modeline', function()
    local root = fixture { ['entry.lua'] = 'return 1\n' }
    local _, result = compile_bundle(root, 'entry', { bin = true })
    local first, second = slurp(result.out):match '^([^\n]*)\n([^\n]*)\n'

    assert.equal(first, '#!/usr/bin/env -S nvim --clean -l')
    assert.equal(second, '-- vim: set ft=lua:')
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

    assert.equal(proc.code, 0, proc.stderr)
    assert.equal(proc.stdout, 'entry-main\n')
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

    assert.equal(entry.marker, 'entry')
    assert.equal(type(entry.main), 'function')
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

    assert.equal(proc.code, 0, proc.stderr)
    assert.equal(proc.stdout, 'entry-main x\nlib-arg {}\n')
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

    assert.equal(proc.code, 0, proc.stderr)
    assert.equal(proc.stdout, 'entry-main\n')
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

    assert.equal(proc.code, 0, proc.stderr)
    assert.equal(proc.stdout, '')
  end)

  it('makes the output executable', function()
    local root = fixture { ['entry.lua'] = 'return 1\n' }
    local _, result = compile_bundle(root, 'entry', { bin = true })
    local stat = assert(vim.uv.fs_stat(result.out))

    assert.ok(bit.band(stat.mode, 64) ~= 0)
  end)

  it('bundles nvim-bundle itself into a working executable', function()
    local out = fixture {} .. '-out/nvim-bundle'
    run_ok { 'build', '--root', 'lua', '--out', out, '--bin', 'nvim-bundle' }

    local proc = vim.system({ 'nvim', '--clean', '-l', out, '--version' }, { text = true }):wait()
    assert.equal(proc.code, 0, proc.stderr)
    assert.ok((proc.stdout or ''):match '^nvim%-bundle %d+%.%d+%.%d+ %(Neovim %d+%.%d+%.%d+')

    local entry = load_bundle(out)()
    assert.equal(type(entry.build), 'function')
  end)
end)

describe('a file executed again', function()
  -- A busted-like CLI: `test` runs each spec file it is given, and a spec
  -- registers its cases through `require 'test'`, which executes the bundle a
  -- second time because `nvim -l` leaves `package.loaded` empty. The bundle is
  -- installed as `lua/test.lua` on the runtimepath, so the spec's `require`
  -- finds it, not the source.
  --- @param files table<string, string> the CLI's sources, beside `spec.lua`
  --- @return string stdout
  local function run_cli(files)
    local root = fixture(vim.tbl_extend('error', {
      ['spec.lua'] = table.concat({
        'local t = require "test"',
        't.it("works")',
        't.it_local("works")',
        '',
      }, '\n'),
    }, files))
    local out = root .. '-out/lua/test.lua'
    run_ok { 'build', '--root', root, '--out', out, '--exclude', 'spec.lua', 'test' }
    local cmd = {
      'nvim',
      '--clean',
      '--cmd',
      'set rtp^=' .. root .. '-out',
      '-l',
      out,
      root .. '/spec.lua',
    }
    local proc = vim.system(cmd, { text = true }):wait()
    assert.equal(proc.code, 0, proc.stderr)
    return proc.stdout or ''
  end

  local cli = main_guarded(
    'local state = require "test.state"',
    'local M = {}',
    'local own = {}',
    'function M.it(name) table.insert(state.cases, name) end',
    'function M.it_local(name) table.insert(own, name) end',
    'function M.main()',
    '  dofile(arg[1])',
    '  io.stdout:write(("cases %d, entry-local %d\\n"):format(#state.cases, #own))',
    'end'
  )

  it('shares every library module with the script run', function()
    local stdout = run_cli {
      ['test.lua'] = cli,
      ['test/state.lua'] = 'io.stdout:write("state loaded\\n")\nreturn { cases = {} }\n',
    }

    assert.equal(stdout, 'state loaded\ncases 1, entry-local 0\n')
  end)

  -- The spec's `require` cannot return the script run's entry, which is still
  -- running its CLI, so the entry is evaluated again and its own locals are a
  -- second copy. This matches `require` on the unbundled source.
  it('evaluates the entry again, so state local to the entry is not shared', function()
    local stdout = run_cli {
      ['test.lua'] = cli,
      ['test/state.lua'] = 'return { cases = {} }\n',
    }

    assert.contains(stdout, 'entry-local 0')
  end)

  it('keeps a nested bundle cache apart from the outer one', function()
    -- Both bundles hold a module `util`, so a shared cache would hand the
    -- inner bundle the outer `util`.
    local inner = fixture {
      ['lib.lua'] = 'return { util = require "util" }\n',
      ['util.lua'] = 'return "inner"\n',
    }
    local _, built = compile_bundle(inner, 'lib')
    local root = fixture {
      ['entry.lua'] = 'local util = require "util"\nreturn { util, require("vendor.lib").util }\n',
      ['util.lua'] = 'return "outer"\n',
      ['vendor/lib.lua'] = slurp(built.out),
    }

    assert.deep_equal(compile_bundle(root, 'entry')(), { 'outer', 'inner' })
  end)
end)

describe('registry', function()
  it('loads each bundled module once and returns its value', function()
    local root = fixture {
      ['entry.lua'] = "local dep = require 'dep'\nreturn { dep = dep }\n",
      ['dep.lua'] = "return { name = 'dep' }\n",
    }
    local registry = compile_bundle(root)()

    assert.equal(registry['dep'](), registry['entry']().dep)
    assert.equal(registry['dep']().name, 'dep')
  end)

  it('contains every bundled module id', function()
    local root = fixture {
      ['entry.lua'] = "return { dep = require 'dep' }\n",
      ['dep.lua'] = "return 'dep'\n",
    }
    local registry = compile_bundle(root)()

    assert.equal(type(registry['entry']), 'function')
    assert.equal(type(registry['dep']), 'function')
    assert.is_nil(registry['bundle_entry_host_probe'])
  end)

  it('returns true for a bundled module with no return value', function()
    local root = fixture {
      ['entry.lua'] = "return { side = require 'side_effect' }\n",
      ['side_effect.lua'] = 'local value = 1\n',
    }
    local registry = compile_bundle(root)()

    assert.equal(registry['entry']().side, true)
    assert.equal(registry['side_effect'](), true)
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

    assert.contains(content, '__mods._entry = function')
    assert.contains(content, '__mods._myplugin_util = function')
    assert.contains(content, '__mods._my_plugin_math = function')
    assert.contains(content, '__mods._myplugin_util("myplugin.util")')
  end)

  it('disambiguates ids that sanitize to the same name', function()
    local root = fixture {
      ['entry.lua'] = "return { dotted = require 'a.b', underscored = require 'a_b' }\n",
      ['a/b.lua'] = "return 'dotted'\n",
      ['a_b.lua'] = "return 'underscored'\n",
    }
    local chunk, result = compile_bundle(root, 'entry')
    local content = slurp(result.out)

    assert.contains(content, '__mods._a_b = function')
    assert.contains(content, '__mods._a_b_2 = function')
    local entry = chunk()
    assert.equal(entry.dotted, 'dotted')
    assert.equal(entry.underscored, 'underscored')
  end)

  it('escapes a name that would start with a digit', function()
    local root = fixture {
      ['entry.lua'] = "return require '3d'\n",
      ['3d.lua'] = "return '3d'\n",
    }
    local _, result = compile_bundle(root, 'entry')
    assert.contains(slurp(result.out), '__mods._3d = function')
  end)

  it('escapes a Lua keyword used as a module name', function()
    local root = fixture {
      ['entry.lua'] = "return require 'end'\n",
      ['end.lua'] = "return 'end'\n",
    }
    local _, result = compile_bundle(root, 'entry')
    assert.contains(slurp(result.out), '__mods._end = function')
  end)
end)

describe('excludes', function()
  it("leaves out the project's own dev dependencies", function()
    local project = fixture {
      ['nvim-bundle.json'] = vim.json.encode {
        name = 'myplug',
        dependencies = { args = 'me/args.nvim@v1.0.0' },
        dev_dependencies = { test = 'me/test.nvim@v1.0.0' },
      },
      ['lua/myplug/init.lua'] = 'return {}\n',
      ['lua/myplug/vendor/args.lua'] = 'return "args"\n',
      ['lua/myplug/vendor/test.lua'] = 'return "test"\n',
    }
    local out = project .. '-out/myplug.lua'

    run_ok { '-C', project, 'build', '--out', out }

    local registry = load_bundle(out)()
    assert.equal(registry['myplug.vendor.args'](), 'args')
    assert.is_nil(registry['myplug.vendor.test'])
  end)

  it('skips files matching an exclude glob', function()
    local root = fixture {
      ['entry.lua'] = "return { dep = require 'dep', skip = require 'vendor.skip' }\n",
      ['dep.lua'] = "return 'bundled-dep'\n",
      ['vendor/skip.lua'] = "return 'bundled-skip'\n",
    }
    stub_host_module('dep', 'host-dep')
    local ok, value = pcall(function()
      local chunk, result = compile_bundle(root, 'entry', { exclude = { 'dep.lua' } })
      assert.equal(result.modules, 2)
      return chunk()
    end)
    package.loaded.dep = nil
    assert.equal(ok, true, tostring(value))
    assert.equal(value.dep, 'host-dep')
    assert.equal(value.skip, 'bundled-skip')
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
    assert.equal(result.out, out)
    assert.ok(vim.uv.fs_stat(out))
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

    assert.equal(outputs[2], outputs[1])
  end)
end)
