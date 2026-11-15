local Test = require 'nvim-bundle.vendor.test'
local h = require 'spec.helpers'
local describe, it, pending, after_each = Test.describe, Test.it, Test.pending, Test.after_each
local assert = Test.assert

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

  -- test.nvim marks a case pending when it is declared, not while it runs, so
  -- whether the checker is installed is decided as the file is collected.
  --- @param name string
  --- @param fn fun()
  local function it_checks(name, fn)
    if vim.fn.executable 'emmylua_check' == 0 then
      return pending(name .. ' (emmylua_check is not installed)')
    end
    it(name, fn)
  end

  local consumer = table.concat({
    "local lib = require 'bundled_lib'",
    '---@type string',
    'local s = lib.util.answer',
    'print(s)',
    '',
  }, '\n')

  local util = '---@class Util\n---@field answer integer\nreturn { answer = 42 }\n'

  it_checks('preserves the type of a required module in the entry', function()
    local root = fixture {
      ['entry.lua'] = "local util = require 'util'\nreturn { util = util }\n",
      ['util.lua'] = util,
    }
    local _, result = compile_bundle(root, 'entry')
    local output = check_types(slurp(result.out), consumer)

    assert.contains(output, 'consumer.lua')
    assert.contains(output, 'assign-type-mismatch')
  end)

  it_checks('types a required bundle as its entry, never nil', function()
    local root = fixture {
      ['entry.lua'] = "local util = require 'util'\nreturn { util = util }\n",
      ['util.lua'] = util,
    }
    local _, result = compile_bundle(root, 'entry')
    local output = check_types(
      slurp(result.out),
      "local lib = require 'bundled_lib'\nprint(lib.util.answer + 1)\n"
    )

    assert.is_nil((output:find('need-check-nil', 1, true)), output)
  end)

  -- emmylua_check 0.25.1 infers a module's type through pcall in only about
  -- half its runs, with any cache shape and on one thread, so a result here
  -- would say nothing about the bundle. Once it is deterministic, this case
  -- should bundle `pcall(require, 'util')` and expect the consumer's
  -- `assign-type-mismatch`, as the cases around it do.
  pending 'preserves types through pcall(require, ...)'

  it_checks('preserves the type of a module through the registry', function()
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

    assert.contains(output, 'consumer.lua')
    assert.contains(output, 'assign-type-mismatch')
  end)
end)
