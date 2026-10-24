local addonPath = ...
local ns = {}
assert(loadfile(addonPath .. '/Discovery.lua'))('ThumbleBridge', ns)
local now, allowed, combat, devices, refreshes = 0, true, false, {}, 0
local failure, readFailure, recovery
local api = {
    now = function() return now end,
    allowed = function() return allowed end,
    combat = function() return combat end,
    devices = function() if readFailure then error('unavailable') end; return devices end,
    refresh = function()
        refreshes = refreshes + 1
        recovery:Disconnected() -- Same synchronous events as SetCVar.
        if failure then error('restricted') end
    end,
}
local function reset()
    now, allowed, combat, devices, refreshes = 0, true, false, {}, 0
    failure, readFailure = false, false
    recovery = ns.NewGamepadDiscovery(api)
end
local function tick(time) now = time; recovery:Tick() end
reset(); tick(0); tick(1); assert(refreshes == 0); tick(2); assert(refreshes == 1)
tick(3); tick(6); assert(refreshes == 1); tick(7); assert(refreshes == 2)
devices = {{buttons = {}, axes = {}, sticks = {}}}; tick(20); tick(30); assert(refreshes == 2)
print('PASS missing-controller discovery retries are rate limited and stop once a mapped device appears')

reset(); devices = {{buttons = {}, axes = {0}, sticks = {}}}; tick(0)
recovery:Disconnected(); tick(1); tick(2); assert(refreshes == 0); tick(3); assert(refreshes == 1)
assert(recovery.retryUntil == 30); tick(4); tick(8); assert(refreshes == 2)
tick(31); assert(refreshes == 2)
print('PASS stale entries allow bounded retries; rescan events never extend the window')

for _, busy in ipairs({{buttons = {true}}, {axes = {0.8}}, {sticks = {{x = 0.8, y = 0, len = 0.8}}}}) do
    reset(); devices = {busy}; recovery:Disconnected(); tick(3); tick(10); assert(refreshes == 0)
    devices = {{buttons = {}, axes = {0}, sticks = {}}}; tick(11); tick(13); assert(refreshes == 0)
end
print('PASS working buttons, triggers and sticks cancel pending recovery without interrupting input')

reset(); combat = true; recovery:Disconnected(); tick(3); tick(20); assert(refreshes == 0)
tick(40); tick(60); combat = false; tick(61); tick(63); assert(refreshes == 1)
reset(); allowed = false; tick(0); tick(30); assert(refreshes == 0)
allowed = true; tick(31); tick(33); assert(refreshes == 1)
print('PASS combat, disabled gamepad support, opt-out and unsupported platform/API gates defer recovery')

reset(); readFailure = true; tick(0); tick(20); assert(refreshes == 0)
reset(); failure = true; tick(0); tick(2); tick(100); assert(refreshes == 1 and recovery.lastError)
print('PASS unreadable device state fails closed and a rejected refresh stops retries')

local scripts, cvar, mac, calls = {}, '1', true, {}
CreateFrame = function() return {
    RegisterEvent = function() end,
    SetScript = function(_, name, handler) scripts[name] = handler end,
} end
IsMacClient = function() return mac end
ConsolePort, ThumbleBridgeDB = {}, {}
GetTime = function() return now end
InCombatLockdown = function() return false end
GetCVar = function() return cvar end
C_GamePad = { GetAllDeviceIDs = function() return {1} end, GetDeviceMappedState = function() return nil end }
SetCVar = function(name, value)
    assert(name == 'GamePadEnable'); calls[#calls + 1] = value; cvar = tostring(value)
    scripts.OnEvent(nil, 'GAME_PAD_DISCONNECTED')
end
now = 0; assert(loadfile(addonPath .. '/Discovery.lua'))('ThumbleBridge', ns)
scripts.OnEvent(nil, 'PLAYER_LOGIN')
local function update(time) now = time; scripts.OnUpdate(nil, 1) end
mac = false; update(0); update(10); assert(#calls == 0)
mac = true; ConsolePort = nil; update(11); update(20); assert(#calls == 0)
ConsolePort = {}; ThumbleBridgeDB.autoDiscovery = false; update(21); update(30); assert(#calls == 0)
ThumbleBridgeDB.autoDiscovery = true; cvar = '0'; update(31); update(40); assert(#calls == 0)
cvar = '1'; update(41); update(43); assert(#calls == 2 and calls[1] == 0 and calls[2] == 1 and cvar == '1')
assert(ns.DiscoveryStatus.refreshes == 1)
print('PASS runtime respects platform, ConsolePort, saved opt-out and disabled CVar; stale IDs with nil mapped state recover')
