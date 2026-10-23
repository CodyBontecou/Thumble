local _, ns = ...
local counter = 0
local function public(value)
    return not (issecretvalue and issecretvalue(value)) and not (canaccessvalue and not canaccessvalue(value))
end
local function safeText(value, fallback)
    if not public(value) or type(value) ~= 'string' or #value > 512 then return fallback end
    return value:gsub('[%z\1-\31\127]', ' ')
end
local function call(fn, ...)
    if type(fn) ~= 'function' then return nil end
    local ok, a, b, c = pcall(fn, ...); if ok then return a, b, c end
end
local function spellInfo(id)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = call(C_Spell.GetSpellInfo, id)
        if type(info) == 'table' then return safeText(info.name), info.iconID end
    end
    local name, _, icon = call(GetSpellInfo, id); return safeText(name), icon
end
function ns.GetBinding(key, override) return safeText(call(GetBindingAction, key, override), '') end
function ns.AllBindings()
    local result = {}
    for i = 1, GetNumBindings() do
        local values = { GetBinding(i) }
        for n = 3, #values do
            local key = safeText(values[n])
            if key and key ~= '' then result[key] = ns.GetBinding(key, false) end
        end
    end
    -- Include direct spell bindings which some clients omit from the named list.
    for _, key in ipairs(ns.Buttons) do local command = ns.GetBinding(key, false); if command ~= '' then result[key] = command end end
    return result
end
local function isConsolePortProxy(key, base, effective)
    if not ConsolePort or not ConsolePortBarManager or effective ~= 'CLICK CPB_' .. key .. ':ControllerInput' then return false end
    if not base:match('^ACTIONBUTTON%d+$') and not base:match('^MULTIACTIONBAR%d+BUTTON%d+$') then return false end
    local button = _G['CPB_' .. key]
    return button ~= nil and button.id == key and type(button.GetName) == 'function' and button:GetName() == 'CPB_' .. key
