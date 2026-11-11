local addonPath = ...
local ns = {}
for _, file in ipairs({ 'Codec.lua', 'Core.lua', 'WoW.lua' }) do assert(loadfile(addonPath .. '/' .. file))('ThumbleBridge', ns) end
local combat, writes, saves = false, 0, 0
local bindings = { PAD3 = 'ACTIONBUTTON3', SPACE = 'JUMP' }
InCombatLockdown = function() return combat end
GetNumBindings = function() return 2 end
GetBinding = function(i) if i == 1 then return 'ACTIONBUTTON3', 'ACTIONBAR', 'PAD3' end; return 'JUMP', 'MOVEMENT', 'SPACE' end
GetBindingAction = function(key) return bindings[key] or '' end
GetBuildInfo = function() return '1.15.9', '63829', 'date', 11509 end
UnitClass = function() return 'Warrior', 'WARRIOR', 1 end
UnitGUID = function() return 'Player-Test-1' end
UnitName = function() return 'Testwarrior' end
GetRealmName = function() return 'Test Realm' end
UnitLevel = function() return 60 end
GetActionBarPage = function() return 1 end
GetServerTime = function() return 1792780000 end
GetTime = function() return 10 end
GetLocale = function() return 'enUS' end
GetCurrentBindingSet = function() return 2 end
GetCVar = function(name) return name == 'GamePadEmulateShift' and 'PADLTRIGGER' or 'none' end
GetActionInfo = function(slot) if slot == 3 then return 'spell', 100 end end
GetSpellInfo = function(id) if id == 100 then return 'Charge', 'Rank 1', 123 end; if id == 5308 then return 'Execute', 'Rank 1', 456 end end
GetAddOnMetadata = function() return '3.3.11' end
GetNumSpellTabs = function() return 1 end
GetSpellTabInfo = function() return 'Warrior', 123, 0, 2 end
GetSpellBookItemInfo = function(slot) return 'SPELL', slot == 1 and 100 or 5308 end
IsPassiveSpell = function() return false end
SetBinding = function(key, command) writes = writes + 1; bindings[key] = command; return true end
SaveBindings = function() saves = saves + 1 end
ConsolePort = { GetActionPageDriver = function() return 'condition', 1 end, GetActionBinding = function(_, slot) return slot == 3 and 'ACTIONBUTTON3' or nil end }

