#!/usr/bin/env -S nvim --clean -l
-- vim: set ft=lua:
-- nvim-bundle: build a single-file Lua bundle from lua/**/*.lua, and vendor
-- git dependencies as bundles built from source.
--
-- Resolvable `require` calls are linked directly to the bundled module
-- functions. Calls that cannot be resolved (computed names, a shadowed
-- `require`, an unparsable module, or a module outside the bundle) remain
-- ordinary host `require` calls.

--- @return boolean
local function is_main()
  local info = debug.getinfo(1, 'S')
  local argv0 = arg and arg[0]
  if not info or not argv0 or info.source:sub(1, 1) ~= '@' then return false end
  local this = vim.fs.normalize(vim.fn.fnamemodify(info.source:sub(2), ':p'))
  return this == vim.fs.normalize(vim.fn.fnamemodify(argv0, ':p'))
end

-- A checkout runs this file directly, so `lua/` is not on `package.path`; the
-- published bundle inlines the vendored module and needs no bootstrap. The
-- vendor-file check keeps a required bundle from touching the host's path.
local running_as_main = is_main()
if running_as_main and arg and arg[0] then
  local script_dir = vim.fs.dirname(vim.fn.fnamemodify(arg[0], ':p'))
  if vim.uv.fs_stat(script_dir .. '/nvim-bundle/vendor/args.lua') then
    package.path = script_dir .. '/?.lua;' .. package.path
  end
end

local args = require 'nvim-bundle.vendor.args'
local build = require 'nvim-bundle.build'
local deps = require 'nvim-bundle.deps'
local version = require 'nvim-bundle.version'

local M = { build = build.build }

local USAGE = [[
Usage: nvim-bundle <command> [options]

Commands:
  build [<entry>]    Bundle a source tree into one Lua file
  install [<spec>]   Vendor a dependency, or sync lua/<name>/vendor/
  remove <alias>     Delete a vendored dependency
  update [<alias>]   Move dependencies to newer tags or branch heads
  outdated           List dependencies that update would move

Options:
  -C <dir>           Run as if started in <dir>
  -h, --help         Show this help
  -V, --version      Print the nvim-bundle and Neovim versions

Run `nvim-bundle <command> --help` for a command's options.
]]

--- @param msg string
--- @return never
local function die(msg) error('nvim-bundle: ' .. msg, 0) end

--- @param lines string[]
--- @return string
local function report(lines)
  if #lines == 0 then return 'dependencies are up to date' end
  return table.concat(lines, '\n')
end

--- Each command owns its options, its usage text, and a `run` that turns the
--- parsed options into stdout lines, so `main` owns every process-level concern.
--- Every command also accepts `-h`/`--help`, added when the spec is built.
--- @class NvimBundle.Command
--- @field options table<string, any> an args.nvim spec for this command
--- @field usage string
--- @field run fun(parsed: table): string