end
local function getSpells()
    local spells, seen = ns.Array(), {}
    local function add(id, passive)
        if type(id) ~= 'number' or seen[id] then return end
        local name = spellInfo(id)
        if not name then return end
        seen[id] = true
        local _, rank = call(GetSpellInfo, id)
        spells[#spells + 1] = { id = id, name = name, rank = safeText(rank, ''), passive = passive == true }
    end
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookItemInfo then
        local bank = Enum.SpellBookSpellBank.Player
        for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
            if info and not info.offSpecID then
                for slot = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                    local item = C_SpellBook.GetSpellBookItemInfo(slot, bank)
                    if item and item.spellID and not item.isOffSpec and not item.isUnlearned and not item.isFutureSpell then
                        local known = not C_SpellBook.IsSpellInSpellBook or C_SpellBook.IsSpellInSpellBook(item.spellID, bank, true)
                        if known then add(item.spellID, item.isPassive or call(C_SpellBook.IsSpellBookItemPassive, slot, bank)) end
                    end
                end
            end
        end
    elseif GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemInfo then
        for tab = 1, GetNumSpellTabs() do
            local _, _, offset, count = GetSpellTabInfo(tab)
            for slot = offset + 1, offset + count do
                local kind, id = GetSpellBookItemInfo(slot, BOOKTYPE_SPELL or 'spell')
                if kind == 'SPELL' then add(id, call(IsPassiveSpell, slot, BOOKTYPE_SPELL or 'spell')) end
            end
        end
    else error('This client has no supported spellbook API') end
    if #spells > 2048 then error('Spellbook exceeds export limit') end
    table.sort(spells, function(a, b) return a.id < b.id end)
    return spells
end
local function actionName(kind, id)
    if kind == 'spell' then return spellInfo(id) end
    if kind == 'macro' then return safeText(call(GetMacroInfo, id), 'Macro') end
    if kind == 'item' then return safeText(call(GetItemInfo, id), 'Item ' .. tostring(id)) end
    return kind
end
-- Read-only visual snapshot of ConsolePort's actual button frames and LAB states.
-- Never clicks a frame or changes an action/attribute.
local function consolePortLayout(page, spells)
    if not ConsolePortBarManager or not UIParent or not UIParent.GetWidth then return nil end
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    if not sw or not sh or sw <= 0 or sh <= 0 then return nil end
    local result = ns.Array()
    local mods = { '', 'SHIFT-', 'CTRL-', 'ALT-', 'CTRL-SHIFT-', 'ALT-SHIFT-', 'ALT-CTRL-', 'ALT-CTRL-SHIFT-' }
    for _, key in ipairs(ns.Buttons) do
        local button = _G['CPB_' .. key]
        if button and button.GetCenter and button.GetAttribute and button:IsVisible() then
            local x, y = button:GetCenter()
            local w, h = button:GetWidth(), button:GetHeight()
            if x and y and w > 0 and h > 0 then
                local layers = ns.Array()
                for _, mod in ipairs(mods) do
                    local command = ns.GetBinding(mod .. key, false)
                    local kind = button:GetAttribute('labtype-' .. mod)
                    local id = button:GetAttribute('labaction-' .. mod)
                    -- Direct bindings take precedence over an old LAB action slot.
                    if command:sub(1, 6) == 'SPELL ' then
                        kind = 'spell'; id = nil
                        for _, spell in ipairs(spells) do if spell.name == command:sub(7) then id = spell.id; break end end
                    elseif command == 'ATTACK' then kind = 'spell'; id = 6603
                    elseif kind == 'action' and type(id) == 'number' then
                        local slot = id <= 12 and id + (page - 1) * 12 or id
                        kind, id = GetActionInfo(slot)
                    end
                    local label = (kind == 'spell' or kind == 'item' or kind == 'macro') and id and actionName(kind, id) or (command ~= '' and (call(GetBindingName, command) or command) or 'Unbound')
                    local row = { modifier = mod, label = safeText(label, 'Unbound'), command = command }
                    if (kind == 'spell' or kind == 'item') and type(id) == 'number' then row.kind = kind; row.id = id end
                    layers[#layers + 1] = row
                end
                result[#result + 1] = { key = key, frame = { x = (x - w / 2) / sw, y = 1 - (y + h / 2) / sh, width = w / sw, height = h / sh }, layers = layers }
            end
        end
    end
    return result
end
function ns.Capture()
    if InCombatLockdown() then error('Leave combat before exporting or reviewing bindings') end
    local version, build, _, interface = GetBuildInfo()
    local _, class, classId = UnitClass('player')
    local spec = GetSpecialization and GetSpecialization()
    local specId = spec and GetSpecializationInfo and GetSpecializationInfo(spec) or 0
    local page = GetActionBarPage and GetActionBarPage() or 1
    if ConsolePort and ConsolePort.GetActionPageDriver then
        local _, activePage = call(ConsolePort.GetActionPageDriver, ConsolePort)
        if type(activePage) == 'number' then page = activePage end
    end
    local modifiers, reserved = {}, {}
    for _, name in ipairs({ 'GamePadEmulateShift', 'GamePadEmulateCtrl', 'GamePadEmulateAlt', 'GamePadCursorLeftClick', 'GamePadCursorRightClick' }) do
        local key = safeText(call(GetCVar, name), 'none')
        modifiers[name] = key
        if key:upper() ~= 'NONE' and key ~= '' then reserved[key] = name end
    end
    local bindings = ns.Array()
    local mods = { '', 'SHIFT-', 'CTRL-', 'ALT-', 'CTRL-SHIFT-', 'ALT-SHIFT-', 'ALT-CTRL-', 'ALT-CTRL-SHIFT-' }
    for _, mod in ipairs(mods) do
        for _, button in ipairs(ns.Buttons) do
            local key = mod .. button
            local base, effective = ns.GetBinding(key, false), ns.GetBinding(key, true)
            bindings[#bindings + 1] = { key = key, base = base, effective = effective, consolePortProxy = isConsolePortProxy(key, base, effective) }
        end
    end
    local actions = ns.Array()
    for slot = 1, math.min(300, math.max(180, MAX_ACTION_BUTTONS or 0)) do
        local kind, id = GetActionInfo(slot)
        if public(kind) and public(id) and type(kind) == 'string' and (type(id) == 'number' or type(id) == 'string') then
            local binding = ConsolePort and ConsolePort.GetActionBinding and call(ConsolePort.GetActionBinding, ConsolePort, slot)
            actions[#actions + 1] = { slot = slot, type = kind, id = id, name = actionName(kind, id) or kind, binding = safeText(binding, '') }
        end
    end
    local metadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    local spells = getSpells()
    return {
        bridgeVersion = 1, kind = 'character', snapshotId = '', exportedAt = GetServerTime(),
        character = { guid = UnitGUID('player'), name = UnitName('player'), realm = GetRealmName(), class = class, classId = classId, specId = specId or 0, level = UnitLevel('player') },
        gameVersion = version, build = build, interface = interface, locale = GetLocale(), bindingSet = GetCurrentBindingSet(), actionPage = page,
        consolePortVersion = safeText(call(metadata, 'ConsolePort', 'Version'), 'not loaded'),
        modifiers = modifiers, reserved = reserved, bindings = bindings, actions = actions, spells = spells,
        consolePortLayout = consolePortLayout(page, spells),
    }
end
function ns.ExportCharacter()
    local snapshot = ns.Capture()
    counter = counter + 1
    snapshot.snapshotId = snapshot.character.guid .. ':' .. snapshot.exportedAt .. ':' .. counter .. ':' .. math.floor(GetTime() * 1000)
    local encoded = ns.Encode(snapshot)
    ThumbleBridgeDB = ThumbleBridgeDB or {}
    ThumbleBridgeDB.snapshot = snapshot
    ThumbleBridgeDB.exportText = encoded
    return encoded
end
function ns.Environment()
    return {
        inCombat = InCombatLockdown, capture = ns.Capture, allBindings = ns.AllBindings, get = ns.GetBinding,
        set = function(key, command)
            local context
            if command and CPAPI and CPAPI.GetBindingContextForAction then context = call(CPAPI.GetBindingContextForAction, command) end
            local ok, result = pcall(SetBinding, key, command, context)
            return ok and result == true
        end,
        save = function(scope)
            if InCombatLockdown() or GetCurrentBindingSet() ~= scope then return false end
            local ok, result = pcall(SaveBindings, scope)
            return ok and result ~= false
        end,
    }
end
function ns.ReviewText(text)
    local plan = ns.Decode(text)
    local rows = ns.Review(plan, ThumbleBridgeDB and ThumbleBridgeDB.snapshot, ns.Capture())
    return plan, rows
end
function ns.ApplyReviewed(plan)
    ThumbleBridgeDB = ThumbleBridgeDB or {}
    local rows, before = ns.Apply(plan, ThumbleBridgeDB.snapshot, ns.Environment())
    ThumbleBridgeDB.undo = { characterGuid = UnitGUID('player'), bindingSet = plan.bindingSet, before = before, after = ns.AllBindings() }
    local result = ns.Array()
    for _, row in ipairs(rows) do result[#result + 1] = { key = row.key, controlId = row.controlId, command = row.after, base = ns.GetBinding(row.key, false), effective = ns.GetBinding(row.key, true) } end
    local verified = true
    for _, row in ipairs(result) do if row.effective ~= row.command then verified = false end end
    ThumbleBridgeDB.receipt = { status = verified and 'verified' or 'pending', bridgeVersion = 1, kind = 'binding-receipt', planId = plan.id, snapshotId = plan.snapshotId, characterGuid = plan.characterGuid, bindingSet = plan.bindingSet, profile = plan.profile, appliedAt = GetServerTime(), results = result }
    ThumbleBridgeDB.receiptText = ns.Encode(ThumbleBridgeDB.receipt)
    return ThumbleBridgeDB.receiptText
end
function ns.ExportResult()
    local receipt = ThumbleBridgeDB and ThumbleBridgeDB.receipt
    if not receipt or receipt.characterGuid ~= UnitGUID('player') or receipt.bindingSet ~= GetCurrentBindingSet() then error('No applied result for this character and scope') end
    for _, row in ipairs(receipt.results) do
        local base, effective = ns.GetBinding(row.key, false), ns.GetBinding(row.key, true)
        if base ~= row.command or effective ~= row.command then error(row.key .. ' is not routed to the proposed action yet; wait for ConsolePort to refresh or restore the last bindings') end
        row.base = base; row.effective = effective
    end
    receipt.status = 'verified'; receipt.verifiedAt = GetServerTime()
    ThumbleBridgeDB.receiptText = ns.Encode(receipt)
    return ThumbleBridgeDB.receiptText
end
function ns.Undo()
    local backup = ThumbleBridgeDB and ThumbleBridgeDB.undo
    if not backup then error('No binding backup is available') end
    if InCombatLockdown() then error('Leave combat and click Restore again; nothing is queued') end
    if UnitGUID('player') ~= backup.characterGuid or GetCurrentBindingSet() ~= backup.bindingSet then error('Character or binding scope changed') end
    local env = ns.Environment()
    if ns.Encode(env.allBindings()) ~= ns.Encode(backup.after) then error('Bindings changed after apply; restore them manually to avoid overwriting newer edits') end
    for key in pairs(backup.after) do if backup.before[key] ~= backup.after[key] and not env.set(key, backup.before[key]) then error('Restore failed for ' .. key) end end
    for key, command in pairs(backup.before) do if backup.after[key] ~= command and not env.set(key, command) then error('Restore failed for ' .. key) end end
    if not env.save(backup.bindingSet) or ns.Encode(env.allBindings()) ~= ns.Encode(backup.before) then error('Restore could not be verified; inspect your bindings') end
    ThumbleBridgeDB.undo = nil; ThumbleBridgeDB.receipt = nil; ThumbleBridgeDB.receiptText = nil; ThumbleBridgeDB.snapshot = nil; ThumbleBridgeDB.exportText = nil
end
