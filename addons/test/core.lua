local fixturePath, planPath, addonPath = ...
local ns = {}
assert(loadfile(addonPath .. '/Codec.lua'))('ThumbleBridge', ns)
assert(loadfile(addonPath .. '/Core.lua'))('ThumbleBridge', ns)
local function read(path) local f = assert(io.open(path, 'rb')); local s = f:read('*a'); f:close(); return s end
local snapshot = ns.Decode(read(fixturePath))
local plan = ns.Decode(read(planPath))
local function copy(t) return ns.Decode(ns.Encode(t)) end
local function equal(a, b) assert(ns.Encode(a) == ns.Encode(b), 'Values differ') end
local count = 0
local function test(name, fn) fn(); count = count + 1; print('PASS ' .. name) end
local function rejects(fn, pattern) local ok, error = pcall(fn); assert(not ok, 'Expected rejection'); if pattern then assert(tostring(error):find(pattern), tostring(error)) end end
local function environment()
    local live = copy(snapshot)
    local map = { ['1'] = 'ACTIONBUTTON1', ['SPACE'] = 'JUMP', PAD3 = 'ACTIONBUTTON3' }
    local writes, saves, combat = 0, 0, false
    local function capture()
        local result = copy(live)
        for _, row in ipairs(result.bindings) do row.base = map[row.key] or ''; row.effective = map[row.key] or '' end
        return result
    end
    local env = {
        inCombat = function() return combat end,
        capture = capture,
        allBindings = function() return copy(map) end,
        get = function(key) return map[key] or '' end,
        set = function(key, command) writes = writes + 1; map[key] = command; return true end,
        save = function() saves = saves + 1; return true end,
    }
    return env, map, live, function() return writes, saves end, function(v) combat = v end
end

