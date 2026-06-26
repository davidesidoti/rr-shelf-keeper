-- RR Shelf Keeper — snapshot persistence (Phase 2: serialize/deserialize + per-save file I/O).
--
-- Format: a Lua return-table (CLAUDE.md §5). Chosen over JSON because UE4SS ships no JSON
-- library and a `return { ... }` chunk needs zero dependencies — serialize is a small
-- recursive emitter, deserialize is the Lua loader run in an EMPTY sandbox env (text-only
-- chunk, no access to os/io/globals) so a tampered layout file cannot execute code.
--
-- The pure parts (serialize/deserialize/pathFor) are unit-tested offline (tests/store_test).
-- save()/load() do real file I/O (testable against a temp file). resolveDir() self-locates
-- the mod folder from the running game and is verified in-game.
local M = {}

local SEP = package.config:sub(1, 1)         -- "\" on Windows, "/" on POSIX

-- ---- serialize (pure) ---------------------------------------------------------------------

local ESC = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function encStr(s)
    return '"' .. (s:gsub('[%c\\"]', function(c) return ESC[c] or string.format("\\%d", c:byte()) end)) .. '"'
end

-- Integers print with no decimal point (SKUs/indices read back clean); floats keep precision.
local function encNum(n)
    if math.type then
        if math.type(n) == "integer" then return string.format("%d", n) end
        return string.format("%.14g", n)
    end
    if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%d", n) end
    return string.format("%.14g", n)
end

local function encKey(k)
    if type(k) == "string" and k:match("^[%a_][%w_]*$") then return k end
    if type(k) == "number" then return "[" .. encNum(k) .. "]" end
    return "[" .. encStr(k) .. "]"
end

-- Deterministic table emit: numeric keys (ascending) then string keys (alphabetical), so the
-- output is stable across runs — required for the idempotency test and clean diffs on disk.
local function enc(v, indent)
    local t = type(v)
    if t == "number"  then return encNum(v) end
    if t == "boolean" then return tostring(v) end
    if t == "string"  then return encStr(v) end
    if t ~= "table"   then error("store: cannot serialize type " .. t) end

    local nKeys, sKeys = {}, {}
    for k in pairs(v) do
        local tk = type(k)
        if tk == "number" then nKeys[#nKeys + 1] = k
        elseif tk == "string" then sKeys[#sKeys + 1] = k
        else error("store: cannot serialize table key of type " .. tk) end
    end
    if #nKeys == 0 and #sKeys == 0 then return "{}" end
    table.sort(nKeys); table.sort(sKeys)

    local ind2, parts = indent .. "  ", {}
    for _, k in ipairs(nKeys) do parts[#parts + 1] = ind2 .. encKey(k) .. " = " .. enc(v[k], ind2) end
    for _, k in ipairs(sKeys) do parts[#parts + 1] = ind2 .. encKey(k) .. " = " .. enc(v[k], ind2) end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

function M.serialize(tbl)
    return "return " .. enc(tbl, "") .. "\n"
end

-- ---- deserialize (pure, sandboxed) --------------------------------------------------------

-- Load a literal-only chunk in an empty environment. setfenv path is Lua 5.1; the load(...,"t",{})
-- path is 5.2+ (UE4SS runs 5.4). Either way the chunk sees no globals -> cannot exec code.
local function loadSandboxed(str)
    if setfenv then
        local f, err = loadstring(str, "layout")
        if not f then return nil, err end
        setfenv(f, {})
        return f
    end
    return load(str, "=layout", "t", {})
end

function M.deserialize(str)
    if type(str) ~= "string" or str == "" then return nil, "empty input" end
    local chunk, perr = loadSandboxed(str)
    if not chunk then return nil, "parse error: " .. tostring(perr) end
    local ok, res = pcall(chunk)
    if not ok then return nil, "eval error: " .. tostring(res) end
    if type(res) ~= "table" then return nil, "layout is not a table" end
    return res
end

-- ---- file I/O (testable against a temp file) ----------------------------------------------

function M.pathFor(dir, key)
    return tostring(dir) .. SEP .. tostring(key) .. ".lua"
end

function M.save(path, tbl)
    local ok, err = pcall(function()
        local s = M.serialize(tbl)
        local f, oerr = io.open(path, "w")
        if not f then error(oerr or ("cannot open " .. tostring(path) .. " for write")) end
        f:write(s)
        f:close()
    end)
    if ok then return true end
    return false, err
end

function M.load(path)
    local f = io.open(path, "r")
    if not f then return nil, "no layout file at " .. tostring(path) end
    local s = f:read("*a")
    f:close()
    return M.deserialize(s)
end

-- ---- mod-folder resolution (runtime; verified in-game) ------------------------------------

-- Resolve the mod's "layouts" directory. UE4SS sets a require'd module's chunk source to its
-- on-disk path ("@...\RR Shelf Keeper\Scripts\store.lua"), so we self-locate from THIS file:
-- strip the filename to get Scripts\, strip Scripts to get the mod root, append "layouts".
-- `override` (config.LayoutsDir) wins if set; the caller should log the resolved path so the
-- first in-game save confirms where files land (the only allowed fallback is a relative dir).
function M.resolveDir(override)
    if type(override) == "string" and override ~= "" then return override end
    local src
    pcall(function() src = debug.getinfo(1, "S").source end)
    if type(src) == "string" and src:sub(1, 1) == "@" then
        local p = src:sub(2)
        local dir = p:match("^(.*)[/\\][^/\\]+$")                 -- strip "\store.lua"
        if dir then
            local root = dir:match("^(.*)[/\\][Ss]cripts$") or dir -- strip "\Scripts"
            return root .. SEP .. "layouts"
        end
    end
    return "layouts"                                              -- last-resort relative dir
end

return M
