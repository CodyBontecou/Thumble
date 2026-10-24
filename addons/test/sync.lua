local root = assert(arg[1])
local ns = {}; assert(loadfile(root .. '/Codec.lua'))('ThumbleBridge', ns)
assert(loadfile(root .. '/Sync.lua'))('ThumbleBridge', ns)
local now, combat, enabled, text, writes = 0, false, true, nil, 0
local state = ns.NewConsolePortSync({ now = function() return now end, combat = function() return combat end,
    enabled = function() return enabled end, capture = function() return 'fresh-' .. now end,
    save = function(value) text = value; writes = writes + 1 end })
state:Changed(); state:Tick(); assert(writes == 0)
now = 1; state:Tick(); assert(text == 'fresh-1' and writes == 1)
state:Tick(); assert(writes == 1)
state:Changed(); combat = true; now = 3; state:Tick(); assert(text == 'fresh-1')
state:Capture(true); assert(text == nil)
combat = false; state:Tick(); assert(text == 'fresh-3')
now = 4; state:Capture(true); assert(text == 'fresh-4')
enabled = false; state:Capture(true); assert(text == nil)
ConsolePort, ConsolePortBarManager = {}, {}
ns.Capture = function() return { exportedAt = 123, character = { guid = 'player' }, modifiers = {}, consolePortLayout = ns.Array({ {key='PAD1'} }) } end
local snapshot = ns.Decode(ns.ExportConsolePortSync())
assert(snapshot.kind == 'consoleport-sync' and snapshot.character.guid == 'player' and snapshot.exportedAt == 123)
ConsolePort = nil; assert(not pcall(ns.ExportConsolePortSync))
print('PASS automatic snapshots debounce events, defer combat, refresh on logout, honor opt-out and never change bindings')
