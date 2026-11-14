--- Every dependency operation is a git command, so any host that git can reach
--- works the same way, with the user's own credentials and no API token.
local M = {}

--- @param msg string
--- @return never
local function die(msg) error('nvim-bundle: ' .. msg, 0) end

--- @param argv string[]
--- @param what string names the operation in an error
--- @return string stdout
local function run(argv, what)
  local proc = vim.system(vim.list_extend({ 'git' }, argv)):wait()
  if proc.code ~= 0 then die(('%s: %s'):format(what, vim.trim(proc.stderr or ''))) end
  return proc.stdout or ''
end

--- The newest tag that parses as a stable version. Tags compare as versions,
--- so `v0.10.0` beats `v0.2.0`, and pre-releases are skipped unless named.
--- @param url string
--- @return string
function M.latest_tag(url)
  local stdout = run({ 'ls-remote', '--tags', '--refs', url }, 'cannot list tags of ' .. url)
  local best, best_version
  for tag in stdout:gmatch 'refs/tags/(%S+)' do
    local version = vim.version.parse(tag)
    if version and not version.prerelease and (not best_version or version > best_version) then
      best, best_version = tag, version
    end
  end
  if not best then die(('no stable version tag in %s'):format(url)) end
  return best
end

--- @param url string
--- @param branch string
--- @return string commit
function M.branch_head(url, branch)
  local what = ('cannot read branch %s of %s'):format(branch, url)
  local commit = run({ 'ls-remote', url, 'refs/heads/' .. branch }, what):match '^(%x+)'
  if not commit then die(('branch %s not found in %s'):format(branch, url)) end
  return commit
end

--- Name the kind of `ref`. A full commit SHA (40 or 64 hex digits) is a rev
--- without asking the remote. Otherwise a tag wins over a branch of the same
--- name, as it does in git.
--- @param url string
--- @param ref string
--- @return nvim-bundle.dto.RefKind
function M.ref_kind(url, ref)
  if (#ref == 40 or #ref == 64) and ref:match '^%x+$' then return 'rev' end
  local tag, branch = 'refs/tags/' .. ref, 'refs/heads/' .. ref
  local stdout = run({ 'ls-remote', url, tag, branch }, 'cannot list refs of ' .. url)
  local found = {}
  for name in stdout:gmatch '%x+\t(%S+)' do
    found[name] = true
  end
  if found[tag] then return 'tag' end
  if not found[branch] then die(('%s is neither a tag nor a branch of %s'):format(ref, url)) end
  return 'branch'
end

--- Check out `ref` of `url` into `dir`, and return the commit that is checked
--- out. A tag or branch is fetched by its full ref name at depth 1, because
--- `clone --branch` picks the branch when a tag shares its name. A rev may be
--- any commit, so it needs the full history.
--- @param url string
--- @param kind nvim-bundle.dto.RefKind
--- @param ref string
--- @param dir string
--- @return string commit
function M.checkout(url, kind, ref, dir)
  if kind == 'rev' then
    run({ 'clone', '-q', '--no-checkout', url, dir }, 'cannot clone ' .. url)
    run({ '-C', dir, 'checkout', '-q', ref }, ('cannot check out %s in %s'):format(ref, url))
  else
    local name = ('refs/%s/%s'):format(kind == 'tag' and 'tags' or 'heads', ref)
    run({ 'init', '-q', dir }, 'cannot create ' .. dir)
    local fetch = { '-C', dir, 'fetch', '-q', '--depth', '1', url, name }
    run(fetch, ('cannot fetch %s from %s'):format(name, url))
    run(
      { '-C', dir, 'checkout', '-q', 'FETCH_HEAD' },
      ('cannot check out %s from %s'):format(name, url)
    )
  end
  return vim.trim(run({ '-C', dir, 'rev-parse', 'HEAD' }, 'cannot read the checked-out commit'))
end

return M
