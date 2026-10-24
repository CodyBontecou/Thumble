local _, ns = ...

-- macOS can report removal without discovering the replacement HID device.
-- Only refresh configuration: never synthesize a gamepad or gameplay action.
function ns.NewGamepadDiscovery(api)
    local state = { refreshes = 0, nextAttempt = 0, quietSince = nil, retryUntil = 0 }
    function state:Disconnected()
        if api.now() < self.nextAttempt then return end -- Ignore our own rescan events.
        self.retryUntil = api.now() + 30
        self.nextAttempt = api.now() + 2
        self.quietSince = nil
    end
    function state:Tick()
        local now = api.now()
        if not api.allowed() then self.quietSince = nil; return end
        if api.combat() then
            if self.retryUntil > now then self.retryUntil = now + 30 end
            self.quietSince = nil; return
        end
        local ok, devices = pcall(api.devices)
        if not ok or type(devices) ~= 'table' then self.quietSince = nil; return end
        local count = 0
        for _, device in ipairs(devices) do
            count = count + 1
            for _, pressed in pairs(device.buttons or {}) do
                if pressed then self.retryUntil = 0; self.quietSince = nil; return end
            end
            for _, value in pairs(device.axes or {}) do
                if math.abs(value) > 0.1 then self.retryUntil = 0; self.quietSince = nil; return end
            end
            for _, stick in pairs(device.sticks or {}) do
                if (stick.len or 0) > 0.1 or math.abs(stick.x or 0) > 0.1 or math.abs(stick.y or 0) > 0.1 then self.retryUntil = 0; self.quietSince = nil; return end
            end
        end
        if now >= self.retryUntil and count > 0 then self.retryUntil = 0; self.quietSince = nil; return end
        self.quietSince = self.quietSince or now
        if now < self.nextAttempt or now - self.quietSince < 2 then return end
        -- Set the guard before SetCVar, whose events may fire synchronously.
        self.nextAttempt = now + 5; self.quietSince = nil
        local refreshed, err = pcall(api.refresh)
        if refreshed then self.refreshes = self.refreshes + 1; self.lastRefresh = now
        else self.lastError = tostring(err); self.nextAttempt = math.huge end
    end
    return state
end

if not CreateFrame then return end -- Pure policy is also exercised outside WoW.
local function allowed()
    return IsMacClient and IsMacClient() and ConsolePort ~= nil
        and ThumbleBridgeDB and ThumbleBridgeDB.autoDiscovery ~= false
        and GetCVar('GamePadEnable') == '1'
        and C_GamePad and C_GamePad.GetAllDeviceIDs and C_GamePad.GetDeviceMappedState
end
local recovery = ns.NewGamepadDiscovery({
    now = GetTime, allowed = allowed, combat = InCombatLockdown,
    devices = function()
        local devices = {}
        for _, id in ipairs(C_GamePad.GetAllDeviceIDs()) do
            local mapped = C_GamePad.GetDeviceMappedState(id)
            if mapped then devices[#devices + 1] = mapped end
        end
        return devices
    end,
    refresh = function()
        SetCVar('GamePadEnable', 0)
        -- Always attempt restoration, even if a client rejects configuration.
        local ok, err = pcall(SetCVar, 'GamePadEnable', 1)
        if not ok then pcall(SetCVar, 'GamePadEnable', 1); error(err) end
    end,
})
ns.DiscoveryStatus = recovery
local watcher = CreateFrame('Frame')
watcher:RegisterEvent('PLAYER_LOGIN')
watcher:RegisterEvent('GAME_PAD_DISCONNECTED')
watcher:SetScript('OnEvent', function(_, event)
    if event == 'PLAYER_LOGIN' then ThumbleBridgeDB = ThumbleBridgeDB or {}
    else recovery:Disconnected() end
end)
local elapsed = 0
watcher:SetScript('OnUpdate', function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 1 then return end
    elapsed = 0
    recovery:Tick()
end)
