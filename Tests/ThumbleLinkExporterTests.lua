-- Run with Lua 5.1 (WoW-compatible syntax), without a game client or dependencies.
local root = assert(arg[1], "repository root required")
local combat, wrongClient, override = false, false, true
local secret = {}
local keys = {
    ACTIONBUTTON1 = { "1" }, ACTIONBUTTON2 = { "SHIFT-2" },
    ACTIONBUTTON3 = { "BUTTON4", "Q" }, ACTIONBUTTON4 = {}, ACTIONBUTTON5 = { "E" },
    MOVEFORWARD = { "W" },
}
_G.SlashCmdList, _G.UISpecialFrames = {}, {}
function InCombatLockdown() return combat end
function UnitAffectingCombat() return false end
function GetBuildInfo() return "1.60.1", "99999", "Oct 18 2026", wrongClient and 120000 or 16001 end
function UnitGUID() return "Player-1234-00000001" end
function UnitName() return "Test Warrior" end
function GetRealmName() return "Test Realm" end
function UnitClass() return "Warrior", "WARRIOR" end
function time() return 1792310400 end
function issecretvalue(value) return value == secret end
function canaccessvalue(value) return value ~= secret end
function GetBindingKey(command) return unpack(keys[command] or {}) end
function GetBindingAction(key)
    if key == "E" and override then return "OTHERCOMMAND" end
    for command, values in pairs(keys) do
        for _, value in ipairs(values) do if key == value then return command end end
    end
    return ""
end
local actions = { { "spell", 78 }, { "spell", 100 }, { "spell", 6552 }, { "macro", 1 }, { "spell", 999 } }
function GetActionInfo(slot) return unpack(actions[slot] or {}) end
function GetActionTexture(slot) return slot == 1 and 132282 or nil end
function GetMacroInfo() return "Unbound", 1, "/run error('macro body must never be exported')" end
_G.C_Spell = { GetSpellName = function(id)
    return ({ [78] = "Heroic Strike", [100] = "Charge", [6552] = "Pummel", [999] = "Overridden" })[id]
end }
for index = 1, 5 do _G["ActionButton" .. index] = { action = index } end
local addon = assert(loadfile(root .. "/Addons/ThumbleLink/ThumbleLink.lua"))()
assert(SLASH_THUMBLELINK1 == "/thumble" and type(SlashCmdList.THUMBLELINK) == "function")
local options = { main = true, extra = false, utility = false }
local export, count = addon.snapshot(options)
assert(count == 5 and export:find('"keys":%[%]'))
assert(export:find('"unavailableReason":"Binding overridden by another UI/addon"', 1, true))
assert(not export:find("macro body", 1, true))
assert(not export:find('"keys":["E"]', 1, true))
combat = true
assert(not pcall(addon.snapshot, options), "combat export must fail")
combat = false
wrongClient = true
assert(not pcall(addon.snapshot, options), "unsupported client must fail")
wrongClient = false
assert(not pcall(addon.snapshot, {}), "empty selection must fail")
local _, utilityCount = addon.snapshot({ utility = true })
assert(utilityCount == 12)
local oldAction = ActionButton1.action
ActionButton1.action = secret
local _, secretCount = addon.snapshot(options)
assert(secretCount == 4, "restricted slot must not be read")
ActionButton1.action = oldAction
local oldBinding = GetBindingKey
GetBindingKey = nil
assert(not pcall(addon.snapshot, options), "missing APIs must fail")
GetBindingKey = oldBinding
local oldName = C_Spell.GetSpellName
C_Spell.GetSpellName = function() return 'Quote " \\ newline\n日本語' end
local escaped = addon.snapshot(options)
assert(escaped:find('Quote \\" \\\\ newline ', 1, true), "escape JSON and scrub control characters")
C_Spell.GetSpellName = oldName

-- Minimal frame mock verifies the slash-command UI and clears stale exports on failure.
local lastButton, editBox
local function frame()
    local object = { scripts = {}, checked = false, value = "", TitleText = { SetText = function() end }, text = { SetText = function() end } }
    function object:SetScript(name, callback) self.scripts[name] = callback end
    function object:SetChecked(value) self.checked = value end
    function object:GetChecked() return self.checked end
    function object:SetText(value) self.value = value end
    function object:CreateFontString() return frame() end
    return setmetatable(object, { __index = function() return function() end end })
end
function CreateFrame(kind)
    local object = frame()
    if kind == "Button" then lastButton = object end
    if kind == "EditBox" then editBox = object end
    return object
end
SlashCmdList.THUMBLELINK()
lastButton.scripts.OnClick()
assert(editBox.value:find("THUMBLELINK1:", 1, true) == 1)
combat = true
lastButton.scripts.OnClick()
assert(editBox.value == "", "failed generation must clear previous export")
io.write(export, "\n")
