local Test = require 'nvim-bundle.vendor.test'
local h = require 'spec.helpers'
local describe, it, after_each = Test.describe, Test.it, Test.after_each
local assert = Test.assert

local fixture = h.fixture
local cli = h.cli
local run_ok = h.run_ok
local run_help = h.run_help
local run_fail = h.run_fail
local load_module = h.load_module

after_each(h.remove_created)

describe('public API', function()
  it('exposes build and not run or main', function()
    local NvimBundle = load_module()
    local keys = vim.tbl_keys(NvimBundle)
    table.sort(keys)

    assert.deep_equal(keys, { 'build' })
    assert.equal(type(NvimBundle.build), 'function')
    assert.is_nil(NvimBundle.run)
    assert.is_nil(NvimBundle.main)
  end)

  it('builds a fixture through build', function()
    local root = fixture { ['entry.lua'] = 'return 1\n' }
    local out = root .. '-out/entry.lua'
    local result = load_module().build { root = root, out = out, entry = 'entry' }

    assert.equal(result.out, out)
    assert.equal(result.modules, 1)
    assert.ok(vim.uv.fs_stat(out))
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

    assert.equal(result.out, out)
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
      assert.contains(help, 'Usage: nvim-bundle <command>')
      assert.contains(help, 'build')
    end
  end)

  it('returns build help without bundling', function()
    for _, flag in ipairs { '--help', '-h' } do
      local help = run_help { 'build', flag }
      assert.contains(help, 'Usage: nvim-bundle build [<entry>]')
      assert.contains(help, '--root')
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
      assert.equal(proc.code, 0, proc.stderr)
      local stdout = proc.stdout or ''
      assert.ok(stdout:match '^nvim%-bundle %d+%.%d+%.%d+ %(Neovim %d+%.%d+%.%d+', stdout)
    end
  end)

  it('reports an entry file that is not on disk', function()
    local root = fixture { ['present.lua'] = 'return 1\n' }
    run_fail({ 'build', '--root', root, 'missing' }, 'module "missing" is not in the bundle')
  end)
end)