local text = ns.ExportCharacter()
local snapshot = ns.Decode(text)
assert(snapshot.character.guid == 'Player-Test-1' and snapshot.consolePortVersion == '3.3.11')
assert(#snapshot.bindings == 136 and #snapshot.spells == 2 and snapshot.spells[1].rank == 'Rank 1')
assert(snapshot.reserved.PADLTRIGGER == 'GamePadEmulateShift' and snapshot.actions[1].binding == 'ACTIONBUTTON3')
assert(writes == 0 and saves == 0 and ThumbleBridgeDB.exportText == text)
print('PASS legacy spellbook export includes current context with zero writes')

C_SpellBook = {
    GetNumSpellBookSkillLines = function() return 1 end,
    GetSpellBookSkillLineInfo = function() return { itemIndexOffset = 0, numSpellBookItems = 3 } end,
    GetSpellBookItemInfo = function(slot) return { spellID = slot == 1 and 100 or 5308, isUnlearned = slot == 3 } end,
    IsSpellInSpellBook = function() return true end,
    IsSpellBookItemPassive = function() return false end,
}
Enum = { SpellBookSpellBank = { Player = 0 } }
assert(#ns.Capture().spells == 2 and writes == 0)
print('PASS modern spellbook branch excludes unlearned entries')

UIParent = { GetWidth = function() return 1000 end, GetHeight = function() return 700 end }
ConsolePortBarManager = {}
_G.CPB_PAD3 = { GetCenter = function() return 800,100 end, GetWidth = function() return 50 end, GetHeight = function() return 50 end,
    IsVisible = function() return true end, GetAttribute = function(_, key) if key == 'labtype-' then return 'action' elseif key == 'labaction-' then return 3 end end }
local visual = ns.Capture().consolePortLayout
assert(#visual == 1 and visual[1].key == 'PAD3' and #visual[1].layers == 8)
assert(visual[1].layers[1].label == 'Charge' and visual[1].layers[1].id == 100 and visual[1].frame.x == .775)
assert(writes == 0 and saves == 0)
_G.CPB_PAD3 = nil; ConsolePortBarManager = nil; UIParent = nil
print('PASS read-only ConsolePort visual export resolves paged actions and all modifier states')

local plan = { bridgeVersion = 1, kind = 'binding-plan', id = 'test-plan', snapshotId = snapshot.snapshotId, characterGuid = snapshot.character.guid, bindingSet = 2, profile = { id = 'warrior', revision = 1, name = 'Warrior' }, changes = ns.Array({ { controlId = 'charge', label = 'Charge', key = 'PAD3', expectedBase = 'ACTIONBUTTON3', expectedEffective = 'ACTIONBUTTON3', spellId = 100 } }) }
local reviewed, rows = ns.ReviewText(ns.Encode(plan))
assert(rows[1].after == 'SPELL Charge' and writes == 0)
local receipt = ns.Decode(ns.ApplyReviewed(reviewed))
assert(receipt.results[1].base == 'SPELL Charge' and receipt.results[1].effective == 'SPELL Charge')
assert(writes == 1 and saves == 1 and bindings.SPACE == 'JUMP')
assert(ns.Decode(ns.ExportResult()).planId == plan.id)
-- Simulate SavedVariables loading without JSON-array metatables.
setmetatable(ThumbleBridgeDB.receipt.results, nil)
assert(ns.Decode(ns.ExportResult()).results[1].command == 'SPELL Charge')
print('PASS review, explicit apply, readback receipt, and receipt export after reload')

bindings.PAD3 = 'JUMP'
assert(not pcall(ns.ExportResult))
assert(not pcall(ns.Undo))
bindings.PAD3 = 'SPELL Charge'
combat = true
assert(not pcall(ns.Undo))
combat = false
ns.Undo()
assert(bindings.PAD3 == 'ACTIONBUTTON3' and bindings.SPACE == 'JUMP' and ThumbleBridgeDB.receipt == nil and ThumbleBridgeDB.exportText == nil)
print('PASS restore requires unchanged post-apply bindings and refuses combat')

bindings.PADBACK = 'OPENALLBAGS'
local staleRoute = true
GetBindingAction = function(key, override)
    if key == 'PADBACK' and override and staleRoute then return 'OPENALLBAGS' end
    return bindings[key] or ''
end
snapshot = ns.Decode(ns.ExportCharacter())
local utilityPlan = { bridgeVersion = 1, kind = 'binding-plan', id = 'utility-plan', snapshotId = snapshot.snapshotId, characterGuid = snapshot.character.guid, bindingSet = 2, profile = plan.profile,
    changes = ns.Array({ { controlId = 'chat', label = 'Chat', key = 'PADBACK', expectedBase = 'OPENALLBAGS', expectedEffective = 'OPENALLBAGS', action = 'OPENCHAT' } }) }
local pending = ns.Decode(ns.ApplyReviewed(utilityPlan))
assert(pending.status == 'pending' and bindings.PADBACK == 'OPENCHAT')
assert(not pcall(ns.ExportResult), 'Stale effective route must not confirm a result')
staleRoute = false
local confirmed = ns.Decode(ns.ExportResult())
assert(confirmed.status == 'verified' and confirmed.results[1].effective == 'OPENCHAT')
ns.Undo()
assert(bindings.PADBACK == 'OPENALLBAGS')
print('PASS delayed utility routes stay pending until effective readback confirms the new binding')

local frames = {}
local function frame()
    local f = { scripts = {}, text = '', enabled = true }
    setmetatable(f, { __index = function(_, key)
        return function(self, ...) self.lastCall = key end
    end })
    f.SetScript = function(self, name, fn) self.scripts[name] = fn end
    f.SetText = function(self, value) self.text = value; if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self) end end
    f.GetText = function(self) return self.text end
    f.Enable = function(self) self.enabled = true end
    f.Disable = function(self) self.enabled = false end
    f.GetStringHeight = function() return 100 end
    f.CreateFontString = function() return frame() end
    f.TitleText = { SetText = function() end }
    return f
end
CreateFrame = function(kind, name, parent, template) local f = frame(); frames[#frames + 1] = f; return f end
UISpecialFrames = {}; SlashCmdList = {}; UIParent = {}; ChatFontNormal = {}
assert(loadfile(addonPath .. '/UI.lua'))('ThumbleBridge', ns)
assert(SLASH_THUMBLEBRIDGE1 == '/thumblebridge' and SLASH_THUMBLEBRIDGE2 == '/tbbridge' and SLASH_THUMBLEBRIDGE3 == '/thumble')
SlashCmdList.THUMBLEBRIDGE()
local export, reviewButton, apply, editor, window
for _, f in ipairs(frames) do
    if f.text == 'Export character' then export = f end
    if f.text == 'Review pasted plan' then reviewButton = f end
    if f.text == 'Apply reviewed changes' then apply = f end
    if f.scripts.OnTextChanged then editor = f end
    if f.scripts.OnEvent then window = f end
end
assert(export and reviewButton and apply and editor and window and not apply.enabled)
export.scripts.OnClick()
local exported = ns.Decode(editor:GetText()); plan.snapshotId = exported.snapshotId
editor:SetText(ns.Encode(plan)); reviewButton.scripts.OnClick()
assert(apply.enabled and bindings.PAD3 == 'ACTIONBUTTON3')
editor:SetText(editor:GetText() .. ' ')
assert(not apply.enabled)
reviewButton.scripts.OnClick(); assert(apply.enabled)
window.scripts.OnEvent(); assert(not apply.enabled and bindings.PAD3 == 'ACTIONBUTTON3')
print('PASS UI opens disabled, reviews without writes, and invalidates apply on edit/combat')

local manualID = ThumbleBridgeDB.snapshot.snapshotId
ns.ExportPhoneCharacter()
local phone = ns.Decode(ThumbleBridgeDB.phoneExportText)
assert(phone.snapshotId ~= manualID and ThumbleBridgeDB.snapshot.snapshotId == manualID)
local phonePlan = ns.Decode(ns.Encode(plan))
phonePlan.id = 'phone-spell-plan'; phonePlan.snapshotId = phone.snapshotId
editor:SetText(ns.Encode(phonePlan)); reviewButton.scripts.OnClick()
assert(apply.enabled and bindings.PAD3 == 'ACTIONBUTTON3')
apply.scripts.OnClick()
assert(bindings.PAD3 == 'SPELL Charge')
assert(ns.Decode(ns.ExportResult()).planId == phonePlan.id)
ns.Undo()
combat = true
assert(not pcall(ns.ExportPhoneCharacter))
combat = false
print('PASS independent phone snapshots preserve manual exports and complete UI review, Apply, receipt and Restore')

assert(loadfile(addonPath .. '/Sync.lua'))('ThumbleBridge', ns)
local logout = frames[#frames].scripts.OnEvent
local beforeLogout = ns.Encode(ns.AllBindings())
ThumbleBridgeDB.autoSync = true
logout(nil, 'PLAYER_LOGOUT')
assert(ThumbleBridgeDB.phoneExportText and ThumbleBridgeDB.phoneSnapshot)
assert(ns.Decode(ThumbleBridgeDB.phoneExportText).snapshotId == ThumbleBridgeDB.phoneSnapshot.snapshotId)
ThumbleBridgeDB.autoSync = false
logout(nil, 'PLAYER_LOGOUT')
assert(ThumbleBridgeDB.phoneExportText == nil and ThumbleBridgeDB.phoneSnapshot == nil)
ThumbleBridgeDB.autoSync = true; combat = true
logout(nil, 'PLAYER_LOGOUT')
assert(ThumbleBridgeDB.phoneExportText == nil and ThumbleBridgeDB.phoneSnapshot == nil)
combat = false
assert(ns.Encode(ns.AllBindings()) == beforeLogout)
print('PASS phone character exports run through logout, respect sync opt-out and combat, and perform zero binding writes')
