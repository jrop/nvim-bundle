--- Dependency vendoring: every dependency is a git repository built from
--- source into one bundle under `lua/<name>/vendor/`, and the manifest and
--- lock record what was asked for and what it resolved to.
local build = require 'nvim-bundle.build'
local files = require 'nvim-bundle.files'
local git = require 'nvim-bundle.git'
local version = require 'nvim-bundle.version'

local M = {}

local MANIFEST = 'nvim-bundle.json'
local LOCK = 'nvim-bundle.lock.json'
local LOCK_VERSION = 1

--- @param msg string
--- @return never
local function die(msg) error('nvim-bundle: ' .. msg, 0) end

--- What `build` is given for a dependency, named as its CLI arguments are.
--- @class NvimBundle.BuildSettings
--- @field entry? string the module the bundle returns; nil means a registry
--- @field root? string
--- @field exclude? string[]

--- One manifest entry: a string `repo[@ref]`, or an object
--- `{ repo, ref, entry, root, exclude }` when it has build settings.
--- @class NvimBundle.Dependency: NvimBundle.BuildSettings
--- @field repo string as written: a git URL or `owner/repo`
--- @field url string what git clones
--- @field ref? string a tag, branch, or commit; nil until the newest tag is chosen
--- @field kind? NvimBundle.RefKind what `ref` names, once resolved

--- A dependency whose ref and kind are known, which is what building and
--- comparing need.
--- @class NvimBundle.Resolved: NvimBundle.Dependency
--- @field ref string
--- @field kind NvimBundle.RefKind

local SETTINGS = { 'entry', 'root', 'exclude' }

--- `owner/repo` is shorthand for its GitHub URL; anything else is a location
--- git understands, so it is cloned as written.
--- @param repo string
--- @return string
local function clone_url(repo)
  if repo:match '^[%w_.-]+/[%w_.-]+$' then return 'https://github.com/' .. repo end
  return repo
end

