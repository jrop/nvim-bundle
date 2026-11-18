--- `init`: scaffold a project in the cwd.
local deps = require 'nvim-bundle.deps'
local files = require 'nvim-bundle.files'
local git = require 'nvim-bundle.git'
local version = require 'nvim-bundle.version'

local M = {}

--- Every scaffold gets the same runner, so a project's first `mise run ci`
--- does not depend on the day it was created.
M.TEST_REF = 'v0.3.0'

--- Each template is keyed by its path. `@NAME@` stands for the project name,
--- and `@VERSION@` for the nvim-bundle that ran `init`. Both tokens are plain
--- text to Lua patterns, tera, and the shell, so a template can contain any of
--- their syntax.
--- @type table<string, string>
local TEMPLATES = {
  ['mise.toml'] = [=[
################################################################################
## Tools
################################################################################

# Both emmylua tools ship in one GitHub release, and mise lists each repository
# once, so an alias gives each tool its own name and install directory.
[tool_alias]
emmylua_check = "github:EmmyLuaLs/emmylua-analyzer-rust"
emmylua_ls = "github:EmmyLuaLs/emmylua-analyzer-rust"

[tools]
"aqua:neovim/neovim" = "{{vars.nvim_default}}"
"github:jrop/nvim-bundle" = "@VERSION@"
stylua = "2.6.0"

[tools.emmylua_check]
version = "0.25.1"
bin = "emmylua_check"
platforms.linux-x64 = { asset_pattern = "emmylua_check-linux-x64.tar.gz" }
platforms.macos-arm64 = { asset_pattern = "emmylua_check-darwin-arm64.tar.gz" }
platforms.macos-x64 = { asset_pattern = "emmylua_check-darwin-x64.tar.gz" }

[tools.emmylua_ls]
version = "0.25.1"
bin = "emmylua_ls"
platforms.linux-x64 = { asset_pattern = "emmylua_ls-linux-x64.tar.gz" }
platforms.macos-arm64 = { asset_pattern = "emmylua_ls-darwin-arm64.tar.gz" }
platforms.macos-x64 = { asset_pattern = "emmylua_ls-darwin-x64.tar.gz" }

################################################################################
# Vars
################################################################################

# The Neovim versions the specs run against. The default is the one `test` and
# the tools above use, so moving the grid forward is an edit to these lines.
[vars]
nvim_default = "0.12.6"
nvim_versions = "0.10.4 0.11.7 {{vars.nvim_default}} nightly"

################################################################################
# Env
################################################################################

[env]
# .emmyrc.json loads Neovim's runtime as a type library through $VIMRUNTIME. An
# editor sets it for its language server, but a shell running `emmylua_check`
# does not.
VIMRUNTIME = { value = "{{ exec(command='nvim --clean --headless +\"lua io.stdout:write(vim.env.VIMRUNTIME)\" +qa') }}", tools = true }

################################################################################
# Tasks
################################################################################

[tasks]
fmt = "stylua ."
"fmt:check" = "stylua --check ."
lint = "emmylua_check --warnings-as-errors ."

[tasks."test:version"]
usage = '''
arg "<version>"
flag "--coverage"
'''
run = '''
tool="aqua:neovim/neovim@$usage_version"
[ "$usage_version" = nightly ] && tool='vfox:jdx/vfox-neovim@nightly'
# With auto-install off, `mise exec` on a missing version warns and runs the
# default `nvim` from PATH, so the suite would pass under the wrong version.
# Installing first makes a missing version an error instead.
mise install "$tool"
# The nightly tag moves, so refresh it when its checksum changed.
[ "$usage_version" = nightly ] && { mise upgrade "$tool" >/dev/null 2>&1 || true; }
mise exec "$tool" -- nvim --clean -l lua/@NAME@/vendor/test.lua ${usage_coverage:+--coverage}
'''

[tasks.test]
run = "mise run test:version {{vars.nvim_default}}"

[tasks."test:all"]
run = '''
for v in {{vars.nvim_versions}}; do
  mise run test:version "$v"
done
'''

[tasks."test:coverage"]
run = "mise run test:version --coverage {{vars.nvim_default}}"

# `install --frozen` fails when a vendored file no longer matches the lock, so
# a hand-edited or reformatted dependency fails CI before the specs run.
[tasks.ci]
run = '''
nvim-bundle install --frozen
mise run fmt:check
mise run lint
mise run test:all
'''
]=],

  -- CI runs the same `ci` task a contributor runs locally, so the workflow
  -- never drifts from mise.toml. mise installs the `github:` tools through the
  -- GitHub API, which rate-limits anonymous runners, so the job passes its
  -- token.
  ['.github/workflows/ci.yaml'] = [=[
# yaml-language-server: $schema=https://json.schemastore.org/github-workflow.json
name: ci

on:
  workflow_dispatch:
  pull_request:
  push:
    branches: ["*"]
    tags: ["*"]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

env:
  GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  MISE_EXPERIMENTAL: true

jobs:
  ci:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v2
      - run: mise run ci
]=],

  ['.gitignore'] = [=[
dist/
]=],

  -- A vendored file's locked hash covers its exact bytes, so formatting it
  -- would fail the next `install --frozen`.
  ['.styluaignore'] = [=[
dist/
lua/@NAME@/vendor/
]=],

  ['.stylua.toml'] = [=[
syntax = "LuaJIT"
call_parentheses = "None"
collapse_simple_statement = "Always"
column_width = 100
indent_type = "Spaces"
indent_width = 2
quote_style = "AutoPreferSingle"

[sort_requires]
enabled = true
]=],

  ['.emmyrc.json'] = [=[
{
  "$schema": "https://raw.githubusercontent.com/EmmyLuaLs/emmylua-analyzer-rust/refs/heads/main/crates/emmylua_code_analysis/resources/schema.json",
  "runtime": {
    "version": "LuaJIT"
  },
  "workspace": {
    "ignoreDir": [
      "dist"
    ],
    "library": [
      "$VIMRUNTIME"
    ]
  }
}
]=],

  ['lua/@NAME@.lua'] = [=[
local M = {}

--- @return string
function M.hello() return 'hello from @NAME@' end

return M
]=],

  ['spec/@NAME@_spec.lua'] = [=[
local Test = require '@NAME@.vendor.test'
local describe, it = Test.describe, Test.it
local assert = Test.assert

local M = require '@NAME@'

describe('@NAME@', function()
  it('says hello', function() assert.equal(M.hello(), 'hello from @NAME@') end)
end)
]=],
}

