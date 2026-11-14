--- @diagnostic disable: undefined-field

local h = require 'spec.helpers'

local fixture = h.fixture
local slurp = h.slurp
local compile_bundle = h.compile_bundle

after_each(h.remove_created)

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
