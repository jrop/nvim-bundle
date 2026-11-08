local M = {}

-- The spec is validated before parsing, so the lookups below cannot miss.
--- @diagnostic disable: need-check-nil
--- @diagnostic disable: param-type-mismatch

local types = { boolean = true, string = true, number = true }

--- @param message string
--- @return never
local function fail(message) error(message, 0) end

--- @param aliases table<string, string>
--- @param name string
--- @return string
local function resolve(aliases, name)
  local seen = {}
  while aliases[name] do
    if seen[name] then fail(('alias cycle at %s'):format(name)) end
    seen[name] = true
    name = aliases[name]
  end
  return name
end

--- @param name string
--- @param definition any
local function handler(name, definition)
  local multiple = false
  if type(definition) == 'table' then
    if #definition ~= 1 then fail(('array type for %s must have one element'):format(name)) end
    definition, multiple = definition[1], true
  end
  if not types[definition] then
    fail(('invalid type for %s: %s'):format(name, tostring(definition)))
  end
  return { name = name, type = definition, flag = definition == 'boolean', multiple = multiple }
end

--- @param spec table
--- @return table
local function build(spec)
  local compiled = { aliases = {}, handlers = {}, commands = {} }

  for name, definition in pairs(spec) do
    if type(name) ~= 'string' or name == '' then
      fail(('invalid spec key: %s'):format(tostring(name)))
    end

    if name:sub(1, 1) ~= '-' then
      if name == '_' then fail 'command name must not be _' end
      if type(definition) ~= 'table' then fail(('spec for %s must be a table'):format(name)) end
      compiled.commands[name] = build(definition)
    else
      if name == '-' or name == '--' then fail(('invalid option name: %s'):format(name)) end
      if name:find('=', 1, true) then fail(('option name must not contain =: %s'):format(name)) end
      if name:sub(1, 2) ~= '--' and #name ~= 2 then
        fail(('short option must have one character: %s'):format(name))
      end

      if type(definition) == 'string' and definition:sub(1, 1) == '-' then
        compiled.aliases[name] = definition
      else
        compiled.handlers[name] = handler(name, definition)
      end
    end
  end

  for alias in pairs(compiled.aliases) do
    if not compiled.handlers[resolve(compiled.aliases, alias)] then
      fail(('alias %s does not resolve to a declared option'):format(alias))
    end
  end

  return compiled
end

--- @param value string
--- @param handler table
--- @return boolean
local function option_like(value, handler)
  if #value < 2 or value:sub(1, 1) ~= '-' then return false end
  return not (handler.type == 'number' and tonumber(value) ~= nil)
end

--- Take the next argument as an option value, guarding against option-like
--- words. Number options accept a numeric word such as `-5`.
--- @param argv string[]
--- @param index integer
--- @param handler table
--- @param spelling string
--- @return string, integer
local function take_value(argv, index, handler, spelling)
  local value = argv[index + 1]
  if value == nil or option_like(value, handler) then
    fail(('option requires argument: %s'):format(spelling))
  end
  return value, index + 1
end

--- Parse `argv` from `start` with one compiled spec level, returning that
--- level's result. A command word selects a child spec and nests its result.
--- @param compiled table
--- @param argv string[]
--- @param start integer
--- @return table
local function parse_level(compiled, argv, start)
  local aliases, handlers = compiled.aliases, compiled.handlers
  local result = { _ = {} }
  local positionals = result._
  local index = start

  -- A bare number option counts its occurrences, so `nil` means "increment".
  local function apply(key, value)
    local handler = handlers[key]
    if handler.type == 'number' then
      if value == nil then
        value = (result[handler.name] or 0) + 1
      else
        value = tonumber(value)
        if value == nil then fail(('expected a number for %s'):format(handler.name)) end
      end
    end
    if handler.multiple then
      local list = result[handler.name]
      if list == nil then
        list = {}
        result[handler.name] = list
      end
      list[#list + 1] = value
    else
      result[handler.name] = value
    end
  end

  -- Resolve a spelling to its canonical handler before reading a value, so an
  -- alias needs no storage or type rules of its own.
  local function lookup(spelling)
    local key = resolve(aliases, spelling)
    local handler = handlers[key]
    if not handler then fail(('unknown or unexpected option: %s'):format(spelling)) end
    return key, handler
  end

  local function long_option(word)
    local name, value = word:match '^%-%-([^=]+)=(.*)$'
    local spelling = name and ('--' .. name) or word
    local key, handler = lookup(spelling)

    if handler.flag then
      if value ~= nil then fail(('option does not take a value: %s'):format(spelling)) end
      apply(key, true)
    else
      if value == nil then
        value, index = take_value(argv, index, handler, spelling)
      end
      apply(key, value)
    end
  end

  local function short_option(word)
    local i = 2
    while i <= #word do
      local spelling = '-' .. word:sub(i, i)
      local key, handler = lookup(spelling)
      local tail = word:sub(i)
      local counting = #tail > 1
        and handler.type == 'number'
        and not handler.multiple
        and tail == tail:sub(1, 1):rep(#tail)

      if handler.flag then
        apply(key, true)
      elseif counting then
        for _ = 1, #tail do
          apply(key, nil)
        end
        return
      elseif i < #word then
        fail(
          ('option requires argument (but was followed by another short argument): %s'):format(
            spelling
          )
        )
      else
        local value
        value, index = take_value(argv, index, handler, spelling)
        apply(key, value)
      end
      i = i + 1
    end
  end

  while index <= #argv do
    local word = argv[index]

    if word == '--' then
      for i = index + 1, #argv do
        positionals[#positionals + 1] = argv[i]
      end
      break
    end

    if #word > 1 and word:sub(1, 1) == '-' then
      if word:sub(1, 2) == '--' then
        long_option(word)
      else
        short_option(word)
      end
    else
      local command = compiled.commands[word]
      if command then
        result[word] = parse_level(command, argv, index + 1)
        return result
      end
      if next(compiled.commands) then fail(('unknown command: %s'):format(word)) end
      positionals[#positionals + 1] = word
    end

    index = index + 1
  end

  return result
end

--- Parse an argument vector with an `arg`-style specification.
---
--- The spec maps a spelling (`--name`, `-n`) to `boolean`, `string`, `number`,
--- an array wrapping one of those for repeated values, or another spelling for
--- an alias. A key that does not begin with `-` is a command with its own spec.
--- Positionals are returned in `_`, and each command nests its result.
--- @param spec table
--- @param argv string[]
--- @return table
function M.parse(spec, argv)
  if type(spec) ~= 'table' then fail 'spec must be a table' end
  if type(argv) ~= 'table' then fail 'argv must be a list of strings' end
  for i, word in ipairs(argv) do
    if type(word) ~= 'string' then fail(('argument %d must be a string'):format(i)) end
  end

  return parse_level(build(spec), argv, 1)
end

return M
