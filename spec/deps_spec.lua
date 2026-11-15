local Test = require 'nvim-bundle.vendor.test'
local h = require 'spec.helpers'
local describe, it, after_each = Test.describe, Test.it, Test.after_each
local assert = Test.assert

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
    assert.equal(vendored:sub(1, 23), '---@diagnostic disable\n')
    assert.equal(require_vendored(project, 'dep'), 'dep')
    local lock = read_json(project .. '/nvim-bundle.lock.json')
    assert.equal(lock.dependencies.dep.sha256, vim.fn.sha256(vendored))
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
    assert.equal(load_bundle(vendored)()['dep']().util, 'dep-util')
    assert.deep_equal(read_json(project .. '/nvim-bundle.json'), {
      name = 'myplug',
      dependencies = { dep = dep.url .. '@v1.0.0' },
    })
    assert.deep_equal(read_json(project .. '/nvim-bundle.lock.json'), {
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
    })
  end)

  it("ignores the build settings in the dependency's own nvim-bundle.json", function()
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
    assert.equal(require_vendored(project, 'dep'), 'dep')
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

    assert.equal(require_vendored(project, 'dep'), 'dep')
    assert.equal(read_json(project .. '/nvim-bundle.json').dependencies.dep, 'jrop/dep.nvim@v1.0.0')
    assert.equal(
      read_json(project .. '/nvim-bundle.lock.json').dependencies.dep.source,
      'https://github.com/jrop/dep.nvim'
    )
  end)

  it('resolves a missing tag to the newest stable tag', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "v0.2.0"\n' }, 'v0.2.0')
    dep.commit({ ['lua/dep/init.lua'] = 'return "v0.10.0"\n' }, 'v0.10.0')
    dep.commit({ ['lua/dep/init.lua'] = 'return "v0.11.0-rc1"\n' }, 'v0.11.0-rc1')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

    install(project, { dep.url })

    assert.equal(require_vendored(project, 'dep'), 'v0.10.0')
    assert.equal(read_json(project .. '/nvim-bundle.json').dependencies.dep, dep.url .. '@v0.10.0')
  end)

  it('follows a branch named after @', function()
    local dep = remote()
    local old = dep.commit { ['lua/dep/init.lua'] = 'return "old"\n' }
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    install(project, { dep.url .. '@main' })

    local locked = read_json(project .. '/nvim-bundle.lock.json').dependencies.dep
    assert.equal(locked.ref, 'main')
    assert.equal(locked.kind, 'branch')
    assert.equal(locked.commit, old)

    local new = dep.commit { ['lua/dep/init.lua'] = 'return "new"\n' }
    local proc = cli { '-C', project, 'update' }
    assert.equal(proc.code, 0, proc.stderr)

    assert.equal(proc.stdout, ('updated dep %s -> %s\n'):format(old:sub(1, 7), new:sub(1, 7)))
    assert.equal(require_vendored(project, 'dep'), 'new')
    assert.equal(read_json(project .. '/nvim-bundle.json').dependencies.dep, dep.url .. '@main')
  end)

  it('pins a full commit SHA named after @', function()
    local dep = remote()
    local first = dep.commit { ['lua/dep/init.lua'] = 'return "first"\n' }
    dep.commit { ['lua/dep/init.lua'] = 'return "second"\n' }
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

    install(project, { dep.url .. '@' .. first })

    assert.equal(require_vendored(project, 'dep'), 'first')
    local locked = read_json(project .. '/nvim-bundle.lock.json').dependencies.dep
    assert.equal(locked.kind, 'rev')
    assert.equal(locked.commit, first)
    local proc = cli { '-C', project, 'outdated' }
    assert.equal(proc.stdout, ('dep is pinned to %s\n'):format(first:sub(1, 7)))
  end)

  it('prefers the tag when a tag and a branch share a name', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "tag"\n' }, 'same')
    dep.commit { ['lua/dep/init.lua'] = 'return "branch"\n' }
    dep.branch 'same'
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

    install(project, { dep.url .. '@same' })

    assert.equal(require_vendored(project, 'dep'), 'tag')
    assert.equal(read_json(project .. '/nvim-bundle.lock.json').dependencies.dep.kind, 'tag')
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
    assert.equal(proc.code, 0, proc.stderr)
    assert.equal(proc.stdout, 'installed dep into lua/myplug/vendor/dep.lua\n')

    local vendored = project .. '/lua/myplug/vendor/dep.lua'
    assert.equal(load_bundle(vendored)(), 'core')
    assert.is_nil((slurp(vendored):find('bundled a test', 1, true)))
    local settings = { entry = 'dep.core', root = 'src', exclude = { '**/_test/**' } }
    assert.deep_equal(
      read_json(project .. '/nvim-bundle.json').dependencies.dep,
      vim.tbl_extend('error', settings, { repo = dep.url, ref = 'v1.0.0' })
    )
    assert.deep_equal(
      read_json(project .. '/nvim-bundle.lock.json').dependencies.dep,
      vim.tbl_extend('error', settings, {
        source = dep.url,
        ref = 'v1.0.0',
        kind = 'tag',
        commit = commit,
        built_with = cli_version(),
        sha256 = vim.fn.sha256(slurp(vendored)),
      })
    )

    -- The recorded settings rebuild the same bytes from the lock.
    local bytes = slurp(vendored)
    os.remove(vendored)
    install(project, {})
    assert.equal(slurp(vendored), bytes)
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

    assert.equal(load_bundle(project .. '/lua/myplug/vendor/dep.lua')(), 'core')
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
    assert.equal(slurp(project .. '/lua/myplug/vendor/dep.lua'), 'return "mine"\n')
  end)

  it('overwrites a vendored file that install did not create under --force', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
    local project = fixture {
      ['lua/myplug/init.lua'] = 'return {}\n',
      ['lua/myplug/vendor/dep.lua'] = 'return "mine"\n',
    }

    install(project, { dep.url .. '@v1.0.0', '--force' })

    assert.equal(require_vendored(project, 'dep'), 'dep')
    assert.ok(read_json(project .. '/nvim-bundle.lock.json').dependencies.dep)
  end)
