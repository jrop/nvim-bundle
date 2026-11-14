--- @diagnostic disable: undefined-field

local h = require 'spec.helpers'

local fixture = h.fixture
local compile_bundle = h.compile_bundle
local run_entry = h.run_entry

after_each(h.remove_created)

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

  it('links a multi-line require and keeps the lines after it in place', function()
    local err, _, line = run_entry(
      "local dep = require(\n  'dep'\n)\nerror(dep)\n",
      nil,
      { ['dep.lua'] = "return 'bundled'\n" }
    )
    assert.is_truthy(tostring(err):find('bundled', 1, true), tostring(err))
    assert.are.equal(4, line)
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
