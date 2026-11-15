--- Dependency vendoring: every dependency is a git repository built from
--- source into one bundle under `lua/<name>/vendor/`, and the manifest and
--- lock record what was asked for and what it resolved to.
local build = require 'nvim-bundle.build'
local dto = require 'nvim-bundle.dto'
local files = require 'nvim-bundle.files'
local git = require 'nvim-bundle.git'
local version = require 'nvim-bundle.version'

local M = {}

local MANIFEST = 'nvim-bundle.json'
local LOCK = 'nvim-bundle.lock.json'
local LOCK_VERSION = 1

-- A diagnostic inside a vendored file cannot be fixed in the consuming
-- project: the file is generated, and `install` would overwrite an edit. So
-- every vendored file silences its own diagnostics. Code that calls into it is
-- still checked against its types, which the comment does not hide.
local VENDORED_HEADER = '---@diagnostic disable\n'

--- @param msg string
--- @return never
local function die(msg) error('nvim-bundle: ' .. msg, 0) end

--- One manifest entry, with the string form split into its repo and ref.
--- @class nvim-bundle.deps.Dependency: nvim-bundle.dto.BuildSettings
--- @field repo string as written: a git URL or `owner/repo`
--- @field url string what git clones
--- @field ref? string a tag, branch, or commit; nil until the newest tag is chosen
--- @field kind? nvim-bundle.dto.RefKind what `ref` names, once resolved
--- @field dev? boolean listed under `dev_dependencies`

--- A dependency whose ref and kind are known, which is what building and
--- comparing need.
--- @class nvim-bundle.deps.Resolved: nvim-bundle.deps.Dependency
--- @field ref string
--- @field kind nvim-bundle.dto.RefKind

--- `owner/repo` is shorthand for its GitHub URL; anything else is a location
--- git understands, so it is cloned as written.
--- @param repo string
--- @return string
local function clone_url(repo)
  if repo:match '^[%w_.-]+/[%w_.-]+$' then return 'https://github.com/' .. repo end
  return repo
end