--- @param name string?
--- @return string name, string[] kept the paths that already existed, sorted
function M.init(name)
  -- A manifest means the project already exists, so every other file is
  -- the project's own, not a scaffold to fill in.
  if files.read 'nvim-bundle.json' then error('nvim-bundle: nvim-bundle.json already exists', 0) end
  git.init_repository()
  name = name or vim.fs.basename(vim.fn.getcwd()):gsub('%.nvim$', ''):gsub('^nvim%-', '')
  local function fill(s) return (s:gsub('@NAME@', name):gsub('@VERSION@', version)) end
  -- The manifest lists test.nvim before anything is cloned, so when the clone
  -- fails, a plain `install` finishes the scaffold.
  files.write_json('nvim-bundle.json', {
    name = name,
    dev_dependencies = { test = { repo = 'jrop/test.nvim', ref = M.TEST_REF, entry = 'test' } },
  })
  local kept = {}
  for path, template in pairs(TEMPLATES) do
    path = fill(path)
    if files.read(path) then
      kept[#kept + 1] = path
    else
      files.write(path, fill(template))
    end
  end
  table.sort(kept)
  local ok, err = pcall(deps.sync)
  if not ok then error(('%s\nnvim-bundle: run `nvim-bundle install` to finish'):format(err), 0) end
  return name, kept
end

return M
