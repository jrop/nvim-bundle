--- @diagnostic disable: undefined-field

local h = require 'spec.helpers'

local run_entry = h.run_entry

after_each(h.remove_created)

describe('dead code', function()
  it('removes a statement whose condition is false', function()
    local value, module =
      run_entry 'if false then error("dead") end\nwhile false do error("dead") end\nreturn 1\n'
    assert.are.equal(1, value)
    assert.are.equal('do end\ndo end\nreturn 1\n', module)
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
    assert.are.same({ inside = 1 }, value)
    assert.is_falsy(module:find('r.other', 1, true))
    assert.is_truthy(module:find('do   return r end', 1, true), module)
  end)

  it('makes the first kept elseif the if', function()
    local value, module =
      run_entry 'if false then return 1 elseif vim.g.flag then return 2 else return 3 end\n'
    assert.are.equal(3, value)
    assert.are.equal('    if vim.g.flag then return 2 else return 3 end\n', module)
  end)

  it('makes a true elseif the else and drops the arms after it', function()
    local value, module =
      run_entry 'if vim.g.flag then return 1 elseif true then return 2 elseif vim.g.other then return 3 else return 4 end\n'
    assert.are.equal(2, value)
    assert.are.equal('if vim.g.flag then return 1 else   return 2   end\n', module)
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
    assert.are.same({ eq = true, not_nil = true, zero = true, or_ = true }, value)
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
    assert.are.equal(src, module)
  end)

  it('removes a branch chosen by a define', function()
    local value, module = run_entry(
      'if vim.g.env == "production" then return "prod" else return "dev" end\n',
      { ['vim.g.env'] = '"production"' }
    )
    assert.are.equal('prod', value)
    assert.is_falsy(module:find('"dev"', 1, true))
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
    assert.are.equal('ok', value)
  end)

  it('keeps a removed statement from joining its neighbors', function()
    -- Without the `do end`, `("x"):upper()` would continue `tostring` on
    -- the line before as a call.
    local value = run_entry 'local s = tostring\nif false then end\nreturn ("x"):upper()\n'
    assert.are.equal('X', value)
  end)

  it('keeps the lines after a removed branch in place', function()
    local _, _, line = run_entry 'if false then\n  local a = 1\n  local b = 2\nend\nerror("here")\n'
    assert.are.equal(5, line)
  end)
end)
