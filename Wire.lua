-- Wire.lua: sync messages as text (#37, docs/SYNC.md §4). Pure: no client
-- call, loaded with every global forbidden in its tests.
--
-- A message is lines; the first is the header, the rest one entry each:
--   GSA <TAB> 1 <TAB> TYPE <TAB> field ...
--   key=<type><value> <TAB> key=<type><value> ...      (one entry)
-- type: s (string), n (number), b (boolean, "1"/"0"). Strings escape "%",
-- tab, newline and carriage return as %XX; nothing else, so stored text is
-- carried exactly (it stays canonical, SYNC.md §2). Only the keys a caller
-- allows are read back: a received entry is a fresh table of known fields.

GuildSpy = GuildSpy or {}
local Wire = {}
GuildSpy.Wire = Wire

Wire.MAGIC, Wire.VERSION = "GSA", "1"

local function esc(s)
    return (s:gsub("[%%\t\n\r]", function(c) return string.format("%%%02X", c:byte()) end))
end
local function unesc(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
Wire.Esc, Wire.Unesc = esc, unesc

local function value(v)
    local t = type(v)
    if t == "string" then return "s" .. esc(v) end
    if t == "number" then return "n" .. string.format("%.17g", v) end
    if t == "boolean" then return "b" .. (v and "1" or "0") end
    return nil
end

local function parse(s)
    local t, rest = s:sub(1, 1), s:sub(2)
    if t == "s" then return true, unesc(rest) end
    if t == "n" then
        local n = tonumber(rest)
        if n == nil or n ~= n then return false end
        return true, n
    end
    if t == "b" then
        if rest == "1" then return true, true end
        if rest == "0" then return true, false end
    end
    return false
end

-- One entry as one line, from `fields` (a list of keys); absent keys are left out.
-- `alias` (optional): a short name per key on the wire (a GUILD message is
-- 255 bytes, #38).
function Wire.Entry(e, fields, alias)
    local parts = {}
    for _, k in ipairs(fields) do
        local v = value(e[k])
        if v then parts[#parts + 1] = (alias and alias[k] or k) .. "=" .. v end
    end
    return table.concat(parts, "\t")
end

-- One line back to a fresh table of the allowed keys; nil on any malformed field.
function Wire.ReadEntry(line, allowed, alias)
    local long
    if alias then
        long = {}
        for k, a in pairs(alias) do long[a] = k end
    end
    local e = {}
    for part in (line .. "\t"):gmatch("([^\t]*)\t") do
        if part ~= "" then
            local k, v = part:match("^([%w]+)=(.*)$")
            if not k then return nil end
            if long then k = long[k] end
            if k and allowed[k] then
                local ok, val = parse(v)
                if not ok then return nil end
                e[k] = val
            end
        end
    end
    return e
end

-- A message: header fields (strings or numbers), then entry lines.
function Wire.Message(kind, header, lines)
    local h = { Wire.MAGIC, Wire.VERSION, kind }
    for _, f in ipairs(header or {}) do h[#h + 1] = esc(tostring(f)) end
    local out = table.concat(h, "\t")
    if lines and #lines > 0 then out = out .. "\n" .. table.concat(lines, "\n") end
    return out
end

-- Its kind, header fields (unescaped strings) and entry lines; nil if not ours.
function Wire.Read(text)
    if type(text) ~= "string" then return nil end
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    local head = {}
    for f in (lines[1] .. "\t"):gmatch("([^\t]*)\t") do head[#head + 1] = f end
    if head[1] ~= Wire.MAGIC or head[2] ~= Wire.VERSION or not head[3] then return nil end
    local fields = {}
    for i = 4, #head do fields[#fields + 1] = unesc(head[i]) end
    local entries = {}
    for i = 2, #lines do if lines[i] ~= "" then entries[#entries + 1] = lines[i] end end
    return head[3], fields, entries
end

return Wire
