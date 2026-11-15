local Test = require 'nvim-bundle.vendor.test'
local h = require 'spec.helpers'
local describe, it, after_each = Test.describe, Test.it, Test.after_each
local assert = Test.assert

local run_entry = h.run_entry

after_each(h.remove_created)

describe('dead code', function()
  it('removes a statement whose condition is false', function()
    local value, module =
      run_entry 'if false then error("dead") end\nwhile false do error("dead") end\nreturn 1\n'
    assert.equal(value, 1)
    assert.equal(module, 'do end\ndo end\nreturn 1\n')
  end)

  it('keeps a true branch as a block', function()
    local value, module = run_entry(table.concat({
      'local r = {}',
      'if true then local hidden = 1; r.inside = hidden else r.other = 1 end',
      'r.outside = hidden',
      'if true then return r end',
      'return "late"',
      '',
    }, '\n'))
    assert.deep_equal(value, { inside = 1 })
    assert.is_nil((module:find('r.other', 1, true)))
    assert.contains(module, 'do   return r end')
  end)

  it('makes the first kept elseif the if', function()
    local value, module =
      run_entry 'if false then return 1 elseif vim.g.flag then return 2 else return 3 end\n'
    assert.equal(value, 3)
    assert.equal(module, '    if vim.g.flag then return 2 else return 3 end\n')
  end)

  it('makes a true elseif the else and drops the arms after it', function()
    local value, module =
      run_entry 'if vim.g.flag then return 1 elseif true then return 2 elseif vim.g.other then return 3 else return 4 end\n'
    assert.equal(value, 2)
    assert.equal(module, 'if vim.g.flag then return 1 else   return 2   end\n')
  end)

  it('evaluates literals, not, ==, ~=, and a short-circuit that skips its right side', function()
    local value = run_entry(table.concat({
      'local r = {}',
      'if "a" == "a" then r.eq = true end',
      'if 1 ~= 1 then r.ne = true end',
      'if not nil then r.not_nil = true end',
      'if 0 then r.zero = true end',
      'if false and error("never runs") then r.and_ = true end',
      'if true or error("never runs") then r.or_ = true end',
      'if (false) then r.paren = true end',
      'return r',
      '',
    }, '\n'))
    assert.deep_equal(value, { eq = true, not_nil = true, zero = true, or_ = true })
  end)

  it('keeps a condition that depends on the program', function()
    local src = table.concat({
      'local x = vim.g.flag',
      'if x then end',
      'if vim.g.flag == "a" then end',
      'if true and vim.g.flag then end',
      'if {} then end',
      'if f and f() then end',
      '',
    }, '\n')
    local _, module = run_entry(src)
    assert.equal(module, src)
  end)

  it('removes a branch chosen by a define', function()
    local value, module = run_entry(
      'if vim.g.env == "production" then return "prod" else return "dev" end\n',
      { ['vim.g.env'] = '"production"' }
    )
    assert.equal(value, 'prod')
    assert.is_nil((module:find('"dev"', 1, true)))
  end)

  it('skips everything inside a removed branch', function()
    local value = run_entry(table.concat({
      'if false then',
      '  if true then error("dead") elseif false then error("dead") end',
      '  local dep = require "missing.module"',
      'end',
      'return "ok"',
      '',
    }, '\n'))
    assert.equal(value, 'ok')
  end)

  it('keeps a removed statement from joining its neighbors', function()
    -- Without the `do end`, `("x"):upper()` would continue `tostring` on
    -- the line before as a call.
    local value = run_entry 'local s = tostring\nif false then end\nreturn ("x"):upper()\n'
    assert.equal(value, 'X')
  end)

  it('keeps the lines after a removed branch in place', function()
    local _, _, line = run_entry 'if false then\n  local a = 1\n  local b = 2\nend\nerror("here")\n'
    assert.equal(line, 5)
  end)
end)
