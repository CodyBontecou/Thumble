-- Configuration export only. No saved variables, network transport, binding writes,
-- secure button changes, macro bodies, or combat decisions.
local addon = {}
local MAX_BYTES, MAX_ACTIONS = 256 * 1024, 128
local arrayMeta = {}
local function array(t) return setmetatable(t or {}, arrayMeta) end

local function accessible(value)
    return not (issecretvalue and issecretvalue(value))
        and not (canaccessvalue and not canaccessvalue(value))
end

local function text(value, fallback, limit)
    if not accessible(value) or type(value) ~= "string" then return fallback end
    value = value:gsub("[%z\1-\31\127]", " ")
    -- Do not truncate UTF-8 in the middle of a codepoint.
    if #value == 0 or #value > (limit or 128) then return fallback end
    return value
end

local function number(value)
    if accessible(value) and type(value) == "number" and value > 0
        and value < 2147483648 and value == math.floor(value) then return value end
end

local function quote(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
        if c == '"' then return '\\"' end
        if c == '\\' then return '\\\\' end
        return string.format('\\u%04x', string.byte(c))
    end) .. '"'
end

local function json(value)
    if type(value) == "string" then return quote(value) end
    if type(value) == "number" then return string.format("%.0f", value) end
    if type(value) ~= "table" then error("Unsupported export value") end
    local parts = {}
    if getmetatable(value) == arrayMeta then
        for i, item in ipairs(value) do parts[i] = json(item) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local names = {}
    for name in pairs(value) do names[#names + 1] = name end
    table.sort(names)
    for i, name in ipairs(names) do parts[i] = quote(name) .. ":" .. json(value[name]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Read the actual button's resolved slot rather than guessing from page numbers.
local bars = {
    { "ActionButton", "ACTIONBUTTON", "Main bar" },
    { "MultiBarBottomLeftButton", "MULTIACTIONBAR1BUTTON", "Bottom left" },
    { "MultiBarBottomRightButton", "MULTIACTIONBAR2BUTTON", "Bottom right" },
    { "MultiBarRightButton", "MULTIACTIONBAR3BUTTON", "Right bar" },
    { "MultiBarLeftButton", "MULTIACTIONBAR4BUTTON", "Left bar" },
    { "MultiBar5Button", "MULTIACTIONBAR5BUTTON", "Bar 5" },
    { "MultiBar6Button", "MULTIACTIONBAR6BUTTON", "Bar 6" },
    { "MultiBar7Button", "MULTIACTIONBAR7BUTTON", "Bar 7" },
}
local utilities = {
    { "MOVEFORWARD", "Move forward" }, { "MOVEBACKWARD", "Move backward" },
    { "STRAFELEFT", "Strafe left" }, { "STRAFERIGHT", "Strafe right" },
    { "JUMP", "Jump" }, { "TARGETNEARESTENEMY", "Target nearest enemy" },
    { "TARGETPREVIOUSENEMY", "Target previous enemy" }, { "TARGETSELF", "Target self" },
    { "INTERACTTARGET", "Interact" }, { "TOGGLEWORLDMAP", "World map" },
    { "OPENALLBAGS", "Bags" }, { "TOGGLECHARACTER0", "Character" },
}

local function keysFor(command)
    local keys = array()
    local candidates = { GetBindingKey(command) }
    local overridden = false
    for _, candidate in ipairs(candidates) do
        local key = text(candidate, nil, 64)
        if key then
            -- Respect override bindings: a key must still activate this command.
            local effective = GetBindingAction(key, true)
            if accessible(effective) and effective == command then
                keys[#keys + 1] = key
            else overridden = true end
        end
    end
    return keys, overridden
end

local function actionLabel(kind, id, slot, fallback)
    if kind == "spell" and id then
        if C_Spell and C_Spell.GetSpellName then return text(C_Spell.GetSpellName(id), fallback) end
        if GetSpellInfo then return text(GetSpellInfo(id), fallback) end
    elseif kind == "item" and id then
        if C_Item and C_Item.GetItemNameByID then return text(C_Item.GetItemNameByID(id), fallback) end
        if GetItemInfo then return text(GetItemInfo(id), fallback) end
    elseif kind == "macro" and id and GetMacroInfo then
        return text(GetMacroInfo(id), fallback) -- Name only; never export macro bodies.
    end
    if GetActionText then return text(GetActionText(slot), fallback) end
    return fallback
end

function addon.snapshot(options)
    if InCombatLockdown() or (UnitAffectingCombat and UnitAffectingCombat("player")) then
        error("Leave combat before exporting your bindings.")
    end
    if not GetBindingKey or not GetBindingAction or not GetActionInfo or not UnitGUID then
        error("This client is missing required binding/action APIs.")
    end
    local version, build, _, interface = GetBuildInfo()
    if interface ~= 16001 then error("This version supports WoW Forever interface 16001 only.") end
    local characterID = text(UnitGUID("player"), nil, 96)
    local characterName = text(UnitName("player"), nil, 96)
    local realm = text(GetRealmName(), nil, 96)
    local _, classToken = UnitClass("player")
    classToken = text(classToken, nil, 32)
    if not characterID or not characterName or not realm or not classToken then
        error("Character information is unavailable. Try again after login.")
    end
    local actions, warnings = array(), array()
    warnings[1] = "Default Blizzard bars only. Current page/form labels are a snapshot; keyboard commands can change actions with game context."
    warnings[2] = "Custom action bars, click-casting, native gamepad bindings, pet bars, and override/vehicle bars are not imported."
    local foundFrames = 0
    for barIndex, bar in ipairs(bars) do
        if (barIndex == 1 and options.main) or (barIndex > 1 and options.extra) then
            for i = 1, 12 do
                local button = _G[bar[1] .. i]
                if button then
                    foundFrames = foundFrames + 1
                    local slot = number(button.action)
                    if slot then
                        local kind, id = GetActionInfo(slot)
                        if accessible(kind) and type(kind) == "string" and kind ~= "" then
                            id = number(id)
                            local command = bar[2] .. i
                            local keys, overridden = keysFor(command)
                            local texture = C_ActionBar and C_ActionBar.GetActionTexture or GetActionTexture
                            local icon = texture and number(texture(slot))
                            actions[#actions + 1] = {
                                command = command, label = actionLabel(kind, id, slot, bar[3] .. " " .. i),
                                keys = keys, slot = slot, kind = kind, actionID = id, iconFileID = icon,
                                unavailableReason = (#keys == 0 and overridden) and "Binding overridden by another UI/addon" or nil,
                            }
                        end
                    end
                end
            end
        end
    end
    if (options.main or options.extra) and foundFrames == 0 then
        error("Blizzard action buttons were not found. Custom action bars need a separate adapter.")
    end
    if options.utility then
        for _, utility in ipairs(utilities) do
            local keys, overridden = keysFor(utility[1])
            actions[#actions + 1] = { command = utility[1], label = utility[2], keys = keys, kind = "utility",
                unavailableReason = (#keys == 0 and overridden) and "Binding overridden by another UI/addon" or nil }
        end
    end
    if #actions == 0 then error("No actions found. Select a populated bar or utility controls.") end
    if #actions > MAX_ACTIONS then error("Too many actions. Select fewer bars.") end
    local result = { schema = "thumble.wow-link", version = 1,
        client = { flavor = "forever", version = tostring(version), build = tostring(build), interface = interface },
        character = { id = characterID, name = characterName, realm = realm, classTag = classToken },
        exportedAt = time(), actions = actions, warnings = warnings }
    local encoded = "THUMBLELINK1:" .. json(result)
    if #encoded > MAX_BYTES then error("Export is too large. Select fewer bars.") end
    return encoded, #actions
end

local window
local function showWindow()
    if not window then
        window = CreateFrame("Frame", "ThumbleLinkWindow", UIParent, "BasicFrameTemplateWithInset")
        window:SetSize(620, 440)
        window:SetPoint("CENTER")
        window:SetClampedToScreen(true)
        window.TitleText:SetText("Thumble Link")
        table.insert(UISpecialFrames, "ThumbleLinkWindow")
        local instructions = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        instructions:SetPoint("TOPLEFT", 18, -42)
        instructions:SetWidth(580)
        instructions:SetJustifyH("LEFT")
        instructions:SetText("Select what to export, then copy the code into Thumble on your Mac. Existing WoW keybinds are kept. Export again after changing them.")
        local function checkbox(title, x, checked)
            local box = CreateFrame("CheckButton", nil, window, "UICheckButtonTemplate")
            box:SetPoint("TOPLEFT", x, -90)
            local label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            label:SetPoint("LEFT", box, "RIGHT", 0, 0)
            label:SetText(title)
            box:SetChecked(checked)
            return box
        end
        window.main = checkbox("Main bar", 18, true)
        window.extra = checkbox("Extra bars", 180, false)
        window.utility = checkbox("Utility", 350, true)
        local scroll = CreateFrame("ScrollFrame", nil, window, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 20, -138)
        scroll:SetPoint("BOTTOMRIGHT", -40, 76)
        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(548)
        edit:SetAutoFocus(false)
        edit:SetMaxLetters(MAX_BYTES)
        edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        scroll:SetScrollChild(edit)
        window.edit = edit
        window.status = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        window.status:SetPoint("BOTTOMLEFT", 20, 48)
        window.status:SetWidth(580)
        window.status:SetJustifyH("LEFT")
        local export = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
        export:SetSize(170, 26)
        export:SetPoint("BOTTOMLEFT", 18, 14)
        export:SetText("Generate export")
        export:SetScript("OnClick", function()
            -- Clear a previous result first so a failed export cannot be mistaken for fresh data.
            edit:SetText("")
            local ok, result, count = pcall(addon.snapshot, { main = window.main:GetChecked(),
                extra = window.extra:GetChecked(), utility = window.utility:GetChecked() })
            if not ok then window.status:SetText("Export failed: " .. tostring(result)); return end
            edit:SetText(result)
            edit:SetFocus()
            edit:HighlightText()
            window.status:SetText(count .. " actions. Press Cmd+C (Mac) or Ctrl+C, then paste into Thumble Link.")
        end)
    end
    window:Show()
end

SLASH_THUMBLELINK1 = "/thumble"
SlashCmdList.THUMBLELINK = showWindow

-- The chunk return is ignored by WoW and lets the mocked Lua tests exercise the exporter.
return addon