--- @param entry string | table a manifest value
--- @param alias string names the entry in an error
--- @return NvimBundle.Dependency
local function parse(entry, alias)
  if type(entry) == 'string' then
    -- The ref is an `@` in the last path segment only, because an earlier `@`
    -- belongs to the location (for example `git@host:me/dep.nvim`).
    local segment = entry:match '[^/]*$' or ''
    local name, ref = segment:match '^(.-)@([^@]+)$'
    local repo = name and entry:sub(1, #entry - #segment) .. name or entry
    return { repo = repo, url = clone_url(repo), ref = ref }
  end

  if type(entry) ~= 'table' or type(entry.repo) ~= 'string' then
    die(('dependency %s needs a repo'):format(alias))
  end
  for key in pairs(entry) do
    if not vim.list_contains(SETTINGS, key) and key ~= 'repo' and key ~= 'ref' then
      die(('dependency %s has an unknown field %s'):format(alias, key))
    end
  end
  return {
    repo = entry.repo,
    url = clone_url(entry.repo),
    ref = entry.ref,
    entry = entry.entry,
    root = entry.root,
    exclude = entry.exclude,
  }
end

--- @param dep NvimBundle.Dependency
--- @return NvimBundle.BuildSettings
local function settings(dep) return { entry = dep.entry, root = dep.root, exclude = dep.exclude } end

--- @param dep NvimBundle.Dependency
--- @return string | table
local function manifest_entry(dep)
  local fields = settings(dep)
  if next(fields) then
    return vim.tbl_extend('error', fields, { repo = dep.repo, ref = dep.ref })
  end
  return dep.repo .. (dep.ref and '@' .. dep.ref or '')
end

--- A lock entry still describes a dependency when it records the same source,
--- ref, and build settings. A dependency with no ref pins nothing yet, so it never
--- matches.
--- @param dep NvimBundle.Dependency
--- @param entry table
--- @return boolean
local function locked(dep, entry)
  return dep.ref ~= nil
    and entry.source == dep.url
    and entry.ref == dep.ref
    and vim.deep_equal(settings(entry), settings(dep))
end

--- Fill in what `dep.ref` names. A locked dependency takes its kind from the
--- lock, so only a new or changed ref asks the remote, and a dependency with
--- no ref gets the newest stable tag.
--- @param dep NvimBundle.Dependency
--- @param entry table? the lock entry
--- @return NvimBundle.Resolved
local function resolve(dep, entry)
  if dep.kind then
    return dep --[[@as NvimBundle.Resolved]]
  end
  if entry and locked(dep, entry) then
    dep.kind = entry.kind
  elseif dep.ref then
    dep.kind = git.ref_kind(dep.url, dep.ref)
  else
    dep.ref, dep.kind = git.latest_tag(dep.url), 'tag'
  end
  return dep --[[@as NvimBundle.Resolved]]
end

--- Commands walk dependencies in sorted order, so their output and the order
--- of their writes never depend on table iteration.
--- @param t table<string, any>
--- @return string[]
local function sorted_keys(t)
  local keys = vim.tbl_keys(t)
  table.sort(keys)
  return keys
end

--- Check out `ref` and build it exactly as `nvim-bundle build` would in that
--- checkout, with the consumer's settings as its arguments. The dependency's
--- own `nvim-bundle.json` is never read, so any Lua repository can be
--- vendored. Returns the bundle, the alias (`alias`, else the entry's package,
--- else the root's one package), and the commit that was built.
--- @param dep NvimBundle.Dependency
--- @param kind NvimBundle.RefKind
--- @param ref string
--- @param alias string?
--- @return string content, string alias, string commit
local function build_from_source(dep, kind, ref, alias)
  local checkout = vim.fn.tempname()
  local out = checkout .. '.bundle.lua'
  -- The checkout and output are removed whether or not the build succeeds.
  local ok, built = pcall(function()
    local commit = git.checkout(dep.url, kind, ref, checkout)
    local root = checkout .. '/' .. (dep.root or 'lua')
    build.build { entry = dep.entry, root = root, exclude = dep.exclude, out = out }
    local name = alias
      or dep.entry and dep.entry:match '^[^.]+'
      or build.package_name(root, 'pass an entry or --as')
    -- build either wrote `out` or raised, so the file is there to read.
    local content = files.read(out) --[[@as string]]
    return { content = content, alias = name, commit = commit }
  end)
  vim.fn.delete(checkout, 'rf')
  vim.fn.delete(out)
  if not ok then error(built, 0) end
  return built.content, built.alias, built.commit
end

--- @class NvimBundle.Project
--- @field name? string inferred on first use, so commands that fail early never need it
--- @field manifest table
--- @field lock table

--- @return NvimBundle.Project
local function load_project()
  local config = files.read_json(MANIFEST) or {}
  local lock = files.read_json(LOCK) or {}
  config.dependencies = config.dependencies or {}
  lock.dependencies = lock.dependencies or {}
  return { name = config.name, manifest = config, lock = lock }
end

--- @param project NvimBundle.Project
--- @return string
local function project_name(project)
  project.name = project.name or build.package_name('lua', ('add "name" to %s'):format(MANIFEST))
  return project.name
end

--- @param project NvimBundle.Project
local function save_project(project)
  project.manifest.name = project_name(project)
  project.lock.lock_version = LOCK_VERSION
  files.write_json(MANIFEST, project.manifest)
  files.write_json(LOCK, project.lock)
end

--- @param project NvimBundle.Project
--- @param alias string
--- @return string
local function vendored_path(project, alias)
  return ('lua/%s/vendor/%s.lua'):format(project_name(project), alias)
end

--- Resolve and build `dep`, and record the result in both files. A file the
--- lock does not know was not vendored by install, so it is only replaced
--- under `force`.
--- @param project NvimBundle.Project
--- @param dep NvimBundle.Dependency
--- @param alias string? overrides the package name as the file name
--- @param force boolean?
--- @return string alias, string path
local function add(project, dep, alias, force)
  local resolved = resolve(dep, alias and project.lock.dependencies[alias])
  local content, commit
  content, alias, commit = build_from_source(dep, resolved.kind, resolved.ref, alias)

  local path = vendored_path(project, alias)
  if not force and not project.lock.dependencies[alias] and files.read(path) then
    die(('%s exists but is not in the lock; move it, pass --as, or pass --force'):format(path))
  end
  files.write(path, content)

  project.manifest.dependencies[alias] = manifest_entry(dep)
  project.lock.dependencies[alias] = vim.tbl_extend('error', settings(dep), {
    source = dep.url,
    ref = dep.ref,
    kind = dep.kind,
    commit = commit,
    built_with = version,
    sha256 = vim.fn.sha256(content),
  })
  return alias, path
end

--- Rebuild the locked commit, not the ref, so a moved tag or an advanced
--- branch cannot change what is restored. The bytes only match under the
--- nvim-bundle version that built them, so a mismatch names both versions.
--- @param dep NvimBundle.Dependency
--- @param alias string
--- @param entry table
--- @param path string
local function restore(dep, alias, entry, path)
  local content = build_from_source(dep, 'rev', entry.commit, alias)
  if vim.fn.sha256(content) ~= entry.sha256 then
    local why = ''
    if entry.built_with ~= version then
      why = (' (locked with nvim-bundle %s, rebuilt with %s)'):format(entry.built_with, version)
    end
    die(('%s at %s no longer matches its locked sha256%s'):format(dep.repo, entry.commit, why))
  end
  files.write(path, content)
end

--- @class NvimBundle.InstallOptions: NvimBundle.BuildSettings
--- @field as? string overrides the package name as the file name
--- @field force? boolean overwrite a file that install did not create

--- @param spec string `repo[@ref]`
--- @param opts NvimBundle.InstallOptions
--- @return string alias, string path
function M.install(spec, opts)
  local project = load_project()
  local dep = parse(spec, spec)
  dep.entry, dep.root, dep.exclude = opts.entry, opts.root, opts.exclude
  local alias, path = add(project, dep, opts.as, opts.force)
  save_project(project)
  return alias, path
end

--- @param alias string
function M.remove(alias)
  local project = load_project()
  if not project.manifest.dependencies[alias] then die(alias .. ' is not a dependency') end
  os.remove(vendored_path(project, alias))
  project.manifest.dependencies[alias] = nil
  project.lock.dependencies[alias] = nil
  save_project(project)
end

--- @param commit string?
--- @return string
local function short(commit) return commit and commit:sub(1, 7) or '(unlocked)' end

--- Where `update` would move a resolved dependency, or nil when it is current
--- or a rev. A tag moves to the newest stable tag, and a branch to its remote
--- head, compared with the locked commit.
--- @param dep NvimBundle.Resolved
--- @param entry table? the lock entry
--- @return { from: string, to: string, ref: string }?
local function newer(dep, entry)
  if dep.kind == 'rev' then return nil end
  if dep.kind == 'branch' then
    local head = git.branch_head(dep.url, dep.ref)
    local commit = entry and entry.commit
    if head == commit then return nil end
    return { from = short(commit), to = short(head), ref = dep.ref }
  end
  local newest = git.latest_tag(dep.url)
  if newest == dep.ref then return nil end
  return { from = dep.ref, to = newest, ref = newest }
end

--- Move each dependency, or only `alias`, where `newer` says. Returns one line
--- per change.
--- @param alias string?
--- @return string[]
function M.update(alias)
  local project = load_project()
  local deps = project.manifest.dependencies
  if alias and not deps[alias] then die(alias .. ' is not a dependency') end

  local changes = {}
  for _, name in ipairs(alias and { alias } or sorted_keys(deps)) do
    local entry = project.lock.dependencies[name]
    local dep = resolve(parse(deps[name], name), entry)
    local move = newer(dep, entry)
    if move then
      dep.ref = move.ref
      add(project, dep, name)
      changes[#changes + 1] = ('updated %s %s -> %s'):format(name, move.from, move.to)
    end
  end

  save_project(project)
  return changes
end

--- Report each dependency that `update` would move, and each rev, without
--- changing any file.
--- @return string[]
function M.outdated()
  local project = load_project()
  local deps = project.manifest.dependencies
  local lines = {}
  for _, alias in ipairs(sorted_keys(deps)) do
    local entry = project.lock.dependencies[alias]
    local dep = resolve(parse(deps[alias], alias), entry)
    local move = newer(dep, entry)
    if dep.kind == 'rev' then
      lines[#lines + 1] = ('%s is pinned to %s'):format(alias, short(dep.ref))
    elseif move then
      lines[#lines + 1] = ('%s %s -> %s'):format(alias, move.from, move.to)
    end
  end
  return lines
end

--- @alias NvimBundle.SyncAction 'resolve' | 'restore' | 'remove'

--- Decide what each dependency needs before touching anything, so a frozen
--- run can report the whole plan and leave every file as it was.
--- @param project NvimBundle.Project
--- @return { action: NvimBundle.SyncAction, alias: string }[]
local function plan_sync(project)
  local plan = {}
  for _, alias in ipairs(sorted_keys(project.manifest.dependencies)) do
    local entry = project.lock.dependencies[alias]
    local current = files.read(vendored_path(project, alias))
    if not entry or not locked(parse(project.manifest.dependencies[alias], alias), entry) then
      plan[#plan + 1] = { action = 'resolve', alias = alias }
    elseif not current or vim.fn.sha256(current) ~= entry.sha256 then
      plan[#plan + 1] = { action = 'restore', alias = alias }
    end
  end

  -- Only files the lock knows were vendored by install, so a hand-written
  -- module that happens to live in `vendor/` is never deleted.
  for _, alias in ipairs(sorted_keys(project.lock.dependencies)) do
    if not project.manifest.dependencies[alias] then
      plan[#plan + 1] = { action = 'remove', alias = alias }
    end
  end
  return plan
end

--- @class NvimBundle.SyncOptions
--- @field frozen? boolean fail instead of changing anything

--- Make `vendor/` match the manifest, using the lock wherever it still
--- applies. Returns one line per dependency that changed.
--- @param opts NvimBundle.SyncOptions?
--- @return string[]
function M.sync(opts)
  local project = load_project()
  local plan = plan_sync(project)
  if opts and opts.frozen and #plan > 0 then
    local would = vim.tbl_map(
      function(step) return ('would %s %s'):format(step.action, step.alias) end,
      plan
    )
    die('install --frozen: ' .. table.concat(would, ', '))
  end

  local done = { resolve = 'resolved', restore = 'restored', remove = 'removed' }
  local changes = {}
  for _, step in ipairs(plan) do
    local alias = step.alias
    local path = vendored_path(project, alias)
    if step.action == 'remove' then
      os.remove(path)
      project.lock.dependencies[alias] = nil
    else
      local dep = parse(project.manifest.dependencies[alias], alias)
      if step.action == 'resolve' then
        add(project, dep, alias)
      else
        restore(dep, alias, project.lock.dependencies[alias], path)
      end
    end
    changes[#changes + 1] = done[step.action] .. ' ' .. alias
  end

  save_project(project)
  return changes
end

return M
