-- tests/key_test.lua — run from repo root:  lua tests/key_test.lua
-- Exercises the PURE filename sanitizer in key.lua. fromGamemode() reads the live
-- Core_Gamemode_C and is verified in-game (docs/PLAN.md Phase 2).
package.path = package.path .. ";RR Shelf Keeper/Scripts/?.lua"
local key = require("key")

local failures = 0
local function check(name, cond)
    if cond then print("PASS: " .. name)
    else print("FAIL: " .. name); failures = failures + 1 end
end

-- the Phase-0 finding: gm["Save Slot Name"] == "Player_Save2" (the .sav basename) passes through.
check("clean save name is preserved", key.sanitize("Player_Save2") == "Player_Save2")
check("alnum/underscore/dash kept", key.sanitize("Save-File_01") == "Save-File_01")

-- unsafe characters become underscores
check("spaces and punctuation replaced", key.sanitize("my save!") == "my_save_")
check("slashes replaced (no path separators leak)",
    key.sanitize("a/b\\c"):find("[/\\]") == nil)

-- path traversal is neutralised: result has no "." at all and no ".."
do
    local s = key.sanitize("../../etc/passwd")
    check("traversal: no dots survive", s:find(".", 1, true) == nil)
    check("traversal: no slashes survive", s:find("[/\\]") == nil)
end

-- empties / non-strings fall back to "default"
check("nil -> default", key.sanitize(nil) == "default")
check("empty string -> default", key.sanitize("") == "default")
check("number -> default", key.sanitize(123) == "default")
check("table -> default", key.sanitize({}) == "default")

-- a name made entirely of unsafe chars still yields a non-empty, safe filename
do
    local s = key.sanitize("###")
    check("all-unsafe -> non-empty safe string", type(s) == "string" and #s > 0
        and s:find("[^%w_-]") == nil)
end

print(string.format("\n%s", failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)")))
os.exit(failures == 0 and 0 or 1)
