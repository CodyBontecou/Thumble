local _, ns = ...
local arrayMeta, null = {}, {}
ns.Array = function(t) return setmetatable(t or {}, arrayMeta) end
ns.Null = null
local MAX = 262144
local function quote(s)
    return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
        if c == '"' or c == '\\' then return '\\' .. c end
        return string.format('\\u%04x', c:byte())
    end) .. '"'
end
function ns.Encode(value)
    local seen = {}
    local function encode(v, depth)
        if depth > 24 then error('JSON nesting limit') end
        local kind = type(v)
        if v == null then return 'null' end
        if kind == 'string' then return quote(v) end
        if kind == 'boolean' then return tostring(v) end
        if kind == 'number' and v == v and math.abs(v) < math.huge then return string.format('%.17g', v) end
        if kind ~= 'table' or seen[v] then error('Unsupported JSON value') end
        seen[v] = true
        local parts = {}
        local isArray = getmetatable(v) == arrayMeta or #v > 0
        if isArray then
            for k in pairs(v) do if type(k) ~= 'number' or k < 1 or k > #v or k ~= math.floor(k) then error('Invalid JSON array') end end
            for i = 1, #v do parts[i] = encode(v[i], depth + 1) end
        else
            local keys = {}
            for k in pairs(v) do if type(k) ~= 'string' then error('JSON object key must be text') end; keys[#keys + 1] = k end
            table.sort(keys)
            for i, k in ipairs(keys) do parts[i] = quote(k) .. ':' .. encode(v[k], depth + 1) end
        end
        seen[v] = nil
        return (isArray and '[' or '{') .. table.concat(parts, ',') .. (isArray and ']' or '}')
    end
    local text = encode(value, 0)
    if #text > MAX then error('Export exceeds 256 KiB') end
    return text
end
local function utf8(n)
    if n < 128 then return string.char(n) end
    if n < 2048 then return string.char(192 + math.floor(n / 64), 128 + n % 64) end
    if n < 65536 then return string.char(224 + math.floor(n / 4096), 128 + math.floor(n / 64) % 64, 128 + n % 64) end
    return string.char(240 + math.floor(n / 262144), 128 + math.floor(n / 4096) % 64, 128 + math.floor(n / 64) % 64, 128 + n % 64)
end
function ns.Decode(text)
    if type(text) ~= 'string' or #text > MAX then error('Paste JSON under 256 KiB') end
    local pos, nodes = 1, 0
    local function fail() error('Invalid JSON near byte ' .. pos) end
    local function ws() local _, last = text:find('^[ \t\r\n]*', pos); pos = (last or pos - 1) + 1 end
    local function hex()
        local s = text:sub(pos, pos + 3)
        if #s ~= 4 or not s:match('^%x%x%x%x$') then fail() end
        pos = pos + 4; return tonumber(s, 16)
    end
    local function str()
        if text:sub(pos, pos) ~= '"' then fail() end
        pos = pos + 1
        local out = {}
        while pos <= #text do
            local c = text:sub(pos, pos); pos = pos + 1
            if c == '"' then return table.concat(out) end
            if c:byte() < 32 then fail() end
            if c == '\\' then
                c = text:sub(pos, pos); pos = pos + 1
                local escapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
                if c == 'u' then
                    local n = hex()
                    if n >= 0xD800 and n <= 0xDBFF then
                        if text:sub(pos, pos + 1) ~= '\\u' then fail() end
                        pos = pos + 2; local low = hex()
                        if low < 0xDC00 or low > 0xDFFF then fail() end
                        n = 65536 + (n - 0xD800) * 1024 + low - 0xDC00
                    elseif n >= 0xDC00 and n <= 0xDFFF then fail() end
                    c = utf8(n)
                else c = escapes[c]; if not c then fail() end end
            end
            out[#out + 1] = c
        end
        fail()
    end
    local parse
    parse = function(depth)
        nodes = nodes + 1
        if depth > 24 or nodes > 30000 then error('JSON complexity limit') end
        ws(); local c = text:sub(pos, pos)
        if c == '"' then return str() end
        if c == '{' or c == '[' then
            local isArray = c == '['; local result = isArray and ns.Array() or {}; local close = isArray and ']' or '}'
            pos = pos + 1; ws()
            if text:sub(pos, pos) == close then pos = pos + 1; return result end
            while true do
                local key
                if not isArray then key = str(); ws(); if text:sub(pos, pos) ~= ':' or result[key] ~= nil then fail() end; pos = pos + 1 end
                local value = parse(depth + 1)
                if isArray then result[#result + 1] = value else result[key] = value end
                ws(); c = text:sub(pos, pos); pos = pos + 1
                if c == close then return result end
                if c ~= ',' then fail() end
                ws()
            end
        end
        for literal, value in pairs({ ['true'] = true, ['false'] = false, ['null'] = null }) do
            if text:sub(pos, pos + #literal - 1) == literal then pos = pos + #literal; return value end
        end
        local start = pos
        if c == '-' then pos = pos + 1 end
        c = text:sub(pos, pos)
        if c == '0' then pos = pos + 1
        elseif c:match('[1-9]') then repeat pos = pos + 1 until not text:sub(pos, pos):match('%d')
        else fail() end
        if text:sub(pos, pos) == '.' then
            pos = pos + 1; if not text:sub(pos, pos):match('%d') then fail() end
            repeat pos = pos + 1 until not text:sub(pos, pos):match('%d')
        end
        if text:sub(pos, pos):match('[eE]') then
            pos = pos + 1; if text:sub(pos, pos):match('[+-]') then pos = pos + 1 end
            if not text:sub(pos, pos):match('%d') then fail() end
            repeat pos = pos + 1 until not text:sub(pos, pos):match('%d')
        end
        local n = tonumber(text:sub(start, pos - 1)); if not n or n ~= n or math.abs(n) == math.huge then fail() end
        return n
    end
    local result = parse(0); ws(); if pos <= #text then fail() end
    return result
end
