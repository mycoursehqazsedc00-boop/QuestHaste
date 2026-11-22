QuestHaste_EventHandler = CreateFrame("FRAME")
QuestHaste_EventHandler:RegisterEvent("ADDON_LOADED")
QuestHaste_EventHandler:RegisterEvent("PLAYER_LOGIN")

local QuestHaste_EventList = {
    "QUEST_PROGRESS",
    "QUEST_COMPLETE",
    "QUEST_DETAIL",
    "QUEST_FINISHED",
    "GOSSIP_SHOW",
    "GOSSIP_CLOSED",
    "QUEST_GREETING"
}

local HAS_CAPI = false
local QuestHaste_HoldLatched = false
local QuestHaste_HoldLatchTime = 0
local QuestHaste_LastCompleteTitle = nil
local QuestHaste_LastCompleteTime = 0
local currentQuest = ""

-- Reusable tables to avoid per-event allocations in GOSSIP_SHOW / QUEST_GREETING
local availableCache = {}
local activeCache = {}

local QuestHaste_Usage = [[
|cffffff00## QuestHaste Usage:

* Quest (active and available) opening/progress modifiers
    * Control          auto complete/accept and save
    * Control+Shift    auto complete/accept, save, and auto-REPEAT
    * Alt              forget (clears save, repeat, and reward)
    * Shift            complete/accept if not saved, hold if saved
    * No Modifier      complete/accept if saved
* Gossip / greeting list modifiers (multi-quest NPC popups)
    * Shift+Click a quest's name   toggle auto-REPEAT for that quest
    * Alt+Click a saved quest's name   forget it (save + repeat + reward)
    * Shift (held, not clicking a specific quest)
        auto complete/accept a quest in the list
* Reward item marking (QUEST_COMPLETE with multiple choices)
    * Right-Click a reward item    mark/unmark it for future auto-repeats
* Command line options (/qhaste, /questhaste):
    * usage            display usage instructions
    * add              saves current quest
    * repeat           toggles auto-repeat on the current quest
    * reward [N|clear] mark choice N (or clear) for current quest
    * hold [on|off|shift|ctrl|alt]
                       require holding a key + click NPC to auto-finish
    * delay <sec>      set action defer delay (default 0.05, 0 = instant)
    * trace            toggle debug trace logging
    * list             list all saved quests (accept/complete/repeat/reward)
    * pause            disable QuestHaste
    * resume           activate QuestHaste
    * complete         complete/accept current quest
    * reset            clears all saved quests|r
]]

local function TraceLog(msg)
    if QuestHaste and QuestHaste.debugTrace then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff88ccff[QH %.3f]|r %s", GetTime(), tostring(msg)))
    end
end

local function EnsureDefaults()
    if QuestHaste == nil or QuestHaste.autolist == nil then
        QuestHaste = {autolist = {}, dataVersion = "1.0.0"}
    end
    if QuestHaste.dataVersion == nil then
        local tmp = {}
        for k, _ in pairs(QuestHaste.autolist) do
            tmp[k] = {complete = true}
        end
        QuestHaste.autolist = tmp
        QuestHaste.dataVersion = "1.0.0"
    end
    if QuestHaste.holdMode == nil then
        QuestHaste.holdMode = true
    end
    if QuestHaste.holdKey == nil then
        QuestHaste.holdKey = "shift"
    end
    if QuestHaste.actionDelay == nil then
        QuestHaste.actionDelay = 0.05
    end
    if QuestHaste.debugTrace == nil then
        QuestHaste.debugTrace = false
    end
    QuestHaste.currentQuest = nil
    currentQuest = ""
end

local function IsHoldKeyDown()
    local key = (QuestHaste and QuestHaste.holdKey) or "shift"
    if key == "ctrl" then
        return IsControlKeyDown()
    elseif key == "alt" then
        return IsAltKeyDown()
    else
        return IsShiftKeyDown()
    end
end

local function IsHoldActive()
    if not (QuestHaste and QuestHaste.holdMode) then
        return false
    end
    if IsHoldKeyDown() then
        QuestHaste_HoldLatched = true
        QuestHaste_HoldLatchTime = GetTime()
        return true
    end
    if QuestHaste_HoldLatched and (GetTime() - QuestHaste_HoldLatchTime) <= 3.0 then
        return true
    end
    QuestHaste_HoldLatched = false
    return false
end

local function ClearHoldLatch()
    QuestHaste_HoldLatched = false
    QuestHaste_HoldLatchTime = 0
end

-- Deferred action runner: yields at least one frame (or actionDelay seconds)
-- before calling AcceptQuest / CompleteQuest / GetQuestReward / SelectGossip*
-- so UI frames and client events settle without stacking in a single tick.
local QuestHaste_ActionFrame = CreateFrame("FRAME")
QuestHaste_ActionFrame:Hide()
local pendingAction = nil
local pendingElapsed = 0
local pendingDelay = 0

local function CancelPendingAction(reason)
    if pendingAction then
        TraceLog("Cancelled pending action (" .. tostring(reason or "unknown") .. ")")
        pendingAction = nil
        pendingElapsed = 0
        QuestHaste_ActionFrame:Hide()
    end
end

local function ScheduleAction(fn, label)
    local delay = (QuestHaste and QuestHaste.actionDelay) or 0.05
    if delay <= 0 then
        TraceLog("Execute immediate: " .. tostring(label))
        fn()
        return
    end
    pendingAction = fn
    pendingElapsed = 0
    pendingDelay = delay
    QuestHaste_ActionFrame:Show()
    TraceLog("Scheduled (" .. tostring(delay) .. "s): " .. tostring(label))
end

