local _, ns = ...

-- A separate snapshot never invalidates a player's reviewed binding plan.
function ns.ExportConsolePortSync()
    if not ConsolePort or not ConsolePortBarManager then error('ConsolePort action bars are not loaded') end
    local captured = ns.Capture()
    if not captured.consolePortLayout or #captured.consolePortLayout == 0 then error('No visible ConsolePort controls') end
    local snapshot = {
        bridgeVersion = 1, kind = 'consoleport-sync', exportedAt = captured.exportedAt,
        character = captured.character, modifiers = captured.modifiers,
        consolePortVersion = captured.consolePortVersion, actionPage = captured.actionPage,
        consolePortLayout = captured.consolePortLayout,
    }
    local encoded = ns.Encode(snapshot)
    if #encoded > 262144 then error('ConsolePort snapshot exceeds 256 KiB') end
    return encoded
end

function ns.NewConsolePortSync(api)
    local state = { dirty = true, due = 0 }
    function state:Changed()
        self.dirty = true; self.due = api.now() + 1
    end
    function state:Capture(final)
        if not api.enabled() then api.save(nil); return end
        if api.combat() then
            self.dirty = true
            if final then api.save(nil) end -- Never publish an old page after an unsafe logout.
            return
        end
        local ok, value = pcall(api.capture)
        self.dirty = not ok
        if ok then api.save(value); self.lastError = nil
        else self.lastError = tostring(value); api.save(nil) end
        self.due = api.now() + 5
    end
    function state:Tick()
        if self.dirty and api.now() >= self.due then self:Capture(false) end
    end
    return state
end

if not CreateFrame then return end
local sync = ns.NewConsolePortSync({
    now = GetTime, combat = InCombatLockdown,
    enabled = function() return not ThumbleBridgeDB or ThumbleBridgeDB.autoSync ~= false end,
    capture = ns.ExportConsolePortSync,
    save = function(text)
        ThumbleBridgeDB = ThumbleBridgeDB or {}
        ThumbleBridgeDB.syncText = text
    end,
})
ns.ConsolePortSync = sync
local frame = CreateFrame('Frame')
for _, event in ipairs({ 'PLAYER_LOGIN', 'PLAYER_LOGOUT', 'PLAYER_ENTERING_WORLD', 'UPDATE_BINDINGS',
    'ACTIONBAR_SLOT_CHANGED', 'ACTIONBAR_PAGE_CHANGED', 'UPDATE_SHAPESHIFT_FORM', 'SPELLS_CHANGED',
    'PLAYER_REGEN_ENABLED', 'DISPLAY_SIZE_CHANGED', 'UI_SCALE_CHANGED', 'CVAR_UPDATE' }) do frame:RegisterEvent(event) end
frame:SetScript('OnEvent', function(_, event, name)
    if event == 'PLAYER_LOGOUT' then
        sync:Capture(true)
        if InCombatLockdown() or (ThumbleBridgeDB and ThumbleBridgeDB.autoSync == false) then
            if ThumbleBridgeDB then ThumbleBridgeDB.phoneExportText = nil; ThumbleBridgeDB.phoneSnapshot = nil end
        else
            local ok = pcall(ns.ExportPhoneCharacter)
            if not ok and ThumbleBridgeDB then ThumbleBridgeDB.phoneExportText = nil; ThumbleBridgeDB.phoneSnapshot = nil end
        end
    elseif event ~= 'CVAR_UPDATE' or (type(name) == 'string' and name:lower():match('^gamepad')) then sync:Changed() end
    if event == 'PLAYER_LOGIN' and ConsolePort and ConsolePort.GetData then
        local db = ConsolePort:GetData()
        if db and db.RegisterCallback then
            db:RegisterCallback('OnNewBindings', function() sync:Changed() end, sync)
        end
    end
end)
local elapsed = 0
frame:SetScript('OnUpdate', function(_, delta)
    elapsed = elapsed + delta
    if elapsed >= .5 then elapsed = 0; sync:Tick() end
end)
