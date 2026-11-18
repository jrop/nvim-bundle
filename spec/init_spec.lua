local Test = require 'nvim-bundle.vendor.test'
local h = require 'spec.helpers'
local scaffold = require 'nvim-bundle.scaffold'
local describe, it, after_each = Test.describe, Test.it, Test.after_each
local assert = Test.assert

local fixture = h.fixture
local slurp = h.slurp
local cli = h.cli
local read_json = h.read_json

after_each(h.remove_created)

--- Git's own URL rewriting, so an `owner/repo` clone reads from `dir`.
--- @param dir string
--- @return table<string, string> env
local function github_at(dir)
  return {
    GIT_CONFIG_COUNT = '1',
    GIT_CONFIG_KEY_0 = 'url.file://' .. dir .. '/.insteadOf',
    GIT_CONFIG_VALUE_0 = 'https://github.com/',
  }
end

--- A stand-in for github.com, holding `jrop/test.nvim` at the tag `init`
--- pins, so `init` installs offline. The stand-in serves this checkout's own
--- vendored runner, so the scaffolded spec runs under a real test.nvim.
--- @return table<string, string> env that points `https://github.com/` at it
local function hub()
  local dir = fixture {}
  local test_nvim = h.remote(dir .. '/jrop/test.nvim')
  test_nvim.commit(
    { ['lua/test.lua'] = slurp 'lua/nvim-bundle/vendor/test.lua' },
    scaffold.TEST_REF
  )
  return github_at(dir)
end

--- A fresh project directory named `basename`, holding `files` (relative
--- path -> contents).
--- @param basename string
--- @param files table<string, string>?
--- @return string
local function project_dir(basename, files)
  local nested = {}
  for rel, content in pairs(files or {}) do
    nested[basename .. '/' .. rel] = content
  end
  local dir = fixture(nested) .. '/' .. basename
  vim.fn.mkdir(dir, 'p')
  return dir
end

--- @param dir string
--- @param argv string[]?
--- @param env table<string, string>?
--- @return vim.SystemCompleted
local function init(dir, argv, env)
  local cmd = { '-C', dir, 'init' }
  vim.list_extend(cmd, argv or {})
  return cli(cmd, env or hub())
end

--- @param dir string
--- @param cmd string[]
--- @param env table<string, string>?
--- @return vim.SystemCompleted
local function run_in(dir, cmd, env)
  return vim.system(cmd, { cwd = dir, text = true, env = env }):wait()
end