--- @type table<string, NvimBundle.Command>
local COMMANDS = {
  build = {
    options = {
      ['--root'] = 'string',
      ['--out'] = 'string',
      ['--exclude'] = { 'string' },
      ['--bin'] = 'boolean',
    },
    usage = [[
Usage: nvim-bundle build [<entry>] [options]

The bundle returns the module <entry>, like `require '<entry>'` would. With
no <entry>, it returns a registry of lazy loaders, one per module.

Options:
  --root <dir>       Source root to scan (default: lua)
  --out <file>       Output bundle (default: dist/<entry>.lua, or
                     dist/<package>.lua for a registry)
  --exclude <glob>   Skip paths matching <glob> (repeatable)
  --bin              Make an executable (needs <entry>)
  -h, --help         Show this help

Examples:
  nvim-bundle build myplugin
  nvim-bundle build myplugin --exclude '**/_test/**'
]],
    run = function(parsed)
      local entry = parsed._[1]
      if parsed._[2] then die('unexpected argument ' .. parsed._[2]) end
      local result = build.build {
        entry = entry,
        root = parsed['--root'],
        out = parsed['--out'],
        exclude = parsed['--exclude'],
        bin = parsed['--bin'],
      }
      local shape = result.entry and ('returns ' .. result.entry) or 'registry'
      return ('bundled %d modules into %s (%s)'):format(result.modules, result.out, shape)
    end,
  },

  install = {
    options = {
      ['--root'] = 'string',
      ['--exclude'] = { 'string' },
      ['--as'] = 'string',
      ['--force'] = 'boolean',
      ['--frozen'] = 'boolean',
    },
    -- `[=[` because the usage line itself contains `]]`.
    usage = [=[
Usage: nvim-bundle install [<spec> [<entry>]] [options]

With no <spec>, install makes lua/<name>/vendor/ match nvim-bundle.json,
reusing nvim-bundle.lock.json wherever it still applies.

A <spec> is a git repository with an optional ref, built from source:
  owner/repo[@<ref>]              Shorthand for https://github.com/owner/repo
  <git url>[@<ref>]               Any URL or path that git can clone
A <ref> is a tag, a branch, or a full commit SHA; a tag wins over a branch of
the same name. Without one, the newest stable tag is used.

The repository is built as `nvim-bundle build [<entry>]` would build it, so
<entry>, --root, and --exclude mean what they mean there, and
nvim-bundle.json records them.

Options:
  --root <dir>       Source root in the repository (default: lua)
  --exclude <glob>   Skip paths matching <glob> (repeatable)
  --as <alias>       Vendor as lua/<name>/vendor/<alias>.lua (default: the
                     package of <entry>, or the repository's one package)
  --force            Overwrite a vendored file that install did not create
  --frozen           With no <spec>, fail instead of changing any file
  -h, --help         Show this help

Examples:
  nvim-bundle install jrop/args.nvim@v0.1.0 args
  nvim-bundle install https://codeberg.org/me/dep.nvim@main
  nvim-bundle install --frozen
]=],
    run = function(parsed)
      local spec = parsed._[1]
      if not spec then return report(deps.sync { frozen = parsed['--frozen'] }) end
      if parsed._[3] then die('unexpected argument ' .. parsed._[3]) end
      local alias, path = deps.install(spec, {
        entry = parsed._[2],
        root = parsed['--root'],
        exclude = parsed['--exclude'],
        as = parsed['--as'],
        force = parsed['--force'],
      })
      return ('installed %s into %s'):format(alias, path)
    end,
  },

  remove = {
    options = {},
    usage = [[
Usage: nvim-bundle remove <alias>

Deletes lua/<name>/vendor/<alias>.lua and its manifest and lock entries.

Options:
  -h, --help         Show this help
]],
    run = function(parsed)
      local alias = parsed._[1]
      if not alias then die 'missing alias (for example: nvim-bundle remove args)' end
      if parsed._[2] then die('unexpected argument ' .. parsed._[2]) end
      deps.remove(alias)
      return 'removed ' .. alias
    end,
  },

  update = {
    options = {},
    usage = [[
Usage: nvim-bundle update [<alias>]

Moves every tagged dependency, or only <alias>, to its newest stable tag, and
each branch to its head. Tags are rewritten in nvim-bundle.json; a rev stays.

Options:
  -h, --help         Show this help
]],
    run = function(parsed)
      if parsed._[2] then die('unexpected argument ' .. parsed._[2]) end
      return report(deps.update(parsed._[1]))
    end,
  },

  outdated = {
    options = {},
    usage = [[
Usage: nvim-bundle outdated

Lists each dependency that `update` would move, and each pinned rev. Nothing
is changed.

Options:
  -h, --help         Show this help
]],
    run = function(parsed)
      if parsed._[1] then die('unexpected argument ' .. parsed._[1]) end
      return report(deps.outdated())
    end,
  },
}

--- @type table<string, any>
local ARGS_SPEC = {
  ['--help'] = 'boolean',
  ['-h'] = '--help',
  ['--version'] = 'boolean',
  ['-V'] = '--version',
  ['-C'] = 'string',
}
for name, command in pairs(COMMANDS) do
  ARGS_SPEC[name] =
    vim.tbl_extend('error', command.options, { ['--help'] = 'boolean', ['-h'] = '--help' })
end

local function exit_error(err)
  io.stderr:write(tostring(err) .. '\n')
  os.exit(1)
end

-- Process boundary: parse argv, run one command, and turn its result into
-- stdout, stderr, and an exit status. `build` is the only public function.
local function main(argv)
  local parse_ok, parsed = pcall(args.parse, ARGS_SPEC, argv)
  if not parse_ok then exit_error('nvim-bundle: ' .. tostring(parsed)) end
  --- @cast parsed table

  if parsed['--version'] then
    -- The type stubs model `vim.version` as a table, but Neovim exposes it as
    -- a callable table.
    --- @diagnostic disable-next-line: call-non-callable
    local v = vim.version()
    local neovim = ('%d.%d.%d'):format(v.major, v.minor, v.patch)
    if v.prerelease then neovim = neovim .. '-' .. v.prerelease end
    io.stdout:write(('nvim-bundle %s (Neovim %s)\n'):format(version, neovim))
    return
  end
  local dir = parsed['-C']
  if dir then
    local ok, err = vim.uv.chdir(dir)
    if not ok then exit_error(('nvim-bundle: cannot change to %s: %s'):format(dir, err)) end
  end

  local command, opts
  for name in pairs(COMMANDS) do
    if parsed[name] then
      command, opts = name, parsed[name]
    end
  end
  if not command then
    if parsed['--help'] then
      io.stdout:write(USAGE)
      return
    end
    exit_error 'nvim-bundle: missing command (for example: nvim-bundle build myplugin)'
  end
  --- @cast command string
  --- @cast opts table

  if opts['--help'] then
    io.stdout:write(COMMANDS[command].usage)
    return
  end

  local ok, message = pcall(COMMANDS[command].run, opts)
  if not ok then exit_error(message) end
  io.stdout:write(message .. '\n')
end

if running_as_main then main(arg) end

return M
