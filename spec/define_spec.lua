local Test = require 'nvim-bundle.vendor.test'
local h = require 'spec.helpers'
local describe, it, after_each = Test.describe, Test.it, Test.after_each
local assert = Test.assert

local fixture = h.fixture
local run_fail = h.run_fail
local load_module = h.load_module
local load_bundle = h.load_bundle
local run_entry = h.run_entry

after_each(h.remove_created)

describe('defines', function()
  it('replaces a global name and a dotted path', function()
    local value = run_entry('return { dev = __DEV__, env = vim.g.env }\n', {
      __DEV__ = 'false',
      ['vim.g.env'] = '"production"',
    })
    assert.deep_equal(value, { dev = false, env = 'production' })
  end)

  it('leaves strings, comments, table keys, and field names alone', function()
    local _, text = run_entry(
      table.concat({
        '-- __DEV__ in a comment',
        'local t = { __DEV__ = 1 }',
        'local s = "__DEV__"',
        'return { t.__DEV__, s }',
        '',
      }, '\n'),
      { __DEV__ = 'false' }
    )
    assert.contains(text, '-- __DEV__ in a comment')
    assert.contains(text, '{ __DEV__ = 1 }')
    assert.contains(text, '"__DEV__"')
    assert.contains(text, 't.__DEV__')
  end)

  it('leaves a name that the module declares itself', function()
    local cases = {
      'local __DEV__ = "local"\nreturn __DEV__\n',
      'local function __DEV__() return "local" end\nreturn __DEV__()\n',
      'local function f(__DEV__) return __DEV__ end\nreturn f("local")\n',
      'for _, __DEV__ in ipairs { "local" } do return __DEV__ end\n',
    }
    for _, src in ipairs(cases) do
      assert.equal((run_entry(src, { __DEV__ = 'false' })), 'local')
    end
  end)

  it('parenthesizes a value that is indexed or called', function()
    local value, text = run_entry('return { vim.g.env:upper(), vim.g.cfg.level, vim.g.make() }\n', {
      ['vim.g.env'] = '"production"',
      ['vim.g.cfg'] = '{ level = 2 }',
      ['vim.g.make'] = 'function() return 3 end',
    })
    assert.deep_equal(value, { 'PRODUCTION', 2, 3 })
    assert.contains(text, '("production"):upper()')
  end)

  it('replaces the longest key that matches', function()
    local value = run_entry('return { vim.g.env, vim.g.other }\n', {
      ['vim.g'] = '{ other = "from vim.g" }',
      ['vim.g.env'] = '"production"',
    })
    assert.deep_equal(value, { 'production', 'from vim.g' })
  end)

  it('replaces a key that spans lines and keeps the lines after it in place', function()
    local err, _, line =
      run_entry('local env = vim.g\n  .env\nerror(env)\n', { ['vim.g.env'] = '"prod"' })
    assert.contains(tostring(err), 'prod')
    assert.equal(line, 3)
  end)

  it('ends the previous statement before a value that starts a statement', function()
    -- Without the `;`, `("prod")` would continue `tostring` on the line
    -- before as a call, which LuaJIT rejects as ambiguous.
    local value = run_entry(
      'local seen\nlocal s = tostring\n-- a comment between\nvim.g.log:gsub(".", function(c) seen = c end)\nreturn { s ~= nil, seen }\n',
      { ['vim.g.log'] = '"x"' }
    )
    assert.deep_equal(value, { true, 'x' })
  end)

  it('adds no `;` before the first statement of a block', function()
    local value, text = run_entry(
      'local seen\ndo vim.g.log:gsub(".", function(c) seen = c end) end\nreturn seen\n',
      { ['vim.g.log'] = '"x"' }
    )
    assert.equal(value, 'x')
    assert.contains(text, 'do ("x"):gsub')
  end)

  it('links a require that a define value contains', function()
    local value = run_entry(
      'return DEP\n',
      { DEP = 'require("dep")' },
      { ['dep.lua'] = 'return "bundled"\n' }
    )
    assert.equal(value, 'bundled')
  end)

  it(
    'ignores a key that matches nothing',
    function() assert.equal((run_entry('return 1\n', { __UNUSED__ = 'true' })), 1) end
  )

  it('rejects an assignment to a defined key or a field through it', function()
    for _, src in ipairs {
      'vim.g.env = "x"\n',
      'vim.g.env.y = 1\n',
      'function vim.g.env() end\n',
    } do
      local root = fixture { ['entry.lua'] = src }
      run_fail({
        'build',
        '--root',
        root,
        '--out',
        root .. '-out/entry.lua',
        '--define',
        'vim.g.env=1',
        'entry',
      }, 'assigns to vim.g.env, which --define replaces')
    end
  end)

  it('rejects a malformed define', function()
    local root = fixture { ['entry.lua'] = 'return 1\n' }
    local cases = {
      { 'nokey', '--define needs <key>=<value>, got "nokey"' },
      { 'vim.g[1]=1', 'Expected a global name or a dotted path' },
      { 'require=1', 'require, pcall, and xpcall cannot be defined' },
      { 'x=1, 2', 'Expected one Lua expression on one line' },
      { 'x=y) (z', 'Expected one Lua expression on one line' },
    }
    for _, case in ipairs(cases) do
      run_fail({
        'build',
        '--root',
        root,
        '--out',
        root .. '-out/entry.lua',
        '--define',
        case[1],
        'entry',
      }, case[2])
    end
    run_fail({
      'build',
      '--root',
      root,
      '--out',
      root .. '-out/entry.lua',
      '--define',
      'x=1',
      '--define',
      'x=2',
      'entry',
    }, '--define x is given twice')
  end)

  it('accepts defines from the Lua API', function()
    local root = fixture { ['entry.lua'] = 'return __DEV__\n' }
    local out = root .. '-out/entry.lua'
    load_module().build { root = root, out = out, entry = 'entry', define = { __DEV__ = '42' } }
    assert.equal(load_bundle(out)(), 42)
  end)
end)
