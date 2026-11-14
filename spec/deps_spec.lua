--- @diagnostic disable: undefined-field

local h = require 'spec.helpers'

local fixture = h.fixture
local slurp = h.slurp
local cli = h.cli
local run_fail = h.run_fail
local load_bundle = h.load_bundle
local read_json = h.read_json
local write_json = h.write_json
local remote = h.remote
local cli_version = h.cli_version
local require_vendored = h.require_vendored
local install = h.install

after_each(h.remove_created)

describe('install', function()
  it('silences diagnostics in the vendored file, under its locked hash', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    install(project, { dep.url .. '@v1.0.0' })

    local vendored = slurp(project .. '/lua/myplug/vendor/dep.lua')
    assert.are.equal('---@diagnostic disable\n', vendored:sub(1, 23))
    assert.are.equal('dep', require_vendored(project, 'dep'))
    local lock = read_json(project .. '/nvim-bundle.lock.json')
    assert.are.equal(vim.fn.sha256(vendored), lock.dependencies.dep.sha256)
  end)

  it('vendors a dependency built from its tag', function()
    local dep = remote()
    local commit = dep.commit({
      ['lua/dep/init.lua'] = 'return { util = require "dep.util" }\n',
      ['lua/dep/util.lua'] = 'return "dep-util"\n',
    }, 'v1.0.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

    install(project, { dep.url .. '@v1.0.0' })

    -- With no entry, the bundle is a registry, as `build` makes, and
    -- `dep.util` resolves statically although the host cannot see it.
    local vendored = project .. '/lua/myplug/vendor/dep.lua'
    assert.are.equal('dep-util', load_bundle(vendored)()['dep']().util)
    assert.are.same({
      name = 'myplug',
      dependencies = { dep = dep.url .. '@v1.0.0' },
    }, read_json(project .. '/nvim-bundle.json'))
    assert.are.same({
      lock_version = 1,
      dependencies = {
        dep = {
          source = dep.url,
          ref = 'v1.0.0',
          kind = 'tag',
          commit = commit,
          built_with = cli_version(),
          sha256 = vim.fn.sha256(slurp(vendored)),
        },
      },
    }, read_json(project .. '/nvim-bundle.lock.json'))
  end)

  it("ignores the dependency's own nvim-bundle.json", function()
    local dep = remote()
    dep.commit({
      ['nvim-bundle.json'] = vim.json.encode {
        name = 'other',
        build = { entry = 'dep', bin = true },
      },
      ['lua/dep/init.lua'] = 'return "dep"\n',
    }, 'v1.0.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    install(project, { dep.url .. '@v1.0.0' })

    local vendored = project .. '/lua/myplug/vendor/dep.lua'
    assert.is_nil(slurp(vendored):match '^#!')
    assert.are.equal('dep', require_vendored(project, 'dep'))
  end)

  it('expands owner/repo to its GitHub URL', function()
    -- git rewrites the GitHub URL to a local directory, so the shorthand is
    -- tested through the same clone a real install runs.
    local hub = fixture {}
    local dep = remote(hub .. '/jrop/dep.nvim')
    dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
    local env = {
      GIT_CONFIG_COUNT = '1',
      GIT_CONFIG_KEY_0 = 'url.file://' .. hub .. '/.insteadOf',
      GIT_CONFIG_VALUE_0 = 'https://github.com/',
    }
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

    install(project, { 'jrop/dep.nvim@v1.0.0' }, env)

    assert.are.equal('dep', require_vendored(project, 'dep'))
    assert.are.equal(
      'jrop/dep.nvim@v1.0.0',
      read_json(project .. '/nvim-bundle.json').dependencies.dep
    )
    assert.are.equal(
      'https://github.com/jrop/dep.nvim',
      read_json(project .. '/nvim-bundle.lock.json').dependencies.dep.source
    )
  end)

  it('resolves a missing tag to the newest stable tag', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "v0.2.0"\n' }, 'v0.2.0')
    dep.commit({ ['lua/dep/init.lua'] = 'return "v0.10.0"\n' }, 'v0.10.0')
    dep.commit({ ['lua/dep/init.lua'] = 'return "v0.11.0-rc1"\n' }, 'v0.11.0-rc1')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

    install(project, { dep.url })

    assert.are.equal('v0.10.0', require_vendored(project, 'dep'))
    assert.are.equal(
      dep.url .. '@v0.10.0',
      read_json(project .. '/nvim-bundle.json').dependencies.dep
    )
  end)

  it('follows a branch named after @', function()
    local dep = remote()
    local old = dep.commit { ['lua/dep/init.lua'] = 'return "old"\n' }
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    install(project, { dep.url .. '@main' })

    local locked = read_json(project .. '/nvim-bundle.lock.json').dependencies.dep
    assert.are.equal('main', locked.ref)
    assert.are.equal('branch', locked.kind)
    assert.are.equal(old, locked.commit)

    local new = dep.commit { ['lua/dep/init.lua'] = 'return "new"\n' }
    local proc = cli { '-C', project, 'update' }
    assert.are.equal(0, proc.code, proc.stderr)

    assert.are.equal(('updated dep %s -> %s\n'):format(old:sub(1, 7), new:sub(1, 7)), proc.stdout)
    assert.are.equal('new', require_vendored(project, 'dep'))
    assert.are.equal(dep.url .. '@main', read_json(project .. '/nvim-bundle.json').dependencies.dep)
  end)

  it('pins a full commit SHA named after @', function()
    local dep = remote()
    local first = dep.commit { ['lua/dep/init.lua'] = 'return "first"\n' }
    dep.commit { ['lua/dep/init.lua'] = 'return "second"\n' }
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

    install(project, { dep.url .. '@' .. first })

    assert.are.equal('first', require_vendored(project, 'dep'))
    local locked = read_json(project .. '/nvim-bundle.lock.json').dependencies.dep
    assert.are.equal('rev', locked.kind)
    assert.are.equal(first, locked.commit)
    local proc = cli { '-C', project, 'outdated' }
    assert.are.equal(('dep is pinned to %s\n'):format(first:sub(1, 7)), proc.stdout)
  end)

  it('prefers the tag when a tag and a branch share a name', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "tag"\n' }, 'same')
    dep.commit { ['lua/dep/init.lua'] = 'return "branch"\n' }
    dep.branch 'same'
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

    install(project, { dep.url .. '@same' })

    assert.are.equal('tag', require_vendored(project, 'dep'))
    assert.are.equal('tag', read_json(project .. '/nvim-bundle.lock.json').dependencies.dep.kind)
  end)

  it('rejects an @ref that is neither a tag nor a branch', function()
    local dep = remote()
    dep.commit { ['lua/dep/init.lua'] = 'return "dep"\n' }
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

    run_fail(
      { '-C', project, 'install', dep.url .. '@nope' },
      'nope is neither a tag nor a branch of ' .. dep.url
    )
  end)

  it('builds with the entry, root, and excludes given on the command line', function()
    local dep = remote()
    local commit = dep.commit({
      ['src/dep/init.lua'] = 'return { core = require "dep.core" }\n',
      ['src/dep/core.lua'] = 'return "core"\n',
      ['src/dep/_test/core_spec.lua'] = 'error "bundled a test"\n',
    }, 'v1.0.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

    local proc = cli {
      '-C',
      project,
      'install',
      dep.url .. '@v1.0.0',
      'dep.core',
      '--root',
      'src',
      '--exclude',
      '**/_test/**',
    }
    assert.are.equal(0, proc.code, proc.stderr)
    assert.are.equal('installed dep into lua/myplug/vendor/dep.lua\n', proc.stdout)

    local vendored = project .. '/lua/myplug/vendor/dep.lua'
    assert.are.equal('core', load_bundle(vendored)())
    assert.is_nil(slurp(vendored):find('bundled a test', 1, true))
    local settings = { entry = 'dep.core', root = 'src', exclude = { '**/_test/**' } }
    assert.are.same(
      vim.tbl_extend('error', settings, { repo = dep.url, ref = 'v1.0.0' }),
      read_json(project .. '/nvim-bundle.json').dependencies.dep
    )
    assert.are.same(
      vim.tbl_extend('error', settings, {
        source = dep.url,
        ref = 'v1.0.0',
        kind = 'tag',
        commit = commit,
        built_with = cli_version(),
        sha256 = vim.fn.sha256(slurp(vendored)),
      }),
      read_json(project .. '/nvim-bundle.lock.json').dependencies.dep
    )

    -- The recorded settings rebuild the same bytes from the lock.
    local bytes = slurp(vendored)
    os.remove(vendored)
    install(project, {})
    assert.are.equal(bytes, slurp(vendored))
  end)

  it('builds with the settings an object entry records', function()
    local dep = remote()
    dep.commit({
      ['src/dep/init.lua'] = 'return { core = require "dep.core" }\n',
      ['src/dep/core.lua'] = 'return "core"\n',
    }, 'v1.0.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    write_json(project .. '/nvim-bundle.json', {
      dependencies = {
        dep = { repo = dep.url, ref = 'v1.0.0', root = 'src', entry = 'dep.core' },
      },
    })

    install(project, {})

    assert.are.equal('core', load_bundle(project .. '/lua/myplug/vendor/dep.lua')())
  end)

  it('refuses to overwrite a vendored file that install did not create', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
    local project = fixture {
      ['lua/myplug/init.lua'] = 'return {}\n',
      ['lua/myplug/vendor/dep.lua'] = 'return "mine"\n',
    }

    run_fail(
      { '-C', project, 'install', dep.url .. '@v1.0.0' },
      'lua/myplug/vendor/dep.lua exists but is not in the lock; move it, pass --as, or pass --force'
    )
    assert.are.equal('return "mine"\n', slurp(project .. '/lua/myplug/vendor/dep.lua'))
  end)

  it('overwrites a vendored file that install did not create under --force', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
    local project = fixture {
      ['lua/myplug/init.lua'] = 'return {}\n',
      ['lua/myplug/vendor/dep.lua'] = 'return "mine"\n',
    }

    install(project, { dep.url .. '@v1.0.0', '--force' })

    assert.are.equal('dep', require_vendored(project, 'dep'))
    assert.is_truthy(read_json(project .. '/nvim-bundle.lock.json').dependencies.dep)
  end)
end)

describe('install without arguments', function()
  it('rebuilds a missing vendored file from its locked commit', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "original"\n' }, 'v1.0.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    install(project, { dep.url .. '@v1.0.0' })
    local vendored = project .. '/lua/myplug/vendor/dep.lua'
    local original = slurp(vendored)

    -- Moving the tag must not change what the lock restores.
    dep.commit({ ['lua/dep/init.lua'] = 'return "moved"\n' }, 'v1.0.0')
    os.remove(vendored)
    install(project, {})

    assert.are.equal(original, slurp(vendored))
  end)

  it('resolves an entry whose manifest tag was edited', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "v0.1.0"\n' }, 'v0.1.0')
    dep.commit({ ['lua/dep/init.lua'] = 'return "v0.2.0"\n' }, 'v0.2.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    install(project, { dep.url .. '@v0.1.0' })

    local manifest = read_json(project .. '/nvim-bundle.json')
    manifest.dependencies.dep = dep.url .. '@v0.2.0'
    write_json(project .. '/nvim-bundle.json', manifest)
    install(project, {})

    assert.are.equal('v0.2.0', require_vendored(project, 'dep'))
    assert.are.equal('v0.2.0', read_json(project .. '/nvim-bundle.lock.json').dependencies.dep.ref)
  end)

  it('needs no network when every vendored file matches the lock', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    install(project, { dep.url .. '@v1.0.0' })
    vim.fn.delete((dep.url:gsub('^file://', '')), 'rf')

    local proc = cli { '-C', project, 'install' }
    assert.are.equal(0, proc.code, proc.stderr)
    assert.are.equal('dependencies are up to date\n', proc.stdout)
  end)

  it('fails under --frozen instead of changing anything', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    install(project, { dep.url .. '@v1.0.0' })
    install(project, { '--frozen' })

    local vendored = project .. '/lua/myplug/vendor/dep.lua'
    local f = assert(io.open(vendored, 'wb'))
    f:write 'return "edited"\n'
    f:close()
    local lock = slurp(project .. '/nvim-bundle.lock.json')

    run_fail({ '-C', project, 'install', '--frozen' }, 'would restore dep')
    assert.are.equal('return "edited"\n', slurp(vendored))
    assert.are.equal(lock, slurp(project .. '/nvim-bundle.lock.json'))
  end)

  it('removes a vendored file whose dependency left the manifest', function()
    local keep, drop = remote(), remote()
    keep.commit({ ['lua/keep/init.lua'] = 'return "keep"\n' }, 'v1.0.0')
    drop.commit({ ['lua/drop/init.lua'] = 'return "drop"\n' }, 'v1.0.0')
    local project = fixture {
      ['lua/myplug/init.lua'] = 'return {}\n',
      ['lua/myplug/vendor/handwritten.lua'] = 'return "mine"\n',
    }
    install(project, { keep.url .. '@v1.0.0' })
    install(project, { drop.url .. '@v1.0.0' })

    write_json(project .. '/nvim-bundle.json', {
      name = 'myplug',
      dependencies = { keep = keep.url .. '@v1.0.0' },
    })
    install(project, {})

    local vendor_dir = project .. '/lua/myplug/vendor/'
    assert.is_nil(vim.uv.fs_stat(vendor_dir .. 'drop.lua'))
    assert.is_truthy(vim.uv.fs_stat(vendor_dir .. 'keep.lua'))
    assert.is_truthy(vim.uv.fs_stat(vendor_dir .. 'handwritten.lua'))
    assert.are.same(
      { 'keep' },
      vim.tbl_keys(read_json(project .. '/nvim-bundle.lock.json').dependencies)
    )
  end)
end)

describe('remove', function()
  it('deletes the vendored file and both entries', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    install(project, { dep.url .. '@v1.0.0' })

    local proc = cli { '-C', project, 'remove', 'dep' }
    assert.are.equal(0, proc.code, proc.stderr)

    assert.is_nil(vim.uv.fs_stat(project .. '/lua/myplug/vendor/dep.lua'))
    assert.is_nil(next(read_json(project .. '/nvim-bundle.json').dependencies))
    assert.is_nil(next(read_json(project .. '/nvim-bundle.lock.json').dependencies))
  end)

  it(
    'rejects an alias that is not a dependency',
    function() run_fail({ '-C', fixture {}, 'remove', 'nope' }, 'nope is not a dependency') end
  )
end)

describe('update', function()
  it('moves a tagged dependency to its newest stable tag', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "v0.1.0"\n' }, 'v0.1.0')
    dep.commit({ ['lua/dep/init.lua'] = 'return "v0.2.0"\n' }, 'v0.2.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    install(project, { dep.url .. '@v0.1.0' })

    local proc = cli { '-C', project, 'update' }
    assert.are.equal(0, proc.code, proc.stderr)

    assert.are.equal('updated dep v0.1.0 -> v0.2.0\n', proc.stdout)
    assert.are.equal('v0.2.0', require_vendored(project, 'dep'))
    assert.are.equal(
      dep.url .. '@v0.2.0',
      read_json(project .. '/nvim-bundle.json').dependencies.dep
    )
  end)

  it('moves a branch to its new head and leaves a rev alone', function()
    local tracked, pinned = remote(), remote()
    local old = tracked.commit { ['lua/tracked/init.lua'] = 'return "old"\n' }
    local rev = pinned.commit { ['lua/pinned/init.lua'] = 'return "pinned"\n' }
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    write_json(project .. '/nvim-bundle.json', {
      dependencies = {
        tracked = tracked.url .. '@main',
        pinned = pinned.url .. '@' .. rev,
      },
    })
    install(project, {})
    local new = tracked.commit { ['lua/tracked/init.lua'] = 'return "new"\n' }
    pinned.commit { ['lua/pinned/init.lua'] = 'return "later"\n' }

    local proc = cli { '-C', project, 'update' }
    assert.are.equal(0, proc.code, proc.stderr)

    assert.are.equal(
      ('updated tracked %s -> %s\n'):format(old:sub(1, 7), new:sub(1, 7)),
      proc.stdout
    )
    assert.are.equal('new', require_vendored(project, 'tracked'))
    assert.are.equal('pinned', require_vendored(project, 'pinned'))
  end)
end)

describe('outdated', function()
  it('lists newer tags and branch heads without changing anything', function()
    local tagged, tracked, pinned = remote(), remote(), remote()
    tagged.commit({ ['lua/tagged/init.lua'] = 'return 1\n' }, 'v0.1.0')
    tagged.commit({ ['lua/tagged/init.lua'] = 'return 2\n' }, 'v0.2.0')
    local old = tracked.commit { ['lua/tracked/init.lua'] = 'return 1\n' }
    local rev = pinned.commit { ['lua/pinned/init.lua'] = 'return 1\n' }
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    write_json(project .. '/nvim-bundle.json', {
      dependencies = {
        tagged = tagged.url .. '@v0.1.0',
        tracked = tracked.url .. '@main',
        pinned = pinned.url .. '@' .. rev,
      },
    })
    install(project, {})
    local new = tracked.commit { ['lua/tracked/init.lua'] = 'return 2\n' }
    local manifest = slurp(project .. '/nvim-bundle.json')

    local proc = cli { '-C', project, 'outdated' }
    assert.are.equal(0, proc.code, proc.stderr)

    assert.are.equal(
      ('pinned is pinned to %s\ntagged v0.1.0 -> v0.2.0\ntracked %s -> %s\n'):format(
        rev:sub(1, 7),
        old:sub(1, 7),
        new:sub(1, 7)
      ),
      proc.stdout
    )
    assert.are.equal(manifest, slurp(project .. '/nvim-bundle.json'))
  end)
end)
