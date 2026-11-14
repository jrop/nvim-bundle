--- File and JSON I/O shared by building and vendoring.
local M = {}

--- @param msg string
--- @return never
local function die(msg) error('nvim-bundle: ' .. msg, 0) end

--- @param path string
--- @return string?
function M.read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local content = f:read '*a'
  f:close()
  return content
end

--- @param path string
--- @param content string
function M.write(path, content)
  local dir = vim.fs.dirname(path)
  if dir and dir ~= '.' then vim.fn.mkdir(dir, 'p') end
  local f, err = io.open(path, 'wb')
  if not f then die(('cannot write %s: %s'):format(path, err)) end
  f:write(content)
  f:close()
end

--- `vim.json.encode` escapes `/` on every supported Neovim, which turns each URL
--- in a hand-edited manifest into `https:\/\/...`, so strings are escaped here.
--- @param s string
--- @return string
local function encode_string(s)
  local escaped = s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == '\\' then return '\\\\' end
    if c == '\n' then return '\\n' end
    if c == '\t' then return '\\t' end
    return ('\\u%04x'):format(c:byte())
  end)
  return '"' .. escaped .. '"'
end

--- Encode with sorted keys and two-space indentation, so rewriting a manifest
--- after a one-entry change produces a one-line diff.
--- @param value any
--- @param indent string?
--- @return string
local function encode(value, indent)
  indent = indent or ''
  if type(value) == 'string' then return encode_string(value) end
  if type(value) ~= 'table' then return vim.json.encode(value) end

  local inner = indent .. '  '
  local parts = {}
  if #value > 0 then
    for _, item in ipairs(value) do
      parts[#parts + 1] = inner .. encode(item, inner)
    end
    return '[\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. ']'
  end

  local keys = vim.tbl_keys(value)
  if #keys == 0 then return '{}' end
  table.sort(keys)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = inner .. encode_string(key) .. ': ' .. encode(value[key], inner)
  end
  return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
end

--- Decode only; the caller validates the shape. `null` decodes as nil rather
--- than `vim.NIL`, because `vim.NIL` is truthy and would pass for a value.
--- @param path string
--- @return unknown? nil when the file does not exist
function M.read_json(path)
  local content = M.read(path)
  if not content then return nil end
  local ok, value = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if not ok then die(('%s is not valid JSON: %s'):format(path, value)) end
  return value
end

--- @param path string
--- @param value table
function M.write_json(path, value) M.write(path, encode(value) .. '\n') end

return M
