local _, ns = ...
local frame, editor, review, reviewContent, status, apply, staged
local function display(value) return tostring(value or ''):gsub('|', '||') end
local function errorText(message) return display(tostring(message):gsub('^.-:%d+: ', '')) end
local function message(text) if status then status:SetText(text) else print('Thumble: ' .. text) end end
local function setReview(text) review:SetText(text); if reviewContent then reviewContent:SetHeight(math.max(220, review:GetStringHeight() + 12)) end end
local function run(action)
    local ok, result = pcall(action)
    if not ok then message('|cffffa0a0' .. errorText(result) .. '|r') end
end
local function put(text)
    staged = nil; apply:Disable(); editor:SetText(text); editor:SetFocus(); editor:HighlightText()
end
local function button(parent, text, width, click)
    local b = CreateFrame('Button', nil, parent, 'UIPanelButtonTemplate')
    b:SetSize(width, 26); b:SetText(text); b:SetScript('OnClick', function() run(click) end)
    return b
end
local function open()
    if frame then frame:Show(); return end
    frame = CreateFrame('Frame', 'ThumbleBridgeWindow', UIParent, 'BasicFrameTemplateWithInset')
    frame:SetSize(880, 620); frame:SetPoint('CENTER'); frame:SetFrameStrata('DIALOG'); frame:SetClampedToScreen(true)
    frame:SetMovable(true); frame:EnableMouse(true); frame:RegisterForDrag('LeftButton')
    frame:SetScript('OnDragStart', frame.StartMoving); frame:SetScript('OnDragStop', frame.StopMovingOrSizing)
    frame.TitleText:SetText('Thumble — review your controller bindings')
    UISpecialFrames[#UISpecialFrames + 1] = 'ThumbleBridgeWindow'
    local intro = frame:CreateFontString(nil, 'OVERLAY', 'GameFontHighlight')
    intro:SetPoint('TOPLEFT', 18, -40); intro:SetPoint('TOPRIGHT', -18, -40); intro:SetJustifyH('LEFT')
    intro:SetText('1. Export and copy your character to the agent.  2. Paste its plan below and Review.  3. Apply only after checking each change.')
    local export = button(frame, 'Export character', 150, function()
        put(ns.ExportCharacter()); setReview('Character exported. Copy the selected JSON to your agent, then paste its proposed plan here.')
        message('Exported character data. Nothing was changed.')
    end)
    export:SetPoint('TOPLEFT', 18, -78)
    local reviewButton = button(frame, 'Review pasted plan', 165, function()
        staged = nil; apply:Disable()
        local plan, rows = ns.ReviewText(editor:GetText())
        local lines = { 'Profile: ' .. display(plan.profile.name) .. '  (saved revision ' .. plan.profile.revision .. ')',
            plan.bindingSet == 1 and '|cffffd080Scope: ACCOUNT — these bindings affect other characters using this account binding set.|r' or 'Scope: this character',
            'Spell bindings use the client’s spell name. Action bars and existing keyboard bindings are preserved.', '' }
        for i, row in ipairs(rows) do
            lines[#lines + 1] = i .. '. ' .. display(row.label) .. '  [' .. display(row.controlId) .. ' / ' .. row.key .. ']'
            lines[#lines + 1] = '    ' .. (row.before == '' and 'Unbound' or display(row.before)) .. '  →  ' .. display(row.description)
            lines[#lines + 1] = ''
        end
        setReview(table.concat(lines, '\n')); staged = plan; apply:Enable(); editor:ClearFocus()
        message('Review ready. Apply checks the character, scope, spells and existing bindings again.')
    end)
    reviewButton:SetPoint('LEFT', export, 'RIGHT', 10, 0)
    local receipt = button(frame, 'Export result', 140, function()
        if not ThumbleBridgeDB or not ThumbleBridgeDB.receipt then error('No applied plan yet') end
        put(ns.ExportResult()); message('Copy this result to the agent to confirm the applied bindings. It does not activate the phone layout.')
    end)
    receipt:SetPoint('LEFT', reviewButton, 'RIGHT', 10, 0)
    local restore = button(frame, 'Restore last bindings', 165, function()
        ns.Undo(); staged = nil; apply:Disable(); setReview('Previous bindings restored. Export your character again before requesting a new plan.')
        message('Restore verified. The previous result is no longer valid.')
    end)
    restore:SetPoint('LEFT', receipt, 'RIGHT', 10, 0)
    local editScroll = CreateFrame('ScrollFrame', nil, frame, 'UIPanelScrollFrameTemplate')
    editScroll:SetPoint('TOPLEFT', 22, -120); editScroll:SetPoint('TOPRIGHT', -40, -120); editScroll:SetHeight(140)
    editor = CreateFrame('EditBox', nil, editScroll)
    editor:SetMultiLine(true); editor:SetAutoFocus(false); editor:SetFontObject(ChatFontNormal); editor:SetWidth(810); editor:SetHeight(140); editor:SetMaxLetters(262144)
    editor:SetTextInsets(4, 4, 4, 4); editor:SetScript('OnEscapePressed', function(self) self:ClearFocus() end)
    editor:SetScript('OnTextChanged', function() staged = nil; if apply then apply:Disable() end end)
    editScroll:SetScrollChild(editor)
    local reviewScroll = CreateFrame('ScrollFrame', nil, frame, 'UIPanelScrollFrameTemplate')
    reviewScroll:SetPoint('TOPLEFT', 22, -282); reviewScroll:SetPoint('BOTTOMRIGHT', -40, 88)
    local content = CreateFrame('Frame', nil, reviewScroll); content:SetWidth(810); content:SetHeight(220)
    review = content:CreateFontString(nil, 'OVERLAY', 'GameFontHighlight'); review:SetPoint('TOPLEFT'); review:SetWidth(800); review:SetJustifyH('LEFT'); review:SetJustifyV('TOP')
    setReview('No plan loaded. Export your character to begin.')
    reviewScroll:SetScrollChild(content)
    reviewContent = content
    status = frame:CreateFontString(nil, 'OVERLAY', 'GameFontHighlightSmall')
    status:SetPoint('BOTTOMLEFT', 20, 44); status:SetPoint('BOTTOMRIGHT', -20, 44); status:SetHeight(34); status:SetJustifyH('LEFT')
    apply = button(frame, 'Apply reviewed changes', 215, function()
        if not staged then error('Review the pasted plan first') end
        local text = ns.ApplyReviewed(staged)
        staged = nil; apply:Disable(); put(text)
        setReview('Changes saved. Click Export result after ConsolePort refreshes to verify the effective bindings, then copy the result back to the agent. Use Restore last bindings to undo.')
        message('Bindings saved. Export result confirms the effective routes. Every gameplay button press is still yours.')
    end)
    apply:SetPoint('BOTTOMRIGHT', -20, 15); apply:Disable()
    frame:SetScript('OnHide', function() staged = nil; apply:Disable(); editor:ClearFocus() end)
    frame:RegisterEvent('PLAYER_REGEN_DISABLED')
    frame:SetScript('OnEvent', function() staged = nil; apply:Disable(); message('Combat started. Nothing will apply automatically. Review again outside combat.') end)
    message('Configuration only. This addon never casts spells or sends gameplay input.')
end
SLASH_THUMBLEBRIDGE1 = '/thumblebridge'
SLASH_THUMBLEBRIDGE2 = '/tbbridge'
SLASH_THUMBLEBRIDGE3 = '/thumble'
SlashCmdList.THUMBLEBRIDGE = function(command)
    local sync = (command or ''):lower():match('^sync%s*(.*)$')
    if sync then
        ThumbleBridgeDB = ThumbleBridgeDB or {}
        if sync == 'off' then ThumbleBridgeDB.autoSync = false; ThumbleBridgeDB.syncText = nil
        elseif sync == 'on' then ThumbleBridgeDB.autoSync = true end
        if ns.ConsolePortSync then ns.ConsolePortSync:Changed() end
        print('Thumble: ConsolePort sync ' .. (ThumbleBridgeDB.autoSync == false and 'off' or 'on') .. '. Changes reach your phone after /reload or logout while the Mac receiver is running.')
        return
    end
    local discovery = (command or ''):lower():match('^discovery%s*(.*)$')
    if discovery then
        ThumbleBridgeDB = ThumbleBridgeDB or {}
        if discovery == 'off' then ThumbleBridgeDB.autoDiscovery = false
        elseif discovery == 'on' then ThumbleBridgeDB.autoDiscovery = true end
        local state = ns.DiscoveryStatus or {}
        print('Thumble: automatic Mac gamepad discovery ' .. (ThumbleBridgeDB.autoDiscovery == false and 'off' or 'on')
            .. '; refreshes: ' .. (state.refreshes or 0) .. (state.lastError and '; error: ' .. state.lastError or ''))
        return
    end
    run(function() open() end)
end