describe('init', function()
  it('scaffolds a project that passes its own fmt:check and lint', function()
    for _, tool in ipairs { 'stylua', 'emmylua_check' } do
      if vim.fn.executable(tool) == 0 then return Test.pending(tool .. ' is not installed') end
    end
    local dir = project_dir 'foo.nvim'
    assert.equal(init(dir).code, 0)

    -- stylua would reformat the vendored runner, so its locked hash would no
    -- longer match; passing the check means the scaffold ignores it.
    local fmt = run_in(dir, { 'stylua', '--check', '.' })
    assert.equal(fmt.code, 0, fmt.stdout)
    local lint = run_in(dir, { 'emmylua_check', '--warnings-as-errors', '.' })
    assert.equal(lint.code, 0, (lint.stdout or '') .. (lint.stderr or ''))
  end)

  it('names the project after its directory and vendors test.nvim as a dev dependency', function()
    local dir = project_dir 'foo.nvim'

    local proc = init(dir)

    assert.equal(proc.code, 0, proc.stderr)
    local manifest = read_json(dir .. '/nvim-bundle.json')
    assert.equal(manifest.name, 'foo')
    assert.deep_equal(manifest.dev_dependencies.test, {
      repo = 'jrop/test.nvim',
      ref = scaffold.TEST_REF,
      entry = 'test',
    })
    assert.ok(vim.uv.fs_stat(dir .. '/lua/foo/vendor/test.lua'), 'test.nvim is not vendored')
  end)

  it('strips a leading nvim- from the directory, unless a name is given', function()
    local prefixed = project_dir 'nvim-bar'
    assert.equal(init(prefixed).code, 0)
    assert.equal(read_json(prefixed .. '/nvim-bundle.json').name, 'bar')

    local named = project_dir 'whatever.nvim'
    local proc = init(named, { 'baz' })
    assert.equal(proc.code, 0, proc.stderr)
    assert.equal(read_json(named .. '/nvim-bundle.json').name, 'baz')
    assert.ok(vim.uv.fs_stat(named .. '/lua/baz.lua'), 'lua/baz.lua is missing')
    assert.ok(vim.uv.fs_stat(named .. '/lua/baz/vendor/test.lua'), 'test.nvim is not vendored')
  end)

  it('creates a git repository in the project', function()
    local dir = project_dir 'foo.nvim'

    assert.equal(init(dir).code, 0)

    assert.ok(vim.uv.fs_stat(dir .. '/.git'), 'no git repository')
  end)

  it('leaves a project inside a git work tree to that repository', function()
    local parent = fixture {}
    run_in(parent, { 'git', 'init', '-q' })
    local dir = parent .. '/foo.nvim'
    vim.fn.mkdir(dir, 'p')

    assert.equal(init(dir).code, 0)

    assert.is_nil(vim.uv.fs_stat(dir .. '/.git'))
  end)

  it('refuses a directory that already has nvim-bundle.json', function()
    local manifest = '{ "name": "mine" }\n'
    local dir = project_dir('foo.nvim', { ['nvim-bundle.json'] = manifest })

    local proc = init(dir)

    assert.equal(proc.code, 1, proc.stdout)
    assert.contains(proc.stderr or '', 'nvim-bundle.json already exists')
    assert.equal(slurp(dir .. '/nvim-bundle.json'), manifest)
    assert.is_nil(vim.uv.fs_stat(dir .. '/mise.toml'))
  end)

  it('keeps the files a directory already has, and reports each one', function()
    local gitignore = 'node_modules/\n'
    local dir = project_dir('foo.nvim', { ['.gitignore'] = gitignore })

    local proc = init(dir)

    assert.equal(proc.code, 0, proc.stderr)
    assert.equal(slurp(dir .. '/.gitignore'), gitignore)
    assert.contains(proc.stdout or '', 'kept .gitignore')
    assert.ok(vim.uv.fs_stat(dir .. '/mise.toml'), 'mise.toml is missing')
  end)

  it('leaves a scaffold that `install` completes when the clone fails', function()
    local dir = project_dir 'foo.nvim'

    -- An empty hub has no test.nvim to clone.
    local proc = init(dir, {}, github_at(fixture {}))

    assert.equal(proc.code, 1, proc.stdout)
    assert.contains(proc.stderr or '', 'run `nvim-bundle install`')
    assert.ok(vim.uv.fs_stat(dir .. '/mise.toml'), 'mise.toml is missing')
    h.install(dir, {}, hub())
    assert.ok(vim.uv.fs_stat(dir .. '/lua/foo/vendor/test.lua'), 'test.nvim is not vendored')
  end)

  it('warns that a checkout pins a version that may be unreleased', function()
    local proc = init(project_dir 'foo.nvim')

    assert.equal(proc.code, 0, proc.stderr)
    assert.contains(
      proc.stderr or '',
      ('warning: pinned unreleased nvim-bundle %s in mise.toml'):format(h.cli_version())
    )
  end)

  it('scaffolds a module whose spec passes under the vendored runner', function()
    local dir = project_dir 'foo.nvim'
    assert.equal(init(dir).code, 0)

    local proc = run_in(dir, { 'nvim', '--clean', '-l', 'lua/foo/vendor/test.lua' })

    assert.equal(proc.code, 0, (proc.stdout or '') .. (proc.stderr or ''))
    assert.contains(proc.stdout or '', 'spec/foo_spec.lua')
    assert.contains(proc.stdout or '', '1 passed, 0 failed')
  end)

  it('writes a GitHub workflow that runs the ci task', function()
    local dir = project_dir 'foo.nvim'
    assert.equal(init(dir).code, 0)

    local workflow = slurp(dir .. '/.github/workflows/ci.yaml')
    assert.contains(workflow, 'jdx/mise-action')
    assert.contains(workflow, 'run: mise run ci')
  end)

  it('writes a mise.toml that pins this nvim-bundle and runs the test grid', function()
    local dir = project_dir 'foo.nvim'
    assert.equal(init(dir).code, 0)

    local mise_toml = slurp(dir .. '/mise.toml')
    assert.contains(mise_toml, ('"github:jrop/nvim-bundle" = "%s"'):format(h.cli_version()))
    assert.contains(mise_toml, 'lua/foo/vendor/test.lua')
    -- mise refuses to read a config it has not been told to trust.
    local proc = run_in(
      dir,
      { 'mise', 'tasks', 'ls', '--no-header' },
      { MISE_TRUSTED_CONFIG_PATHS = dir }
    )
    assert.equal(proc.code, 0, proc.stderr)
    local tasks = vim.tbl_map(
      function(line) return line:match '^(%S+)' end,
      vim.split(vim.trim(proc.stdout or ''), '\n')
    )
    table.sort(tasks)
    assert.deep_equal(
      tasks,
      { 'ci', 'fmt', 'fmt:check', 'lint', 'test', 'test:all', 'test:coverage', 'test:version' }
    )
  end)
end)