QuestHaste_ActionFrame:SetScript("OnUpdate", function()
    pendingElapsed = pendingElapsed + arg1
    if pendingElapsed >= pendingDelay then
        local fn = pendingAction
        pendingAction = nil
        pendingElapsed = 0
        QuestHaste_ActionFrame:Hide()
        if fn then
            fn()
        end
    end
end)

function QuestHaste_RegisterEvents()
    for _, e in pairs(QuestHaste_EventList) do
        QuestHaste_EventHandler:RegisterEvent(e)
    end
end

function QuestHaste_UnregisterEvents()
    for _, e in pairs(QuestHaste_EventList) do
        QuestHaste_EventHandler:UnregisterEvent(e)
    end
    CancelPendingAction("paused")
end

local function ExtractItemId(link)
    if not link then return nil end
    local _, _, idStr = string.find(link, "item:(%d+)")
    if idStr then
        return tonumber(idStr)
    end
    return nil
end

local function WipeArray(t)
    local n = table.getn(t)
    for i = 1, n do
        t[i] = nil
    end
end

-- Chops flat return lists from GetGossipAvailableQuests / GetGossipActiveQuests
-- into reusable record tables, using expectedCount so nil fields never truncate.
local function PackArgs(...)
    return arg
end

local function FillRecords(dest, fields, argList, expectedCount)
    WipeArray(dest)
    local numFields = table.getn(fields)
    if numFields == 0 then
        return dest
    end
    local count = expectedCount
    if not count then
        local total = argList.n or (table.maxn and table.maxn(argList)) or table.getn(argList)
        count = math.floor(total / numFields)
    end
    for i = 1, count do
        local rec = {}
        for k = 1, numFields do
            rec[fields[k]] = argList[(i - 1) * numFields + k]
        end
        dest[i] = rec
    end
    return dest
end

local function contained(t, title)
    for _, v in ipairs(t) do
        if v.title == title then
            return true
        end
    end
    return false
end

