local _, ns = ...
ns.Buttons = { 'PAD1', 'PAD2', 'PAD3', 'PAD4', 'PADLSHOULDER', 'PADRSHOULDER', 'PADBACK', 'PADFORWARD', 'PADLSTICK', 'PADRSTICK', 'PADDUP', 'PADDDOWN', 'PADDLEFT', 'PADDRIGHT', 'PADSYSTEM', 'PADLTRIGGER', 'PADRTRIGGER' }
ns.Utilities = { JUMP = true, OPENCHAT = true, TARGETNEARESTENEMY = true, TARGETPREVIOUSENEMY = true, TARGETSELF = true, OPENALLBAGS = true, TOGGLEWORLDMAP = true, TOGGLECHARACTER0 = true, TOGGLEGAMEMENU = true, INTERACTTARGET = true }
local function text(v, max) return type(v) == 'string' and #v > 0 and #v <= max and not v:find('[%z\1-\31\127|]') end
local function integer(v) return type(v) == 'number' and v >= 1 and v < 2147483648 and v == math.floor(v) end
local function keys(t, allowed)
    if type(t) ~= 'table' or t == ns.Null then return false end
    for k in pairs(t) do if not allowed[k] then return false end end
    return true
end
local function list(t, max)
    if type(t) ~= 'table' or #t < 1 or #t > max then return false end
    for k in pairs(t) do if type(k) ~= 'number' or k < 1 or k > #t or k ~= math.floor(k) then return false end end
    return true
end
local function index(items, field)
    local result = {}; for _, item in ipairs(items or {}) do result[item[field]] = item end; return result