test('JSON codec round-trips UTF-8, booleans, arrays, null and escaped strings', function()
    local value = ns.Decode('{"text":"Crème \\uD83D\\uDE80","flag":false,"n":1.25e2,"items":[null,true,"quote\\\""]}')
    equal(ns.Decode(ns.Encode(value)), value)
    assert(value.flag == false and value.n == 125 and value.items[1] == ns.Null)
end)
test('JSON decoder rejects duplicate keys, code, trailing data and invalid numbers', function()
    for _, text in ipairs({ '{"x":1,"x":2}', 'return os.execute("echo bad")', '{} trailing', '[01]', '[1.]', '[1e]', '"\\uD800"', '[1,]', '{"a":null,"a":3}', string.rep('[', 26) }) do rejects(function() ns.Decode(text) end) end
end)
test('JS-generated plan passes Lua review and matches the intended learned spells', function()
    local rows = ns.Review(plan, snapshot, copy(snapshot))
    assert(#rows == 2 and rows[1].key == 'PAD3' and rows[1].after == 'SPELL Charge' and rows[2].after == 'SPELL Execute')
end)
test('review rejects different character, specialization, binding scope, page and modifiers', function()
    for _, mutate in ipairs({
        function(t) t.character.guid = 'Other' end,
        function(t) t.character.specId = 1 end,
        function(t) t.bindingSet = 1 end,
        function(t) t.actionPage = 2 end,
        function(t) t.modifiers.GamePadEmulateShift = 'PAD1' end,
        function(t) t.actions[1].id = 78 end,
    }) do local live = copy(snapshot); mutate(live); rejects(function() ns.Review(plan, snapshot, live) end) end
end)
test('review rejects stale, overridden, reserved, unknown and passive bindings', function()
    local live = copy(snapshot); live.bindings[3].base = 'JUMP'; rejects(function() ns.Review(plan, snapshot, live) end)
    live = copy(snapshot); live.bindings[3].effective = 'CLICK Override:LeftButton'; rejects(function() ns.Review(plan, snapshot, live) end)
    live = copy(snapshot); live.reserved.PAD3 = 'modifier'; rejects(function() ns.Review(plan, snapshot, live) end)
    for _, id in ipairs({99999,20572}) do local p = copy(plan); p.changes[1].spellId = id; rejects(function() ns.Review(p, snapshot, copy(snapshot)) end) end
end)
test('review rejects keyboard, macro, duplicate and executable plan fields', function()
    for _, mutate in ipairs({
        function(p) p.changes[1].key = 'SPACE' end,
        function(p) p.changes[1].spellId = nil; p.changes[1].action = 'MACRO /cast Charge' end,
        function(p) p.changes[2].key = 'PAD3' end,
        function(p) p.execute = 'CastSpellByName' end,
        function(p) p.changes[1].label = '|cff00ff00hidden' end,
    }) do local p = copy(plan); mutate(p); rejects(function() ns.Review(p, snapshot, copy(snapshot)) end) end
end)
test('combat apply performs zero writes and never queues work', function()
    local env, _, _, stats, combat = environment(); combat(true)
    rejects(function() ns.Apply(plan, snapshot, env) end, 'Leave combat')
    assert(stats() == 0); combat(false); assert(stats() == 0)
end)
test('apply rechecks the live state and preserves keyboard bindings', function()
    local env, map, _, stats = environment()
    local rows, before = ns.Apply(plan, snapshot, env)
    assert(#rows == 2 and map.PAD3 == 'SPELL Charge' and map.PAD4 == 'SPELL Execute')
    assert(map.SPACE == 'JUMP' and map['1'] == 'ACTIONBUTTON1' and before.PAD3 == 'ACTIONBUTTON3')
    local writes, saves = stats(); assert(writes == 2 and saves == 1)
end)
test('a stale plan performs zero writes at apply time', function()
    local env, map, _, stats = environment(); map.PAD3 = 'JUMP'
    rejects(function() ns.Apply(plan, snapshot, env) end, 'changed since export'); assert(stats() == 0)
end)
test('a client rejection rolls back earlier mutations', function()
    local env, map = environment(); local native = env.set
    env.set = function(key, command) if key == 'PAD4' and command == 'SPELL Execute' then return false end; return native(key, command) end
    rejects(function() ns.Apply(plan, snapshot, env) end, 'previous bindings restored')
    assert(map.PAD3 == 'ACTIONBUTTON3' and map.PAD4 == nil and map.SPACE == 'JUMP')
end)
test('unexpected unrelated changes are detected and rolled back', function()
    local env, map = environment(); local native = env.set
    env.set = function(key, command) local result = native(key, command); if command == 'SPELL Charge' then map.SPACE = nil end; return result end
    rejects(function() ns.Apply(plan, snapshot, env) end, 'unrelated binding')
    assert(map.SPACE == 'JUMP' and map.PAD3 == 'ACTIONBUTTON3' and map.PAD4 == nil)
end)
test('save failure rolls back mutations and reports rollback failure when persistence fails', function()
    local env, map = environment(); env.save = function() return false end
    rejects(function() ns.Apply(plan, snapshot, env) end, 'rollback incomplete')
    assert(map.PAD3 == 'ACTIONBUTTON3' and map.PAD4 == nil)
end)
test('ConsolePort proxy refresh may be pending but unrelated overrides still fail', function()
    local baseline = copy(snapshot)
    baseline.bindings[3].effective = 'CLICK CPB_PAD3:ControllerInput'; baseline.bindings[3].consolePortProxy = true
    local candidate = copy(plan); candidate.changes[1].expectedEffective = baseline.bindings[3].effective
    local env, map = environment()
    env.capture = function() return copy(baseline) end
    env.get = function(key, override) if key == 'PAD3' and override then return 'CLICK CPB_PAD3:ControllerInput' end; return map[key] or '' end
    local rows = ns.Apply(candidate, baseline, env)
    assert(rows[1].consolePortProxy and map.PAD3 == 'SPELL Charge')
    baseline.bindings[3].consolePortProxy = false
    rejects(function() ns.Review(candidate, baseline, copy(baseline)) end, 'unrecognized override')
end)
test('an ordinary ConsolePort utility route can remain pending until refresh', function()
    local baseline = copy(snapshot)
    baseline.bindings[3].base = 'OPENALLBAGS'; baseline.bindings[3].effective = 'OPENALLBAGS'
    local candidate = copy(plan); candidate.changes = { { controlId = 'chat', label = 'Chat', key = 'PAD3', expectedBase = 'OPENALLBAGS', expectedEffective = 'OPENALLBAGS', action = 'OPENCHAT' } }
    local env, map = environment(); map.PAD3 = 'OPENALLBAGS'
    env.capture = function() return copy(baseline) end
    env.get = function(key, override) if key == 'PAD3' and override then return 'OPENALLBAGS' end; return map[key] or '' end
    ns.Apply(candidate, baseline, env)
    assert(map.PAD3 == 'OPENCHAT', 'Expected saved base binding while the old route refreshes')
    env.get = function(key, override) if key == 'PAD3' and override then return 'CLICK Unknown:LeftButton' end; return map[key] or '' end
    map.PAD3 = 'OPENALLBAGS'
    rejects(function() ns.Apply(candidate, baseline, env) end, 'Client rejected effective route')
    assert(map.PAD3 == 'OPENALLBAGS', 'Unknown effective routes must roll back')
end)
print('PASS ' .. count .. ' Lua 5.1 addon core tests')