end)

describe('dev dependencies', function()
  it('records a dependency installed with --dev under dev_dependencies', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

    install(project, { '--dev', dep.url .. '@v1.0.0' })

    assert.equal(require_vendored(project, 'dep'), 'dep')
    assert.deep_equal(read_json(project .. '/nvim-bundle.json'), {
      name = 'myplug',
      dependencies = {},
      dev_dependencies = { dep = dep.url .. '@v1.0.0' },
    })
  end)

  it('moves an alias installed again without --dev back to dependencies', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    install(project, { '--dev', dep.url .. '@v1.0.0' })

    install(project, { dep.url .. '@v1.0.0' })

    local manifest = read_json(project .. '/nvim-bundle.json')
    assert.equal(manifest.dependencies.dep, dep.url .. '@v1.0.0')
    assert.is_nil(manifest.dev_dependencies)
  end)

  it('restores a missing dev dependency without moving it', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    install(project, { '--dev', dep.url .. '@v1.0.0' })
    os.remove(project .. '/lua/myplug/vendor/dep.lua')

    local proc = cli { '-C', project, 'install' }
    assert.equal(proc.code, 0, proc.stderr)

    assert.equal(proc.stdout, 'restored dep\n')
    assert.equal(require_vendored(project, 'dep'), 'dep')
    assert.ok(read_json(project .. '/nvim-bundle.json').dev_dependencies.dep)
  end)

  it('updates a dev dependency and keeps it under dev_dependencies', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "v0.1.0"\n' }, 'v0.1.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    install(project, { '--dev', dep.url .. '@v0.1.0' })
    dep.commit({ ['lua/dep/init.lua'] = 'return "v0.2.0"\n' }, 'v0.2.0')

    local outdated = cli { '-C', project, 'outdated' }
    assert.equal(outdated.stdout, 'dep v0.1.0 -> v0.2.0\n')
    local proc = cli { '-C', project, 'update' }
    assert.equal(proc.code, 0, proc.stderr)

    assert.equal(require_vendored(project, 'dep'), 'v0.2.0')
    assert.deep_equal(
      read_json(project .. '/nvim-bundle.json').dev_dependencies,
      { dep = dep.url .. '@v0.2.0' }
    )
  end)

  it('removes a dev dependency', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    install(project, { '--dev', dep.url .. '@v1.0.0' })

    local proc = cli { '-C', project, 'remove', 'dep' }
    assert.equal(proc.code, 0, proc.stderr)

    assert.is_nil(vim.uv.fs_stat(project .. '/lua/myplug/vendor/dep.lua'))
    assert.is_nil(read_json(project .. '/nvim-bundle.json').dev_dependencies)
    assert.is_nil(next(read_json(project .. '/nvim-bundle.lock.json').dependencies))
  end)

  it("leaves a dependency's own dev dependencies out of its bundle", function()
    local dep = remote()
    dep.commit({
      ['nvim-bundle.json'] = vim.json.encode {
        name = 'dep',
        dependencies = { args = 'me/args.nvim@v1.0.0' },
        dev_dependencies = { test = 'me/test.nvim@v1.0.0' },
      },
      ['lua/dep/init.lua'] = 'return "dep"\n',
      ['lua/dep/vendor/args.lua'] = 'return "args"\n',
      ['lua/dep/vendor/test.lua'] = 'return "test"\n',
    }, 'v1.0.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }

    install(project, { dep.url .. '@v1.0.0' })

    local registry = load_bundle(project .. '/lua/myplug/vendor/dep.lua')()
    assert.equal(registry['dep.vendor.args'](), 'args')
    assert.is_nil(registry['dep.vendor.test'])
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

    assert.equal(slurp(vendored), original)
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

    assert.equal(require_vendored(project, 'dep'), 'v0.2.0')
    assert.equal(read_json(project .. '/nvim-bundle.lock.json').dependencies.dep.ref, 'v0.2.0')
  end)

  it('needs no network when every vendored file matches the lock', function()
    local dep = remote()
    dep.commit({ ['lua/dep/init.lua'] = 'return "dep"\n' }, 'v1.0.0')
    local project = fixture { ['lua/myplug/init.lua'] = 'return {}\n' }
    install(project, { dep.url .. '@v1.0.0' })
    vim.fn.delete((dep.url:gsub('^file://', '')), 'rf')

    local proc = cli { '-C', project, 'install' }
    assert.equal(proc.code, 0, proc.stderr)
    assert.equal(proc.stdout, 'dependencies are up to date\n')
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
    assert.equal(slurp(vendored), 'return "edited"\n')
    assert.equal(slurp(project .. '/nvim-bundle.lock.json'), lock)
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
    assert.ok(vim.uv.fs_stat(vendor_dir .. 'keep.lua'))
    assert.ok(vim.uv.fs_stat(vendor_dir .. 'handwritten.lua'))
    assert.deep_equal(
      vim.tbl_keys(read_json(project .. '/nvim-bundle.lock.json').dependencies),
      { 'keep' }
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
    assert.equal(proc.code, 0, proc.stderr)

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
    assert.equal(proc.code, 0, proc.stderr)

    assert.equal(proc.stdout, 'updated dep v0.1.0 -> v0.2.0\n')
    assert.equal(require_vendored(project, 'dep'), 'v0.2.0')
    assert.equal(read_json(project .. '/nvim-bundle.json').dependencies.dep, dep.url .. '@v0.2.0')
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
    assert.equal(proc.code, 0, proc.stderr)

    assert.equal(proc.stdout, ('updated tracked %s -> %s\n'):format(old:sub(1, 7), new:sub(1, 7)))
    assert.equal(require_vendored(project, 'tracked'), 'new')
    assert.equal(require_vendored(project, 'pinned'), 'pinned')
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
    assert.equal(proc.code, 0, proc.stderr)

    assert.equal(
      proc.stdout,
      ('pinned is pinned to %s\ntagged v0.1.0 -> v0.2.0\ntracked %s -> %s\n'):format(
        rev:sub(1, 7),
        old:sub(1, 7),
        new:sub(1, 7)
      )
    )
    assert.equal(slurp(project .. '/nvim-bundle.json'), manifest)
  end)
end)