local function StripQuestFormatting(text)
    if not text then return nil end
    local s = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    s = string.gsub(s, "|r", "")
    s = string.gsub(s, "^%s*%[%d+[%+%*]?%]%s*", "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function ResolveButtonQuestTitle(btn, available, active)
    if not btn then return nil end
    local id = btn:GetID()
    if (btn.type == "Available" or btn.isActive == 0) and id and available[id] and available[id].title then
        return available[id].title
    elseif (btn.type == "Active" or btn.isActive == 1) and id and active[id] and active[id].title then
        return active[id].title
    end
    local raw = btn:GetText()
    local clean = StripQuestFormatting(raw)
    if clean then
        for _, v in ipairs(available) do
            if v.title == clean then return v.title end
        end
        for _, v in ipairs(active) do
            if v.title == clean then return v.title end
        end
    end
    return clean or raw
end

local function ShouldAutoRepeatRun()
    if QuestHaste and QuestHaste.holdMode then
        return IsHoldActive()
    end
    return true
end

local function menuHandler(available, active, name, accept, complete)
    local function SetupBackground(b)
        b:SetAllPoints()
        b:SetDrawLayer("BACKGROUND", -1)
        if b.SetColorTexture then
            b:SetColorTexture(1, 1, 1)
        else
            b:SetTexture(1, 1, 1)
        end
    end

    for i = 1, 32 do
        local f = getglobal(name .. i)
        if f then
            if not f.QHaste then
                f.QHaste = {background = f:CreateTexture(), oldScript = f:GetScript("OnClick")}
                SetupBackground(f.QHaste.background)
                local btn = f
                local function OnClick()
                    local title = ResolveButtonQuestTitle(btn, available, active)
                    if IsAltKeyDown() and title and QuestHaste.autolist[title] then
                        if contained(available, title) then
                            QuestHaste_RemoveAutoAccept(title)
                        else
                            QuestHaste_RemoveAutoComplete(title)
                        end
                        QuestHaste_RemoveAutoRepeat(title)
                        QuestHaste_ClearSavedReward(title)
                        btn.QHaste.background:Hide()
                    elseif IsShiftKeyDown() and title then
                        -- Shift+Click a quest's name: toggle auto-repeat
                        TraceLog("Toggle repeat from list: " .. tostring(title))
                        if QuestHaste_IsAutoRepeat(title) then
                            QuestHaste_RemoveAutoRepeat(title)
                            if QuestHaste_IsAutoAccept(title) or QuestHaste_IsAutoComplete(title) then
                                btn.QHaste.background:SetGradientAlpha("HORIZONTAL", 0.5, 1, 0, 0.5, 1, 1, 0, 0)
                                btn.QHaste.background:Show()
                            else
                                btn.QHaste.background:Hide()
                            end
                        else
                            QuestHaste_AddAutoRepeat(title)
                            btn.QHaste.background:SetGradientAlpha("HORIZONTAL", 1, 0.82, 0, 0.6, 1, 0.82, 0, 0)
                            btn.QHaste.background:Show()
                        end
                    else
                        if btn.QHaste.oldScript then
                            btn.QHaste.oldScript()
                        end
                    end
                end
                f:SetScript("OnClick", OnClick)
            end
            if f:IsVisible() then
                f.QHaste.background:Hide()
                local text = f:GetText()
                if text then
                    -- Fast O(1) exact match first
                    local entry = QuestHaste.autolist[text]
                    if entry then
                        if entry.loop then
                            f.QHaste.background:SetGradientAlpha("HORIZONTAL", 1, 0.82, 0, 0.6, 1, 0.82, 0, 0)
                        else
                            f.QHaste.background:SetGradientAlpha("HORIZONTAL", 0.5, 1, 0, 0.5, 1, 1, 0, 0)
                        end
                        f.QHaste.background:Show()
                    else
                        -- Fallback substring check for formatted titles
                        for k in pairs(QuestHaste.autolist) do
                            if strfind(text, k, 1, true) then
                                if QuestHaste_IsAutoRepeat(k) then
                                    f.QHaste.background:SetGradientAlpha("HORIZONTAL", 1, 0.82, 0, 0.6, 1, 0.82, 0, 0)
                                else
                                    f.QHaste.background:SetGradientAlpha("HORIZONTAL", 0.5, 1, 0, 0.5, 1, 1, 0, 0)
                                end
                                f.QHaste.background:Show()
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- Auto-repeat pass (always on if holdMode=false, or gated by IsHoldActive() if holdMode=true)
    if ShouldAutoRepeatRun() then
        for k, v in ipairs(active) do
            if v.completed and QuestHaste_IsAutoRepeat(v.title) then
                currentQuest = v.title
                local idx = k
                ScheduleAction(function() complete(idx) end, "complete repeat active: " .. tostring(v.title))
                return
            end
        end
        for k, v in ipairs(available) do
            if QuestHaste_IsAutoRepeat(v.title) then
                currentQuest = v.title
                local idx = k
                ScheduleAction(function() accept(idx) end, "accept repeat available: " .. tostring(v.title))
                return
            end
        end
        -- If holdMode is active and user held the key, also finish saved (non-repeat) completed/available quests
        if QuestHaste.holdMode then
            for k, v in ipairs(active) do
                if v.completed and QuestHaste_IsAutoComplete(v.title) then
                    currentQuest = v.title
                    local idx = k
                    ScheduleAction(function() complete(idx) end, "hold-finish saved active: " .. tostring(v.title))
                    return
                end
            end
            for k, v in ipairs(available) do
                if QuestHaste_IsAutoAccept(v.title) then
                    currentQuest = v.title
                    local idx = k
                    ScheduleAction(function() accept(idx) end, "hold-accept saved available: " .. tostring(v.title))
                    return
                end
            end
        end
    end

    -- Legacy Shift-held list pass (when holdMode=false)
    if IsShiftKeyDown() and not QuestHaste.holdMode then
        for k, v in ipairs(active) do
            if v.completed then
                currentQuest = v.title
                local idx = k
                ScheduleAction(function() complete(idx) end, "shift complete active: " .. tostring(v.title))
                return
            end
        end

        for k, v in ipairs(available) do
            if QuestHaste_IsAutoAccept(v.title) or (v.repeatable and QuestHaste_IsAutoComplete(v.title)) then
                currentQuest = v.title
                local idx = k
                ScheduleAction(function() accept(idx) end, "shift accept saved: " .. tostring(v.title))
                return
            end
        end

        for k, v in ipairs(active) do
            if QuestHaste_IsAutoComplete(v.title) then
                currentQuest = v.title
                local idx = k
                ScheduleAction(function() complete(idx) end, "shift complete saved: " .. tostring(v.title))
                return
            end
        end

        if available[1] then
            currentQuest = available[1].title
            ScheduleAction(function() accept(1) end, "shift accept first")
            return
        end
        if active[1] then
            currentQuest = active[1].title
            ScheduleAction(function() complete(1) end, "shift complete first")
            return
        end
    end
end

-- Reward item UI hooks for QuestRewardItem1..10
local function RefreshRewardHighlights()
    if not QuestFrame or not QuestFrame:IsShown() then return end
    local title = GetTitleText()
    local savedName, savedId = QuestHaste_GetSavedReward(title)
    local numChoices = GetNumQuestChoices()

    for i = 1, 10 do
        local btn = getglobal("QuestRewardItem" .. i)
        if btn and btn.QHasteFrame then
            if i <= numChoices and (savedName or savedId) then
                local itemName = GetQuestItemInfo("choice", i)
                local itemLink = GetQuestItemLink("choice", i)
                local itemId = ExtractItemId(itemLink)
                if (savedId and itemId and itemId == savedId) or (savedName and itemName and itemName == savedName) then
                    btn.QHasteFrame:Show()
                else
                    btn.QHasteFrame:Hide()
                end
            else
                btn.QHasteFrame:Hide()
            end
        end
    end
end

local function SetSolidColor(tex, r, g, b, a)
    if tex.SetColorTexture then
        tex:SetColorTexture(r, g, b, a)
    else
        tex:SetTexture(r, g, b, a)
    end
end

local function SetupRewardItemHooks()
    for i = 1, 10 do
        local btn = getglobal("QuestRewardItem" .. i)
        if btn and not btn.QHasteHooked then
            btn.QHasteHooked = true
            btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

            local overlay = CreateFrame("Frame", nil, btn)
            overlay:SetAllPoints(btn)
            overlay:SetFrameLevel(btn:GetFrameLevel() + 5)

            local bg = overlay:CreateTexture(nil, "OVERLAY")
            bg:SetAllPoints(overlay)
            SetSolidColor(bg, 1, 0.82, 0, 0.25)

            local top = overlay:CreateTexture(nil, "OVERLAY")
            top:SetPoint("TOPLEFT", overlay, "TOPLEFT", 0, 0)
            top:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", 0, 0)
            top:SetHeight(2)
            SetSolidColor(top, 1, 0.82, 0, 1)

            local bottom = overlay:CreateTexture(nil, "OVERLAY")
            bottom:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", 0, 0)
            bottom:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", 0, 0)
            bottom:SetHeight(2)
            SetSolidColor(bottom, 1, 0.82, 0, 1)

            local left = overlay:CreateTexture(nil, "OVERLAY")
            left:SetPoint("TOPLEFT", overlay, "TOPLEFT", 0, 0)
            left:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", 0, 0)
            left:SetWidth(2)
            SetSolidColor(left, 1, 0.82, 0, 1)

            local right = overlay:CreateTexture(nil, "OVERLAY")
            right:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", 0, 0)
            right:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", 0, 0)
            right:SetWidth(2)
            SetSolidColor(right, 1, 0.82, 0, 1)

            local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            label:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", -3, -3)
            label:SetText("|cffffd700[AUTO]|r")

            overlay:Hide()
            btn.QHasteFrame = overlay

            local oldOnClick = btn:GetScript("OnClick")
            local slotIndex = i
            btn:SetScript("OnClick", function(self, button)
                local clickBtn = button or arg1
                if clickBtn == "RightButton" then
                    if btn.type and btn.type ~= "choice" then
                        return
                    end
                    local title = GetTitleText()
                    if title and title ~= "" then
                        local idx = btn:GetID()
                        if not idx or idx == 0 then idx = slotIndex end
                        TraceLog("Right-Click reward item #" .. tostring(idx) .. " for " .. tostring(title))
                        QuestHaste_ToggleSavedReward(title, idx)
                        RefreshRewardHighlights()
                    end
                    return
                end
                if oldOnClick then
                    oldOnClick(self, button)
                end
            end)

            local oldOnEnter = btn:GetScript("OnEnter")
            btn:SetScript("OnEnter", function(self, motion)
                if oldOnEnter then
                    oldOnEnter(self, motion)
                end
                if (btn.type == nil or btn.type == "choice") and GameTooltip and GameTooltip:IsOwned(btn) then
                    GameTooltip:AddLine("QuestHaste: Right-Click to mark for auto-repeat", 1, 0.82, 0)
                    GameTooltip:Show()
                end
            end)
        end
    end
end

local function FindSavedRewardChoice(title)
    local numChoices = GetNumQuestChoices()
    if numChoices == 0 then
        return 0, true
    end
    if numChoices == 1 then
        return 1, true
    end
    local savedName, savedId = QuestHaste_GetSavedReward(title)
    if not savedName and not savedId then
        return nil, false
    end
    for i = 1, numChoices do
        local itemName = GetQuestItemInfo("choice", i)
        local itemLink = GetQuestItemLink("choice", i)
        local itemId = ExtractItemId(itemLink)
        if (savedId and itemId and itemId == savedId) or (savedName and itemName and itemName == savedName) then
            return i, true
        end
    end
    return nil, false, savedName
end

function QuestHaste_EventHandler.GOSSIP_SHOW()
    if QuestHaste and QuestHaste.holdMode and not IsHoldKeyDown() then
        ClearHoldLatch()
    end

    local available = availableCache
    local active = activeCache
    local availStride, actStride = 0, 0

    if C_GossipInfo and C_GossipInfo.GetAvailableQuests and C_GossipInfo.GetActiveQuests then
        WipeArray(available)
        WipeArray(active)
        local cAvail = C_GossipInfo.GetAvailableQuests()
        for i, q in ipairs(cAvail) do
            available[i] = {title = q.title, level = q.questLevel, repeatable = true}
        end
        local cAct = C_GossipInfo.GetActiveQuests()
        for i, q in ipairs(cAct) do
            active[i] = {title = q.title, level = q.questLevel, completed = q.isComplete}
        end
        availStride = -1
        actStride = -1
    else
        local numAvail = GetNumGossipAvailableQuests and GetNumGossipAvailableQuests() or nil
        local numAct = GetNumGossipActiveQuests and GetNumGossipActiveQuests() or nil
        local availRaw = PackArgs(GetGossipAvailableQuests())
        local actRaw = PackArgs(GetGossipActiveQuests())

        local availFields = {"title", "level", "trivial", "repeatable"}
        local activeFields = {"title", "level", "completed"}

        availStride = (numAvail and numAvail > 0 and availRaw.n and availRaw.n > 0) and math.floor(availRaw.n / numAvail) or 0
        actStride = (numAct and numAct > 0 and actRaw.n and actRaw.n > 0) and math.floor(actRaw.n / numAct) or 0
        if availStride == 2 then
            availFields = {"title", "level"}
        elseif availStride == 3 then
            availFields = {"title", "level", "repeatable"}
        elseif availStride == 4 then
            availFields = {"title", "level", "trivial", "repeatable"}
        elseif availStride == 7 then
            availFields = {"title", "level", "trivial", "frequency", "repeatable", "legendary", "ignored"}
        end
        if actStride == 2 then
            activeFields = {"title", "level"}
        elseif actStride == 3 then
            activeFields = {"title", "level", "completed"}
        elseif actStride == 4 then
            activeFields = {"title", "level", "trivial", "completed"}
        elseif actStride == 6 then
            activeFields = {"title", "level", "trivial", "completed", "legendary", "ignored"}
        end

        FillRecords(available, availFields, availRaw, numAvail)
        FillRecords(active, activeFields, actRaw, numAct)
    end

    TraceLog("GOSSIP_SHOW (avail=" .. table.getn(available) .. " s=" .. availStride .. ", act=" .. table.getn(active) .. " s=" .. actStride .. ", holdMode=" .. tostring(QuestHaste.holdMode) .. ", holdActive=" .. tostring(IsHoldActive()) .. ")")
    if QuestHaste and QuestHaste.debugTrace then
        for i, v in ipairs(active) do
            if QuestHaste_IsAutoRepeat(v.title) then
                TraceLog("  active[" .. i .. "] repeat=" .. tostring(v.title) .. " completed=" .. tostring(v.completed))
            end
        end
    end
    menuHandler(available, active, "GossipTitleButton", SelectGossipAvailableQuest, SelectGossipActiveQuest)
end

function QuestHaste_EventHandler.QUEST_GREETING()
    if QuestHaste and QuestHaste.holdMode and not IsHoldKeyDown() then
        ClearHoldLatch()
    end
    WipeArray(availableCache)
    WipeArray(activeCache)
    for k = 1, GetNumActiveQuests() do
        local title, level, isComplete = GetActiveTitle(k)
        activeCache[k] = {title = title, level = level, completed = isComplete}
    end
    for k = 1, GetNumAvailableQuests() do
        local title, level, isTrivial, isRepeatable = GetAvailableTitle(k)
        availableCache[k] = {title = title, level = level, trivial = isTrivial, repeatable = isRepeatable}
    end
    TraceLog("QUEST_GREETING (avail=" .. table.getn(availableCache) .. ", act=" .. table.getn(activeCache) .. ", holdMode=" .. tostring(QuestHaste.holdMode) .. ", holdActive=" .. tostring(IsHoldActive()) .. ")")
    menuHandler(availableCache, activeCache, "QuestTitleButton", SelectAvailableQuest, SelectActiveQuest)
end

function QuestHaste_EventHandler.QUEST_PROGRESS()
    local title = GetTitleText()
    local holdActive = IsHoldActive()
    local holdKeyIsAlt = (QuestHaste.holdMode and QuestHaste.holdKey == "alt")
    local holdKeyIsCtrl = (QuestHaste.holdMode and QuestHaste.holdKey == "ctrl")
    local holdKeyIsShift = (QuestHaste.holdMode and QuestHaste.holdKey == "shift")
    TraceLog("QUEST_PROGRESS: " .. tostring(title) .. " (holdActive=" .. tostring(holdActive) .. ")")

    if IsControlKeyDown() and IsShiftKeyDown() and not (holdActive and (holdKeyIsCtrl or holdKeyIsShift)) then
        QuestHaste_AddAutoRepeat(title)
    elseif IsControlKeyDown() and not (holdActive and holdKeyIsCtrl) then
        QuestHaste_AddAutoComplete(title)
    elseif IsAltKeyDown() and not (holdActive and holdKeyIsAlt) then
        QuestHaste_RemoveAutoComplete(title)
        QuestHaste_RemoveAutoRepeat(title)
        QuestHaste_ClearSavedReward(title)
        return
    end

    local repeatAllowed = QuestHaste_IsAutoRepeat(title) and ShouldAutoRepeatRun()
    local savedAllowed = QuestHaste_IsAutoComplete(title)
    local normalTrigger
    if QuestHaste.holdMode then
        normalTrigger = holdActive and (repeatAllowed or savedAllowed)
    else
        normalTrigger = repeatAllowed or (currentQuest == title) or (not savedAllowed ~= not (IsShiftKeyDown() and not holdKeyIsShift))
    end

    if (normalTrigger or currentQuest == title) and IsQuestCompletable() then
        currentQuest = title
        ScheduleAction(function()
            if QuestFrame and QuestFrame:IsShown() and IsQuestCompletable() then
                CompleteQuest()
            end
        end, "CompleteQuest: " .. tostring(title))
    else
        currentQuest = ""
    end
end

function QuestHaste_EventHandler.QUEST_COMPLETE()
    local title = GetTitleText()
    local holdActive = IsHoldActive()
    local holdKeyIsAlt = (QuestHaste.holdMode and QuestHaste.holdKey == "alt")
    local holdKeyIsCtrl = (QuestHaste.holdMode and QuestHaste.holdKey == "ctrl")
    local holdKeyIsShift = (QuestHaste.holdMode and QuestHaste.holdKey == "shift")
    TraceLog("QUEST_COMPLETE: " .. tostring(title) .. " (choices=" .. tostring(GetNumQuestChoices()) .. ", holdActive=" .. tostring(holdActive) .. ")")

    SetupRewardItemHooks()
    RefreshRewardHighlights()

    if IsControlKeyDown() and IsShiftKeyDown() and not (holdActive and (holdKeyIsCtrl or holdKeyIsShift)) then
        QuestHaste_AddAutoRepeat(title)
    elseif IsControlKeyDown() and not (holdActive and holdKeyIsCtrl) then
        QuestHaste_AddAutoComplete(title)
    elseif IsAltKeyDown() and not (holdActive and holdKeyIsAlt) then
        QuestHaste_RemoveAutoComplete(title)
        QuestHaste_RemoveAutoRepeat(title)
        QuestHaste_ClearSavedReward(title)
        return
    end

    -- Anti-duplicate guard for rapid double-fires of QUEST_COMPLETE
    local now = GetTime()
    if QuestHaste_LastCompleteTitle == title and (now - QuestHaste_LastCompleteTime) < 0.15 then
        TraceLog("Suppressed duplicate QUEST_COMPLETE for " .. tostring(title))
        return
    end

    local repeatAllowed = QuestHaste_IsAutoRepeat(title) and ShouldAutoRepeatRun()
    local savedAllowed = QuestHaste_IsAutoComplete(title)
    local normalTrigger
    if QuestHaste.holdMode then
        normalTrigger = holdActive and (repeatAllowed or savedAllowed)
    else
        normalTrigger = repeatAllowed or (currentQuest == title) or (not savedAllowed ~= not (IsShiftKeyDown() and not holdKeyIsShift))
    end

    if normalTrigger or currentQuest == title then
        local choiceIdx, ok, missingName = FindSavedRewardChoice(title)
        if not ok then
            if missingName then
                DEFAULT_CHAT_FRAME:AddMessage("|cffffff88QuestHaste|r: |cffff6600Saved reward '" .. tostring(missingName) .. "' not found for '" .. tostring(title) .. "'. Please choose manually.|r")
            else
                TraceLog("QUEST_COMPLETE waiting for manual choice (no saved reward)")
            end
            currentQuest = ""
            return
        end

        QuestHaste_LastCompleteTitle = title
        QuestHaste_LastCompleteTime = now
        local capturedTitle = title
        local capturedChoice = choiceIdx
        ScheduleAction(function()
            if QuestFrame and QuestFrame:IsShown() then
                if capturedChoice and capturedChoice > 0 then
                    GetQuestReward(capturedChoice)
                else
                    GetQuestReward()
                end
                if QuestHaste_IsAutoRepeat(capturedTitle) then
                    QuestHaste_Session[capturedTitle] = (QuestHaste_Session[capturedTitle] or 0) + 1
                    DEFAULT_CHAT_FRAME:AddMessage("|cffffff88QuestHaste|r: |cffffd700" .. capturedTitle .. "|r repeated (|cff00ff00x" .. QuestHaste_Session[capturedTitle] .. "|r this session).")
                end
            end
            currentQuest = ""
            if QuestHaste.holdMode and not IsHoldKeyDown() then
                ClearHoldLatch()
            end
        end, "GetQuestReward(" .. tostring(capturedChoice) .. "): " .. tostring(capturedTitle))
    else
        currentQuest = ""
    end
end

function QuestHaste_EventHandler.QUEST_DETAIL()
    local title = GetTitleText()
    local holdActive = IsHoldActive()
    local holdKeyIsAlt = (QuestHaste.holdMode and QuestHaste.holdKey == "alt")
    local holdKeyIsCtrl = (QuestHaste.holdMode and QuestHaste.holdKey == "ctrl")
    local holdKeyIsShift = (QuestHaste.holdMode and QuestHaste.holdKey == "shift")
    TraceLog("QUEST_DETAIL: " .. tostring(title) .. " (holdActive=" .. tostring(holdActive) .. ")")

    if IsControlKeyDown() and IsShiftKeyDown() and not (holdActive and (holdKeyIsCtrl or holdKeyIsShift)) then
        QuestHaste_AddAutoRepeat(title)
    elseif IsControlKeyDown() and not (holdActive and holdKeyIsCtrl) then
        QuestHaste_AddAutoAccept(title)
    elseif IsAltKeyDown() and not (holdActive and holdKeyIsAlt) then
        QuestHaste_RemoveAutoAccept(title)
        QuestHaste_RemoveAutoRepeat(title)
        QuestHaste_ClearSavedReward(title)
        return
    end

    local repeatAllowed = QuestHaste_IsAutoRepeat(title) and ShouldAutoRepeatRun()
    local savedAllowed = QuestHaste_IsAutoAccept(title)
    local normalTrigger
    if QuestHaste.holdMode then
        normalTrigger = holdActive and (repeatAllowed or savedAllowed)
    else
        normalTrigger = repeatAllowed or (currentQuest == title) or (not savedAllowed ~= not (IsShiftKeyDown() and not holdKeyIsShift))
    end

    if normalTrigger or currentQuest == title then
        ScheduleAction(function()
            if QuestFrame and QuestFrame:IsShown() then
                AcceptQuest()
            end
        end, "AcceptQuest: " .. tostring(title))
    else
        currentQuest = ""
    end
end

function QuestHaste_EventHandler.QUEST_FINISHED()
    CancelPendingAction("QUEST_FINISHED")
end

function QuestHaste_EventHandler.GOSSIP_CLOSED()
    CancelPendingAction("GOSSIP_CLOSED")
    currentQuest = ""
    if QuestHaste and QuestHaste.holdMode and not IsHoldKeyDown() then
        ClearHoldLatch()
    end
end

function QuestHaste_EventHandler.ADDON_LOADED(name)
    if name == "QuestHaste" then
        QuestHaste_Session = {}
        EnsureDefaults()
        QuestHaste_RegisterEvents()
        QuestHaste_EventHandler:UnregisterEvent("ADDON_LOADED")
        local modeStr = QuestHaste.holdMode and ("Hold-" .. tostring(QuestHaste.holdKey)) or "Always-Repeat"
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff88QuestHaste|r loaded (" .. modeStr .. "). See /qhaste usage")
    end
end

function QuestHaste_EventHandler.PLAYER_LOGIN()
    HAS_CAPI = (CLASSIC_API_VERSION ~= nil)
    TraceLog("PLAYER_LOGIN: ClassicAPI=" .. tostring(HAS_CAPI))
end

QuestHaste_EventHandler:SetScript("OnEvent", function()
    if QuestHaste_EventHandler[event] then
        QuestHaste_EventHandler[event](arg1, arg2, arg3, arg4, arg5)
    end
end)

function QuestHaste_IsAutoComplete(title)
    return QuestHaste.autolist[title] and QuestHaste.autolist[title].complete
end

function QuestHaste_IsAutoAccept(title)
    return QuestHaste.autolist[title] and QuestHaste.autolist[title].accept
end

function QuestHaste_IsAutoRepeat(title)
    return QuestHaste.autolist[title] and QuestHaste.autolist[title].loop
end

function QuestHaste_GetSavedReward(title)
    local entry = QuestHaste.autolist[title]
    if not entry then return nil, nil, nil end
    return entry.rewardName, entry.rewardItemId, entry.rewardIndex
end

function QuestHaste_SetSavedReward(title, choiceIndex)
    if not title or title == "" then return false end
    local numChoices = GetNumQuestChoices()
    if not choiceIndex or choiceIndex < 1 or choiceIndex > numChoices then
        return false
    end
    local itemName = GetQuestItemInfo("choice", choiceIndex)
    local itemLink = GetQuestItemLink("choice", choiceIndex)
    local itemId = ExtractItemId(itemLink)
    if not itemName and not itemId then
        return false
    end
    if QuestHaste.autolist[title] == nil then
        QuestHaste.autolist[title] = {}
    end
    QuestHaste.autolist[title].rewardName = itemName
    QuestHaste.autolist[title].rewardItemId = itemId
    QuestHaste.autolist[title].rewardIndex = choiceIndex
    local display = itemLink or itemName or ("Choice #" .. choiceIndex)
    local msg = "|cffffff88QuestHaste|r: |cffffd700" .. title .. "|r auto-reward set to " .. display .. "."
    UIErrorsFrame:AddMessage(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
    return true
end

function QuestHaste_ClearSavedReward(title)
    local entry = QuestHaste.autolist[title]
    if not entry or (not entry.rewardName and not entry.rewardItemId) then return end
    entry.rewardName = nil
    entry.rewardItemId = nil
    entry.rewardIndex = nil
    if not (entry.accept or entry.complete or entry.loop) then
        QuestHaste.autolist[title] = nil
    end
    local msg = "|cffffff88QuestHaste|r: |cffffd700" .. title .. "|r auto-reward |cffff0000cleared|r."
    UIErrorsFrame:AddMessage(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
end

function QuestHaste_ToggleSavedReward(title, choiceIndex)
    local savedName, savedId = QuestHaste_GetSavedReward(title)
    local itemName = GetQuestItemInfo("choice", choiceIndex)
    local itemLink = GetQuestItemLink("choice", choiceIndex)
    local itemId = ExtractItemId(itemLink)
    if (savedId and itemId and savedId == itemId) or (savedName and itemName and savedName == itemName) then
        QuestHaste_ClearSavedReward(title)
    else
        QuestHaste_SetSavedReward(title, choiceIndex)
    end
end

function QuestHaste_AddAutoComplete(title)
    if QuestHaste_IsAutoComplete(title) then return end
    if QuestHaste.autolist[title] == nil then QuestHaste.autolist[title] = {} end
    QuestHaste.autolist[title].complete = true
    local msg = "|cffffff88QuestHaste|r: |cffffff00" .. title .. "|r |cff00ff00added|r."
    UIErrorsFrame:AddMessage(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
end

function QuestHaste_AddAutoAccept(title)
    if QuestHaste_IsAutoAccept(title) then return end
    if QuestHaste.autolist[title] == nil then QuestHaste.autolist[title] = {} end
    QuestHaste.autolist[title].accept = true
    local msg = "|cffffff88QuestHaste|r: |cffffff00" .. title .. "|r |cff00ff00added|r."
    UIErrorsFrame:AddMessage(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
end

function QuestHaste_AddAutoRepeat(title)
    if QuestHaste_IsAutoRepeat(title) then return end
    if QuestHaste.autolist[title] == nil then QuestHaste.autolist[title] = {} end
    QuestHaste.autolist[title].loop = true
    QuestHaste_Session[title] = QuestHaste_Session[title] or 0
    local msg = "|cffffff88QuestHaste|r: |cffffd700" .. title .. "|r auto-repeat |cff00ff00enabled|r."
    UIErrorsFrame:AddMessage(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
end

function QuestHaste_RemoveAutoComplete(title)
    if not QuestHaste_IsAutoComplete(title) then return end
    local entry = QuestHaste.autolist[title]
    if entry.accept or entry.loop or entry.rewardName or entry.rewardItemId then
        entry.complete = false
    else
        QuestHaste.autolist[title] = nil
    end
    local msg = "|cffffff88QuestHaste|r: |cffffff00" .. title .. "|r |cffff0000removed|r."
    UIErrorsFrame:AddMessage(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
end

function QuestHaste_RemoveAutoAccept(title)
    if not QuestHaste_IsAutoAccept(title) then return end
    local entry = QuestHaste.autolist[title]
    if entry.complete or entry.loop or entry.rewardName or entry.rewardItemId then
        entry.accept = false
    else
        QuestHaste.autolist[title] = nil
    end
    local msg = "|cffffff88QuestHaste|r: |cffffff00" .. title .. "|r |cffff0000removed|r."
    UIErrorsFrame:AddMessage(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
end

function QuestHaste_RemoveAutoRepeat(title)
    if not QuestHaste_IsAutoRepeat(title) then return end
    local entry = QuestHaste.autolist[title]
    entry.loop = nil
    if not (entry.accept or entry.complete or entry.rewardName or entry.rewardItemId) then
        QuestHaste.autolist[title] = nil
    end
    local msg = "|cffffff88QuestHaste|r: |cffffd700" .. title .. "|r auto-repeat |cffff0000disabled|r."
    UIErrorsFrame:AddMessage(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
end

function QuestHaste_Proceed()
    if GossipFrame:IsShown() then
        currentQuest = GetGossipActiveQuests()
        SelectGossipActiveQuest(1)
    elseif QuestFrame:IsShown() then
        local title = GetTitleText()
        if QuestFrameAcceptButton:IsShown() then
            AcceptQuest()
        elseif QuestFrameCompleteButton:IsShown() and IsQuestCompletable() then
            currentQuest = title
            CompleteQuest()
        elseif QuestFrameCompleteQuestButton:IsShown() and IsQuestCompletable() then
            local choiceIdx, ok = FindSavedRewardChoice(title)
            if ok then
                if choiceIdx and choiceIdx > 0 then
                    GetQuestReward(choiceIdx)
                else
                    GetQuestReward()
                end
            else
                UIErrorsFrame:AddMessage("QuestHaste: select a reward or Right-Click to mark one.", 1, 0.5, 0)
            end
        end
    end
end

local function CommandParser(msg)
    local _, _, command, rest = string.find(msg or "", "^(%S*)%s*(.-)$")
    command = string.lower(command or "")
    rest = string.lower(rest or "")

    if command == "usage" then
        DEFAULT_CHAT_FRAME:AddMessage(QuestHaste_Usage)
    elseif command == "add" then
        if QuestFrame:IsShown() then
            local title = GetTitleText()
            QuestHaste_AddAutoComplete(title)
        else
            UIErrorsFrame:AddMessage("QuestHaste: no active quest.", 1, 0, 0)
        end
        QuestHaste_Proceed()
    elseif command == "repeat" then
        if QuestFrame:IsShown() then
            local title = GetTitleText()
            if QuestHaste_IsAutoRepeat(title) then
                QuestHaste_RemoveAutoRepeat(title)
            else
                QuestHaste_AddAutoRepeat(title)
            end
        else
            UIErrorsFrame:AddMessage("QuestHaste: no active quest.", 1, 0, 0)
        end
        QuestHaste_Proceed()
    elseif command == "reward" then
        if not QuestFrame:IsShown() then
            UIErrorsFrame:AddMessage("QuestHaste: open quest completion frame first.", 1, 0, 0)
            return
        end
        local title = GetTitleText()
        if rest == "clear" or rest == "none" then
            QuestHaste_ClearSavedReward(title)
            RefreshRewardHighlights()
        else
            local idx = tonumber(rest)
            if idx then
                if not QuestHaste_SetSavedReward(title, idx) then
                    UIErrorsFrame:AddMessage("QuestHaste: invalid choice index " .. tostring(idx) .. ".", 1, 0, 0)
                else
                    RefreshRewardHighlights()
                end
            else
                local savedName = QuestHaste_GetSavedReward(title)
                DEFAULT_CHAT_FRAME:AddMessage("|cffffff88QuestHaste|r: saved reward for |cffffd700" .. tostring(title) .. "|r = " .. tostring(savedName or "none") .. " (use /qhaste reward <index|clear> or Right-Click item).")
            end
        end
    elseif command == "hold" then
        if rest == "on" then
            QuestHaste.holdMode = true
        elseif rest == "off" then
            QuestHaste.holdMode = false
            ClearHoldLatch()
        elseif rest == "shift" or rest == "ctrl" or rest == "alt" then
            QuestHaste.holdMode = true
            QuestHaste.holdKey = rest
        elseif rest == "" then
            QuestHaste.holdMode = not QuestHaste.holdMode
            if not QuestHaste.holdMode then ClearHoldLatch() end
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffffff88QuestHaste|r: usage /qhaste hold [on|off|shift|ctrl|alt]")
            return
        end
        local stateStr = QuestHaste.holdMode and ("|cff00ff00ON|r (key: |cffffd700" .. tostring(QuestHaste.holdKey) .. "|r)") or "|cffff0000OFF|r (always auto-repeat)"
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff88QuestHaste|r: Hold-Key NPC mode " .. stateStr)
    elseif command == "delay" then
        local val = tonumber(rest)
        if val and val >= 0 and val <= 2 then
            QuestHaste.actionDelay = val
            DEFAULT_CHAT_FRAME:AddMessage("|cffffff88QuestHaste|r: action defer delay set to |cff00ff00" .. tostring(val) .. "s|r.")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffffff88QuestHaste|r: current delay = " .. tostring(QuestHaste.actionDelay) .. "s (use /qhaste delay <0..2>).")
        end
    elseif command == "trace" then
        QuestHaste.debugTrace = not QuestHaste.debugTrace
        local stateStr = QuestHaste.debugTrace and "|cff00ff00ON|r" or "|cffff0000OFF|r"
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff88QuestHaste|r: debug trace " .. stateStr)
    elseif command == "list" then
        DEFAULT_CHAT_FRAME:AddMessage("QuestHaste quest list:")
        for k, v in pairs(QuestHaste.autolist) do
            DEFAULT_CHAT_FRAME:AddMessage("    " .. k)
            local opts = "        ("
            opts = opts .. (QuestHaste_IsAutoAccept(k) and "|cff00ff00" or "|cffff0000") .. "accept|r | "
            opts = opts .. (QuestHaste_IsAutoComplete(k) and "|cff00ff00" or "|cffff0000") .. "complete|r | "
            opts = opts .. (QuestHaste_IsAutoRepeat(k) and "|cffffd700" or "|cffff0000") .. "repeat|r"
            if v.rewardName then
                opts = opts .. " | |cff88ccffreward: " .. v.rewardName .. "|r"
            end
            opts = opts .. ")"
            DEFAULT_CHAT_FRAME:AddMessage(opts)
        end
    elseif command == "pause" then
        CancelPendingAction("pause")
        ClearHoldLatch()
        currentQuest = ""
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff88QuestHaste|r: |cffff0000paused|r.")
        QuestHaste_UnregisterEvents()
    elseif command == "resume" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff88QuestHaste|r: |cff00ff00active|r.")
        QuestHaste_RegisterEvents()
    elseif command == "complete" then
        QuestHaste_Proceed()
    elseif command == "reset" then
        QuestHaste.autolist = {}
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff88QuestHaste|r: saved quest list cleared.")
    else
        DEFAULT_CHAT_FRAME:AddMessage("Syntax:\n/qhaste usage\n/qhaste add\n/qhaste repeat\n/qhaste reward [index|clear]\n/qhaste hold [on|off|shift|ctrl|alt]\n/qhaste delay <sec>\n/qhaste trace\n/qhaste list\n/qhaste complete\n/qhaste pause\n/qhaste resume\n/qhaste reset")
    end
end

SLASH_QUESTHASTE1 = "/questhaste"
SLASH_QUESTHASTE2 = "/qhaste"
SlashCmdList["QUESTHASTE"] = CommandParser