--- @param entry nvim-bundle.dto.ManifestDependency
--- @return nvim-bundle.deps.Dependency
local function parse(entry)
  if type(entry) == 'string' then
    -- The ref is an `@` in the last path segment only, because an earlier `@`
    -- belongs to the location (for example `git@host:me/dep.nvim`).
    local segment = entry:match '[^/]*$' or ''
    local name, ref = segment:match '^(.-)@([^@]+)$'
    local repo = name and entry:sub(1, #entry - #segment) .. name or entry
    return { repo = repo, url = clone_url(repo), ref = ref }
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

--- Both manifest sections as one table, because every command treats a dev
--- dependency like any other; only a build of the project tells them apart.
--- @param manifest nvim-bundle.dto.Manifest
--- @return table<string, nvim-bundle.deps.Dependency>
local function dependencies(manifest)
  local deps = {}
  for alias, entry in pairs(manifest.dependencies) do
    deps[alias] = parse(entry)
  end
  for alias, entry in pairs(manifest.dev_dependencies) do
    deps[alias] = parse(entry)
    deps[alias].dev = true
  end
  return deps
end

--- Record `entry` in the section `dev` names. An alias lives in exactly one
--- section, so this also clears it from the other, and a nil entry clears both.
--- @param manifest nvim-bundle.dto.Manifest
--- @param alias string
--- @param entry nvim-bundle.dto.ManifestDependency?
--- @param dev boolean?
local function record(manifest, alias, entry, dev)
  manifest.dependencies[alias] = not dev and entry or nil
  manifest.dev_dependencies[alias] = dev and entry or nil
end

--- @param dep nvim-bundle.deps.Dependency | nvim-bundle.dto.LockEntry
--- @return nvim-bundle.dto.BuildSettings
local function settings(dep) return { entry = dep.entry, root = dep.root, exclude = dep.exclude } end

--- @param dep nvim-bundle.deps.Dependency
--- @return nvim-bundle.dto.ManifestDependency
local function manifest_entry(dep)
  if not next(settings(dep)) then return dep.repo .. (dep.ref and '@' .. dep.ref or '') end
  return {
    repo = dep.repo,
    ref = dep.ref,
    entry = dep.entry,
    root = dep.root,
    exclude = dep.exclude,
  }
end

--- A lock entry still describes a dependency when it records the same source,
--- ref, and build settings. A dependency with no ref pins nothing yet, so it never
--- matches.
--- @param dep nvim-bundle.deps.Dependency
--- @param entry nvim-bundle.dto.LockEntry
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
--- @param dep nvim-bundle.deps.Dependency
--- @param entry nvim-bundle.dto.LockEntry? the lock entry
--- @return nvim-bundle.deps.Resolved
local function resolve(dep, entry)
  if dep.kind then
    return dep --[[@as nvim-bundle.deps.Resolved]]
  end
  if entry and locked(dep, entry) then
    dep.kind = entry.kind
  elseif dep.ref then
    dep.kind = git.ref_kind(dep.url, dep.ref)
  else
    dep.ref, dep.kind = git.latest_tag(dep.url), 'tag'
  end
  return dep --[[@as nvim-bundle.deps.Resolved]]
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

--- A project's files are in `dir`, or in the cwd when `dir` is nil, so that
--- messages about the cwd's project name its files as the user sees them.
--- @param dir string?
--- @param file string
--- @return string
local function in_project(dir, file) return dir and dir .. '/' .. file or file end

--- A missing manifest is valid: `install` creates one. The absent value still
--- goes through the schema, so its defaults come from one place.
--- @param dir string?
--- @return nvim-bundle.dto.Manifest
local function read_manifest(dir)
  local path = in_project(dir, MANIFEST)
  return dto.check(dto.Manifest, files.read_json(path) or {}, path) --[[@as nvim-bundle.dto.Manifest]]
end

--- The project's module root is `lua/<name>/`: the manifest's `name`, else the
--- one package under `lua/`.
--- @param manifest nvim-bundle.dto.Manifest
--- @param dir string?
--- @return string
local function module_name(manifest, dir)
  local hint = ('add "name" to %s'):format(in_project(dir, MANIFEST))
  return manifest.name or build.package_name(in_project(dir, 'lua'), hint)
end

--- @class nvim-bundle.deps.Project
--- @field name? string inferred on first use, so commands that fail early never need it
--- @field manifest nvim-bundle.dto.Manifest
--- @field lock nvim-bundle.dto.Lock

--- A project with neither file is valid: `install` creates both.
--- @return nvim-bundle.deps.Project
local function load_project()
  local manifest = read_manifest()
  local lock = dto.check(dto.Lock, files.read_json(LOCK) or { lock_version = LOCK_VERSION }, LOCK) --[[@as nvim-bundle.dto.Lock]]
  return { name = manifest.name, manifest = manifest, lock = lock }
end

--- @param project nvim-bundle.deps.Project
--- @return string
local function project_name(project)
  project.name = project.name or module_name(project.manifest)
  return project.name
end

--- @param project nvim-bundle.deps.Project
local function save_project(project)
  project.manifest.name = project_name(project)
  project.lock.lock_version = LOCK_VERSION
  -- Most projects have no dev dependencies, so their manifest keeps no empty
  -- section for them.
  local manifest = vim.deepcopy(project.manifest)
  if not next(manifest.dev_dependencies) then manifest.dev_dependencies = nil end
  files.write_json(MANIFEST, manifest)
  files.write_json(LOCK, project.lock)
end

--- Where a project with module root `name` vendors `alias`, relative to the
--- project directory.
--- @param name string
--- @param alias string
--- @return string
local function vendored_path(name, alias) return ('lua/%s/vendor/%s.lua'):format(name, alias) end

--- A project vendors its dev dependencies only for developing it, so no build
--- of the project includes them. This returns them as excludes for a build of
--- the project in `dir` (the cwd when nil) from `root`. An exclude is matched
--- against the path below the root, and a file outside the root is never
--- bundled, so only the dev dependencies under `root` need one.
--- @param root string the build's source root
--- @param dir string? the project directory, which holds its manifest
--- @return string[]
function M.dev_excludes(root, dir)
  local manifest = read_manifest(dir)
  local aliases = sorted_keys(manifest.dev_dependencies)
  -- Returning before the name is inferred keeps a project without dev
  -- dependencies buildable when its name is ambiguous.
  if #aliases == 0 then return {} end

  local name = module_name(manifest, dir)
  local below = vim.fn.fnamemodify(root, ':p')
  local excludes = {}
  for _, alias in ipairs(aliases) do
    local file = vim.fn.fnamemodify(in_project(dir, vendored_path(name, alias)), ':p')
    if vim.startswith(file, below) then excludes[#excludes + 1] = file:sub(#below + 1) end
  end
  return excludes
end

--- Check out `ref` and build it exactly as `nvim-bundle build` would in that
--- checkout, with the consumer's settings as its arguments. Of the
--- dependency's own `nvim-bundle.json`, only its dev dependencies are read,
--- so any Lua repository can be vendored. Returns the vendored file's
--- content, the alias (`alias`, else the entry's package, else the root's one
--- package), and the commit that was built.
--- @param dep nvim-bundle.deps.Dependency
--- @param kind nvim-bundle.dto.RefKind
--- @param ref string
--- @param alias string?
--- @return string content, string alias, string commit
local function build_from_source(dep, kind, ref, alias)
  local checkout = vim.fn.tempname()
  local out = checkout .. '.bundle.lua'
  -- The checkout and output are removed whether or not the build succeeds.
  local ok, built = pcall(function()
    local commit = git.checkout(dep.url, kind, ref, checkout)
    local root = checkout .. '/' .. (dep.root or build.DEFAULT_ROOT)
    local exclude = vim.list_extend(M.dev_excludes(root, checkout), dep.exclude or {})
    build.build { entry = dep.entry, root = root, exclude = exclude, out = out }
    local name = alias
      or dep.entry and dep.entry:match '^[^.]+'
      or build.package_name(root, 'pass an entry or --as')
    -- build either wrote `out` or raised, so the file is there to read.
    local bundle = files.read(out) --[[@as string]]
    return { content = VENDORED_HEADER .. bundle, alias = name, commit = commit }
  end)
  vim.fn.delete(checkout, 'rf')
  vim.fn.delete(out)
  if not ok then error(built, 0) end
  return built.content, built.alias, built.commit
end

--- Resolve and build `dep`, and record the result in both files. A file the
--- lock does not know was not vendored by install, so it is only replaced
--- under `force`.
--- @param project nvim-bundle.deps.Project
--- @param dep nvim-bundle.deps.Dependency
--- @param alias string? overrides the package name as the file name
--- @param force boolean?
--- @return string alias, string path
local function add(project, dep, alias, force)
  local resolved = resolve(dep, alias and project.lock.dependencies[alias])
  local content, commit
  content, alias, commit = build_from_source(dep, resolved.kind, resolved.ref, alias)

  local path = vendored_path(project_name(project), alias)
  if not force and not project.lock.dependencies[alias] and files.read(path) then
    die(('%s exists but is not in the lock; move it, pass --as, or pass --force'):format(path))
  end
  files.write(path, content)

  record(project.manifest, alias, manifest_entry(dep), dep.dev)
  project.lock.dependencies[alias] = {
    source = dep.url,
    ref = resolved.ref,
    kind = resolved.kind,
    commit = commit,
    built_with = version,
    sha256 = vim.fn.sha256(content),
    entry = dep.entry,
    root = dep.root,
    exclude = dep.exclude,
  }
  return alias, path
end

--- Rebuild the locked commit, not the ref, so a moved tag or an advanced
--- branch cannot change what is restored. The bytes only match under the
--- nvim-bundle version that built them, so a mismatch names both versions.
--- @param dep nvim-bundle.deps.Dependency
--- @param alias string
--- @param entry nvim-bundle.dto.LockEntry
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

--- @class nvim-bundle.deps.InstallOptions: nvim-bundle.dto.BuildSettings
--- @field as? string overrides the package name as the file name
--- @field force? boolean overwrite a file that install did not create
--- @field dev? boolean record it under `dev_dependencies`

--- @param spec string `repo[@ref]`
--- @param opts nvim-bundle.deps.InstallOptions
--- @return string alias, string path
function M.install(spec, opts)
  local project = load_project()
  local dep = parse(spec)
  dep.entry, dep.root, dep.exclude, dep.dev = opts.entry, opts.root, opts.exclude, opts.dev
  local alias, path = add(project, dep, opts.as, opts.force)
  save_project(project)
  return alias, path
end

--- @param alias string
function M.remove(alias)
  local project = load_project()
  if not dependencies(project.manifest)[alias] then die(alias .. ' is not a dependency') end
  os.remove(vendored_path(project_name(project), alias))
  record(project.manifest, alias, nil)
  project.lock.dependencies[alias] = nil
  save_project(project)
end

--- @param commit string?
--- @return string
local function short(commit) return commit and commit:sub(1, 7) or '(unlocked)' end

--- Where `update` would move a resolved dependency, or nil when it is current
--- or a rev. A tag moves to the newest stable tag, and a branch to its remote
--- head, compared with the locked commit.
--- @param dep nvim-bundle.deps.Resolved
--- @param entry nvim-bundle.dto.LockEntry? the lock entry
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
  local deps = dependencies(project.manifest)
  if alias and not deps[alias] then die(alias .. ' is not a dependency') end

  local changes = {}
  for _, name in ipairs(alias and { alias } or sorted_keys(deps)) do
    local entry = project.lock.dependencies[name]
    local dep = resolve(deps[name], entry)
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
  local deps = dependencies(project.manifest)
  local lines = {}
  for _, alias in ipairs(sorted_keys(deps)) do
    local entry = project.lock.dependencies[alias]
    local dep = resolve(deps[alias], entry)
    local move = newer(dep, entry)
    if dep.kind == 'rev' then
      lines[#lines + 1] = ('%s is pinned to %s'):format(alias, short(dep.ref))
    elseif move then
      lines[#lines + 1] = ('%s %s -> %s'):format(alias, move.from, move.to)
    end
  end
  return lines
end

--- @alias nvim-bundle.deps.SyncAction 'resolve' | 'restore' | 'remove'

--- Decide what each dependency needs before touching anything, so a frozen
--- run can report the whole plan and leave every file as it was.
--- @param project nvim-bundle.deps.Project
--- @param deps table<string, nvim-bundle.deps.Dependency> both manifest sections
--- @return { action: nvim-bundle.deps.SyncAction, alias: string }[]
local function plan_sync(project, deps)
  local plan = {}
  for _, alias in ipairs(sorted_keys(deps)) do
    local entry = project.lock.dependencies[alias]
    local current = files.read(vendored_path(project_name(project), alias))
    if not entry or not locked(deps[alias], entry) then
      plan[#plan + 1] = { action = 'resolve', alias = alias }
    elseif not current or vim.fn.sha256(current) ~= entry.sha256 then
      plan[#plan + 1] = { action = 'restore', alias = alias }
    end
  end

  -- Only files the lock knows were vendored by install, so a hand-written
  -- module that happens to live in `vendor/` is never deleted.
  for _, alias in ipairs(sorted_keys(project.lock.dependencies)) do
    if not deps[alias] then plan[#plan + 1] = { action = 'remove', alias = alias } end
  end
  return plan
end

--- @class nvim-bundle.deps.SyncOptions
--- @field frozen? boolean fail instead of changing anything

--- Make `vendor/` match the manifest, using the lock wherever it still
--- applies. Returns one line per dependency that changed.
--- @param opts nvim-bundle.deps.SyncOptions?
--- @return string[]
function M.sync(opts)
  local project = load_project()
  local deps = dependencies(project.manifest)
  local plan = plan_sync(project, deps)
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
    local path = vendored_path(project_name(project), alias)
    if step.action == 'remove' then
      os.remove(path)
      project.lock.dependencies[alias] = nil
    else
      local dep = deps[alias]
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
