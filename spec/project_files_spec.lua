--- @diagnostic disable: undefined-field

local h = require 'spec.helpers'

local fixture = h.fixture
local cli = h.cli
local run_fail = h.run_fail
local load_module = h.load_module

after_each(h.remove_created)

describe('project files', function()
  -- `remove` reads both files before it looks at its argument, so it checks
  -- them without touching git or the network.
  --- @param files table<string, string>
  --- @param pattern string
  local function rejects(files, pattern)
    run_fail({ '-C', fixture(files), 'remove', 'dep' }, pattern)
  end

  --- @param entry any
  --- @return string
  local function manifest(entry) return vim.json.encode { dependencies = { dep = entry } } end

  --- @param fields table<string, any>
  --- @return string
  local function lock(fields)
    local entry = {
      source = 'https://example.com/dep',
      ref = 'v1.0.0',
      kind = 'tag',
      commit = string.rep('a', 40),
      built_with = '0.1.0',
      sha256 = string.rep('b', 64),
    }
    return vim.json.encode {
      lock_version = fields.lock_version or 1,
      dependencies = { dep = vim.tbl_extend('force', entry, fields.entry or {}) },
    }
  end

  it(
    'rejects a manifest that is not JSON',
    function() rejects({ ['nvim-bundle.json'] = '{' }, 'nvim-bundle.json is not valid JSON') end
  )

  it(
    'rejects a manifest that is not an object',
    function() rejects({ ['nvim-bundle.json'] = '"x"' }, '`(root)`: Expected table') end
  )

  it(
    'rejects an object entry without a repo',
    function()
      rejects(
        { ['nvim-bundle.json'] = manifest { ref = 'v1' } },
        '`.dependencies["dep"].repo`: Expected string'
      )
    end
  )

  it(
    'rejects an unknown field in an object entry',
    function()
      rejects(
        { ['nvim-bundle.json'] = manifest { repo = 'me/dep', reop = 'x' } },
        '`.dependencies["dep"].reop`: Unexpected key'
      )
    end
  )

  it('reports only the object form for a bad object entry', function()
    local proc = cli {
      '-C',
      fixture { ['nvim-bundle.json'] = manifest { repo = 'me/dep', exclude = 'x' } },
      'remove',
      'dep',
    }
    local stderr = proc.stderr or ''
    assert.are.equal(1, proc.code)
    assert.is_truthy(stderr:find('`.dependencies["dep"].exclude`: Expected array', 1, true))
    assert.is_falsy(stderr:find('alt', 1, true), stderr)
  end)

  it(
    'names both forms for an entry of another type',
    function()
      rejects(
        { ['nvim-bundle.json'] = manifest(42) },
        '`.dependencies["dep"]`: Expected string or table'
      )
    end
  )

  it(
    'treats a null field as absent',
    function()
      rejects({ ['nvim-bundle.json'] = '{"dependencies": null}' }, 'dep is not a dependency')
    end
  )

  it(
    'rejects a lock in an unknown format',
    function()
      rejects(
        { ['nvim-bundle.lock.json'] = lock { lock_version = 2 } },
        'nvim-bundle.lock.json: Validation failed'
      )
    end
  )

  it(
    'rejects a lock entry with an unknown ref kind',
    function()
      rejects(
        { ['nvim-bundle.lock.json'] = lock { entry = { kind = 'commit' } } },
        '`.dependencies["dep"].kind`: Expected one of'
      )
    end
  )

  it('rejects an unknown build option from the Lua API', function()
    local root = fixture { ['entry.lua'] = 'return 1\n' }
    local ok, err = pcall(load_module().build, { root = root, entry = 'entry', exlude = {} })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find('`.exlude`: Unexpected key', 1, true), tostring(err))
  end)
end)