end
function ns.Review(plan, baseline, live)
    if not keys(plan, { bridgeVersion = true, kind = true, id = true, snapshotId = true, characterGuid = true, bindingSet = true, profile = true, changes = true })
        or plan.bridgeVersion ~= 1 or plan.kind ~= 'binding-plan' or not text(plan.id, 80)
        or not text(plan.snapshotId, 128) or not text(plan.characterGuid, 128)
        or not keys(plan.profile, { id = true, revision = true, name = true }) or not text(plan.profile.id, 64)
        or not integer(plan.profile.revision) or not text(plan.profile.name, 320) or not list(plan.changes, 32) then error('Invalid binding plan') end
    if not baseline or baseline.snapshotId ~= plan.snapshotId then error('Export your character again; this plan uses a different snapshot') end
    if live.character.guid ~= plan.characterGuid or baseline.character.guid ~= plan.characterGuid then error('Plan belongs to a different character') end
    for _, field in ipairs({ 'classId', 'specId' }) do
        if baseline.character[field] ~= live.character[field] then error('Character specialization changed; export again') end
    end
    if live.build ~= baseline.build or live.interface ~= baseline.interface or live.actionPage ~= baseline.actionPage then error('Game build or action page changed; export again') end
    if live.bindingSet ~= plan.bindingSet or baseline.bindingSet ~= plan.bindingSet or (plan.bindingSet ~= 1 and plan.bindingSet ~= 2) then error('Active binding scope changed; export again') end
    if ns.Encode(baseline.modifiers) ~= ns.Encode(live.modifiers) or ns.Encode(baseline.reserved) ~= ns.Encode(live.reserved) then error('Gamepad modifiers or cursor buttons changed; export again') end
    if baseline.consolePortVersion ~= live.consolePortVersion then error('ConsolePort version changed; export again') end
    local function slots(snapshot)
        local result = ns.Array()
        for _, action in ipairs(snapshot.actions or {}) do result[#result + 1] = { slot = action.slot, type = action.type, id = action.id, binding = action.binding } end
        return ns.Encode(result)
    end
    if slots(baseline) ~= slots(live) then error('Action slots changed since export; export again') end
    local current, exported, spells = index(live.bindings, 'key'), index(baseline.bindings, 'key'), index(live.spells, 'id')
    local allowed = {}; for _, key in ipairs(ns.Buttons) do allowed[key] = true end
    local seenKeys, seenControls, rows = {}, {}, {}
    for _, change in ipairs(plan.changes) do
        if not keys(change, { controlId = true, label = true, key = true, expectedBase = true, expectedEffective = true, spellId = true, action = true })
            or not text(change.controlId, 80) or not text(change.label, 320) or not allowed[change.key]
            or type(change.expectedBase) ~= 'string' or type(change.expectedEffective) ~= 'string'
            or #change.expectedBase > 512 or #change.expectedEffective > 512
            or seenKeys[change.key] or seenControls[change.controlId] then error('Invalid or duplicate binding change') end
        seenKeys[change.key] = true; seenControls[change.controlId] = true
        if live.reserved[change.key] then error(change.key .. ' is reserved: ' .. live.reserved[change.key]) end
        local now, before = current[change.key], exported[change.key]
        if not now or not before or before.base ~= change.expectedBase or before.effective ~= change.expectedEffective
            or now.base ~= before.base or now.effective ~= before.effective then error(change.key .. ' changed since export; export again') end
        if now.base ~= now.effective and not (now.consolePortProxy == true and before.consolePortProxy == true) then error(change.key .. ' has an unrecognized override binding; configure it in ConsolePort first') end
        local command, description
        if change.spellId ~= nil and change.action == nil then
            local spell = spells[change.spellId]
            if not integer(change.spellId) or not spell or spell.passive or not text(spell.name, 256) then error('Spell is unavailable or passive: ' .. tostring(change.spellId)) end
            command = 'SPELL ' .. spell.name; description = spell.name .. ' (spell ' .. spell.id .. ')'
        elseif change.spellId == nil and ns.Utilities[change.action] then
            command = change.action; description = change.action
        else error('Only learned spells or supported utility actions can be bound') end
        rows[#rows + 1] = { key = change.key, controlId = change.controlId, label = change.label, before = before.base, beforeEffective = before.effective, consolePortProxy = now.consolePortProxy == true, after = command, description = description }
    end
    return rows
end
-- No timer, event handler or imported data can apply a plan. UI OnClick calls this.
function ns.Apply(plan, baseline, env)
    if env.inCombat() then error('Leave combat and click Apply again; nothing is queued') end
    local live = env.capture()
    local rows = ns.Review(plan, baseline, live)
    local before = env.allBindings()
    local function restore()
        local after = env.allBindings(); local errors = {}
        for key in pairs(after) do if before[key] ~= after[key] and not env.set(key, before[key]) then errors[#errors + 1] = key end end
        for key, command in pairs(before) do if after[key] ~= command and not env.set(key, command) then errors[#errors + 1] = key end end
        if not env.save(plan.bindingSet) then errors[#errors + 1] = 'save' end
        return #errors == 0
    end
    local ok, message = pcall(function()
        for _, row in ipairs(rows) do
            if env.inCombat() then error('Combat started; apply stopped') end
            if not env.set(row.key, row.after) or env.get(row.key, false) ~= row.after then error('Client rejected ' .. row.key) end
            local effective = env.get(row.key, true)
            if effective ~= row.after and effective ~= row.beforeEffective then
                error('Client rejected effective route for ' .. row.key .. ': expected ' .. row.after .. ', observed ' .. effective)
            end
            -- ConsolePort debounces its override refresh. ExportResult verifies the
            -- effective route later; a pending result cannot confirm a phone label.
            -- An unchanged, preflight-validated utility route can also be stale.
        end
        local planned = {}; for _, row in ipairs(rows) do planned[row.key] = true end
        local after = env.allBindings()
        for key, command in pairs(before) do if not planned[key] and after[key] ~= command then error('Client changed an unrelated binding: ' .. key) end end
        for key, command in pairs(after) do if not planned[key] and before[key] ~= command then error('Client changed an unrelated binding: ' .. key) end end
        if not env.save(plan.bindingSet) then error('Client could not save bindings') end
    end)
    if not ok then
        local restored = restore()
        error(tostring(message) .. (restored and '; previous bindings restored' or '; rollback incomplete: inspect bindings before playing'))
    end
    return rows, before
end
