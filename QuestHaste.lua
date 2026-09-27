QuestHaste_EventHandler = CreateFrame("FRAME")
QuestHaste_EventHandler:RegisterEvent("ADDON_LOADED")

local QuestHaste_EventList = {
    "QUEST_PROGRESS",
    "QUEST_COMPLETE",
    "QUEST_DETAIL",
    "GOSSIP_SHOW",
    "QUEST_GREETING"
}

local QuestHaste_Usage = [[
|cffffff00## QuestHaste Usage:

* Quest (active and available) opening/progress modifiers
    * Control          auto complete/accept and save
    * Control+Shift    auto complete/accept, save, and auto-REPEAT
                        (keeps accepting/turning this quest back in,
                        with zero further key presses, until you
                        clear it again with Alt or /qhaste repeat)
    * Alt              forget (clears save AND repeat)
    * Shift            complete/accept if not saved, hold if saved
    * No Modifier      complete/accept if saved
* Gossip / greeting list modifiers (multi-quest NPC popups)
    * Shift+Click a quest's name   toggle auto-REPEAT for that quest
    * Alt+Click a saved quest's name   forget it (save + repeat)
    * Shift (held, not clicking a specific quest)
        auto complete/accept a quest in the list
        (priority: repeat-flagged, completed, available saved,
        active saved, available, active)
* Command line options (/qhaste, /questhaste):
    * usage    display usage instructions
    * add      saves current quest
    * repeat   toggles auto-repeat on the current quest
    * list     list all saved quests (shows accept/complete/repeat state)
    * pause    disable QuestHaste
    * resume   activate QuestHaste
    * complete complete/accept current quest
    * reset    clears all saved quests|r
]]

function QuestHaste_RegisterEvents()
    for _,e in pairs(QuestHaste_EventList) do
        QuestHaste_EventHandler:RegisterEvent(e)
    end
end

function QuestHaste_UnregisterEvents()
    for _,e in pairs(QuestHaste_EventList) do
        QuestHaste_EventHandler:UnregisterEvent(e)
    end
end

-- Vanilla's GetGossipAvailableQuests()/GetGossipActiveQuests() return one
-- long flat list of values (numRecords * #fields). This chops that flat
-- list back up into an array of {field = value, ...} records.
local function filterEvens(t, fields)
    local r = {}
    for i=1,#t/#fields do
        r[i] = {}
        for k = 1,#fields do
            r[i][fields[k]] = t[(i-1)*#fields+k]
        end
    end
    return r
end

-- FIX: this used to do `v == val`, comparing a whole record table to a
-- plain title string -- that's never true, so it always fell through to
-- the `else` branch below regardless of whether the quest was actually
-- available or active. Alt-clicking a saved "available" quest silently
-- did nothing because of this.
local function contained(t,title)
    for _,v in pairs(t) do
        if v.title == title then
            return true
        end
    end
    return false
end

local function menuHandler(available, active, name, accept, complete)
    local function SetupBackground(b)
        b:SetAllPoints()
        b:SetDrawLayer("BACKGROUND", -1)
        b:SetColorTexture(1,1,1)
    end
    for i = 1,32 do
        local f = getglobal(name..i)
        if f then
            if not f.QHaste then
                f.QHaste = {background = f:CreateTexture(), oldScript = f:GetScript("OnClick")}
                SetupBackground(f.QHaste.background)
                local function OnClick(...)
                    local title = f:GetText()
                    if IsAltKeyDown() and QuestHaste.autolist[title] then
                        if contained(available, title) then
                            QuestHaste_RemoveAutoAccept(title)
                        else
                            QuestHaste_RemoveAutoComplete(title)
                        end
                        QuestHaste_RemoveAutoRepeat(title)
                        f.QHaste.background:Hide()
                    elseif IsShiftKeyDown() then
                        -- Shift+Click a quest's name: toggle auto-repeat
                        -- for that specific quest, independent of any
                        -- save/accept/complete flag it may already have.
                        if QuestHaste_IsAutoRepeat(title) then
                            QuestHaste_RemoveAutoRepeat(title)
                        else
                            QuestHaste_AddAutoRepeat(title)
                        end
                    else
                        f.QHaste.oldScript(...)
                    end
                end
                f:SetScript("OnClick",OnClick)
            end
            if f:IsVisible() then
                f.QHaste.background:Hide()
                for k in pairs(QuestHaste.autolist) do
                    -- FIX: plain-find (the 4th "true" arg) instead of a
                    -- Lua pattern match, so quest titles containing
                    -- pattern-magic characters ("-", "(", "%", etc, all
                    -- common in real quest names) don't break matching
                    -- or throw a pattern error.
                    if strfind(f:GetText(), k, 1, true) then
                        if QuestHaste_IsAutoRepeat(k) then
                            -- gold: this one is on auto-repeat
                            f.QHaste.background:SetGradientAlpha("HORIZONTAL", 1,0.82,0,0.6, 1,0.82,0,0)
                        else
                            -- green-yellow: merely saved
                            f.QHaste.background:SetGradientAlpha("HORIZONTAL", 0.5,1,0,0.5, 1,1,0,0)
                        end
                        f.QHaste.background:Show()
                        break
                    end
                end
            end
        end
    end

    -- Unconditional auto-repeat pass. Unlike the Shift-held pass below,
    -- this runs on every single GOSSIP_SHOW/QUEST_GREETING regardless of
    -- modifier keys -- it's what makes a repeat-flagged quest actually
    -- keep looping hands-off once you've marked it, rather than only
    -- while you hold Shift down.
    for k,v in pairs(active) do
        if v.completed and QuestHaste_IsAutoRepeat(v.title) then
            QuestHaste.currentQuest = v.title
            complete(k)
            return
        end
    end
    for k,v in pairs(available) do
        if QuestHaste_IsAutoRepeat(v.title) then
            QuestHaste.currentQuest = v.title
            accept(k)
            return
        end
    end
    for k,v in pairs(active) do
        if QuestHaste_IsAutoRepeat(v.title) then
            QuestHaste.currentQuest = v.title
            complete(k)
            return
        end
    end

    if IsShiftKeyDown() then
        for k,v in pairs(active) do
            if v.completed then
                QuestHaste.currentQuest = v.title
                complete(k)
                return
            end
        end

        for k,v in pairs(available) do
            if QuestHaste_IsAutoAccept(v.title) or v.repeatable and QuestHaste_IsAutoComplete(v.title) then
                QuestHaste.currentQuest = v.title
                accept(k)
                return
            end
        end

        for k,v in pairs(active) do
            if QuestHaste_IsAutoComplete(v.title) then
                QuestHaste.currentQuest = v.title
                complete(k)
                return
            end
        end
        
        if next(available) then
            QuestHaste.currentQuest = available[1]
            accept(1)
            return
        end
        if next(active) then
            QuestHaste.currentQuest = active[1]
            complete(1)
            return
        end
    end
end
    
function QuestHaste_EventHandler.GOSSIP_SHOW()
    local available = filterEvens({GetGossipAvailableQuests()},{"title", "level", "trivial", "frequency", "repeatable", "legendary", "ignored"})
    local active = filterEvens({GetGossipActiveQuests()}, {"title", "level", "trivial", "completed", "legendary", "ignored"})
    local name = "GossipTitleButton"
    menuHandler(available, active, name, SelectGossipAvailableQuest, SelectGossipActiveQuest)
end

function QuestHaste_EventHandler.QUEST_GREETING()
    -- FIX (real bug, not just style): GetActiveTitle/GetAvailableTitle
    -- each return SEVERAL values (title, level, isComplete / title,
    -- level, isTrivial, isRepeatable). The old code did
    -- `table.insert(active, GetActiveTitle(k))`, which -- because a
    -- multi-return function as the last argument gets fully expanded --
    -- silently turned into a call like `table.insert(active, title,
    -- level, isComplete)`. Stock table.insert only accepts 2 or 3
    -- arguments, so as soon as any quest was on offer this threw
    -- "wrong number of arguments to 'insert'" and menuHandler never ran
    -- for this event at all. On top of that, even without the error,
    -- the list would have held bare strings instead of records, so
    -- `v.completed`/`v.repeatable`/`v.title` inside menuHandler were
    -- always nil for anything that came through QUEST_GREETING -- the
    -- saved/repeat/priority logic never actually applied to simple
    -- quest-greeting NPCs, only to full gossip-menu NPCs.
    local available, active = {}, {}
    for k = 1, GetNumActiveQuests() do
        local title, level, isComplete = GetActiveTitle(k)
        table.insert(active, {title = title, level = level, completed = isComplete})
    end
    for k = 1, GetNumAvailableQuests() do
        local title, level, isTrivial, isRepeatable = GetAvailableTitle(k)
        table.insert(available, {title = title, level = level, trivial = isTrivial, repeatable = isRepeatable})
    end
    local name = "QuestTitleButton"
    menuHandler(available, active, name, SelectAvailableQuest, SelectActiveQuest)
end
    

function QuestHaste_EventHandler.QUEST_PROGRESS()
    local title = GetTitleText()

    if IsControlKeyDown() and IsShiftKeyDown() then
        QuestHaste_AddAutoRepeat(title)
    elseif IsControlKeyDown() then
        QuestHaste_AddAutoComplete(title)
    elseif IsAltKeyDown() then
        QuestHaste_RemoveAutoComplete(title)
        QuestHaste_RemoveAutoRepeat(title)
        return
    end

    if (QuestHaste_IsAutoRepeat(title) or QuestHaste.currentQuest == title or not QuestHaste_IsAutoComplete(title) ~= not IsShiftKeyDown()) and IsQuestCompletable() then
        QuestHaste.currentQuest = title
        CompleteQuest()
    else
        QuestHaste.currentQuest = ""
    end
end

function QuestHaste_EventHandler.QUEST_COMPLETE()
    local title = GetTitleText()

    if IsControlKeyDown() and IsShiftKeyDown() then
        QuestHaste_AddAutoRepeat(title)
    elseif IsControlKeyDown() then
        QuestHaste_AddAutoComplete(title)
    elseif IsAltKeyDown() then
        QuestHaste_RemoveAutoComplete(title)
        QuestHaste_RemoveAutoRepeat(title)
        return
    end

    if (QuestHaste_IsAutoRepeat(title) or QuestHaste.currentQuest == title or not QuestHaste_IsAutoComplete(title) ~= not IsShiftKeyDown()) and GetNumQuestChoices() == 0 then
        GetQuestReward()
        if QuestHaste_IsAutoRepeat(title) then
            QuestHaste_Session[title] = (QuestHaste_Session[title] or 0) + 1
            DEFAULT_CHAT_FRAME:AddMessage("|cffffff88QuestHaste|r: |cffffd700"..title.."|r repeated (|cff00ff00x"..QuestHaste_Session[title].."|r this session).")
        end
    end
    QuestHaste.currentQuest = ""
end

function QuestHaste_EventHandler.QUEST_DETAIL()
    local title = GetTitleText()

    if IsControlKeyDown() and IsShiftKeyDown() then
        QuestHaste_AddAutoRepeat(title)
    elseif IsControlKeyDown() then
        QuestHaste_AddAutoAccept(title)
    elseif IsAltKeyDown() then
        QuestHaste_RemoveAutoAccept(title)
        QuestHaste_RemoveAutoRepeat(title)
        return
    end

    if QuestHaste_IsAutoRepeat(title) or QuestHaste.currentQuest == title or not QuestHaste_IsAutoAccept(title) ~= not IsShiftKeyDown() then
        AcceptQuest()
    else
        QuestHaste.currentQuest = ""
    end
end

function QuestHaste_EventHandler.ADDON_LOADED(name)
    if name == "QuestHaste" then
        QuestHaste_Session = {}
        if QuestHaste == nil or QuestHaste.autolist == nil then
            QuestHaste = {autolist = {}, dataVersion = "1.0.0"}
        end
        if QuestHaste.dataVersion == nil then
            local tmp = {}
            for k,_ in pairs(QuestHaste.autolist) do
                tmp[k] = {complete=true}
            end
            QuestHaste.autolist = tmp
            QuestHaste.dataVersion = "1.0.0"
        end
        QuestHaste_RegisterEvents()
        QuestHaste_EventHandler:UnregisterEvent("ADDON_LOADED")
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff88QuestHaste|r loaded. See /qhaste usage")
    end
end

QuestHaste_EventHandler:SetScript("OnEvent",
    function (_, event, ...)
        if QuestHaste_EventHandler[event] then
            QuestHaste_EventHandler[event](...)
        end
    end
)

function QuestHaste_IsAutoComplete(title)
    return QuestHaste.autolist[title] and QuestHaste.autolist[title].complete
end

function QuestHaste_IsAutoAccept(title)
    return QuestHaste.autolist[title] and QuestHaste.autolist[title].accept
end

function QuestHaste_IsAutoRepeat(title)
    return QuestHaste.autolist[title] and QuestHaste.autolist[title].loop
end

function QuestHaste_AddAutoComplete(title)
    if QuestHaste_IsAutoComplete(title) then return end
    if QuestHaste.autolist[title] == nil then QuestHaste.autolist[title] = {} end
    QuestHaste.autolist[title].complete = true
    local msg = "|cffffff88QuestHaste|r: |cffffff00"..title.."|r |cff00ff00added|r."
    UIErrorsFrame:AddMessage(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
end

function QuestHaste_AddAutoAccept(title)
    if QuestHaste_IsAutoAccept(title) then return end
    if QuestHaste.autolist[title] == nil then QuestHaste.autolist[title] = {} end
    QuestHaste.autolist[title].accept = true
    local msg = "|cffffff88QuestHaste|r: |cffffff00"..title.."|r |cff00ff00added|r."
    UIErrorsFrame:AddMessage(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
end

function QuestHaste_AddAutoRepeat(title)
    if QuestHaste_IsAutoRepeat(title) then return end
    if QuestHaste.autolist[title] == nil then QuestHaste.autolist[title] = {} end
    QuestHaste.autolist[title].loop = true
    QuestHaste_Session[title] = QuestHaste_Session[title] or 0
    local msg = "|cffffff88QuestHaste|r: |cffffd700"..title.."|r auto-repeat |cff00ff00enabled|r."
    UIErrorsFrame:AddMessage(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
end

function QuestHaste_RemoveAutoComplete(title)
    if not QuestHaste_IsAutoComplete(title) then return end
    if QuestHaste_IsAutoAccept(title) then
        QuestHaste.autolist[title].complete = false
    else 
        QuestHaste.autolist[title] = nil
    end
    local msg = "|cffffff88QuestHaste|r: |cffffff00"..title.."|r |cffff0000removed|r."
    UIErrorsFrame:AddMessage(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
end

function QuestHaste_RemoveAutoAccept(title)
    if not QuestHaste_IsAutoAccept(title) then return end
    -- FIX: this called the non-existent global QuestHaste_IsComplete
    -- (the real function is QuestHaste_IsAutoComplete), which raised a
    -- Lua error ("attempt to call global 'QuestHaste_IsComplete' (a nil
    -- value)") every time you Alt-clicked to forget a quest that also
    -- had auto-complete saved on it, and left the autolist entry
    -- half-cleaned-up since the function aborted mid-way.
    if QuestHaste_IsAutoComplete(title) then
        QuestHaste.autolist[title].accept = false
    else
        QuestHaste.autolist[title] = nil
    end
    local msg = "|cffffff88QuestHaste|r: |cffffff00"..title.."|r |cffff0000removed|r."
    UIErrorsFrame:AddMessage(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
end

function QuestHaste_RemoveAutoRepeat(title)
    if not QuestHaste_IsAutoRepeat(title) then return end
    QuestHaste.autolist[title].loop = nil
    if QuestHaste.autolist[title] and not (QuestHaste.autolist[title].accept or QuestHaste.autolist[title].complete) then
        QuestHaste.autolist[title] = nil
    end
    local msg = "|cffffff88QuestHaste|r: |cffffd700"..title.."|r auto-repeat |cffff0000disabled|r."
    UIErrorsFrame:AddMessage(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg)
end

function QuestHaste_Proceed()
    if GossipFrame:IsShown() then
        QuestHaste.currentQuest = GetGossipActiveQuests()
        SelectGossipActiveQuest(1)
    elseif QuestFrame:IsShown() then
        local title = GetTitleText()
        if QuestFrameAcceptButton:IsShown() then
            AcceptQuest()
        elseif QuestFrameCompleteButton:IsShown() and IsQuestCompletable() then
            QuestHaste.currentQuest = title
            CompleteQuest()
        elseif QuestFrameCompleteQuestButton:IsShown() and IsQuestCompletable() then
            GetQuestReward()
        end
    end
end

local function CommandParser(msg, editbox)
    local _,_,command, rest = string.find(msg,"^(%S*)%s*(.-)$")
    if command == "usage" then
        DEFAULT_CHAT_FRAME:AddMessage(QuestHaste_Usage)
    elseif command == "add" then
        if QuestFrame:IsShown() then
            local title = GetTitleText()
            QuestHaste_AddAutoComplete(title)
        else
            UIErrorsFrame:AddMessage("QuestHaste: no active quest.",1,0,0)
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
            UIErrorsFrame:AddMessage("QuestHaste: no active quest.",1,0,0)
        end
        QuestHaste_Proceed()
    --elseif command == "remove" then
    --    QuestHaste.autolist[title] = nil
    elseif command == "list" then
        DEFAULT_CHAT_FRAME:AddMessage("QuestHaste quest list:")
        for k,v in pairs(QuestHaste.autolist) do
            DEFAULT_CHAT_FRAME:AddMessage("    "..k)
            local opts = "        ("
            if QuestHaste_IsAutoAccept(k) then
                opts = opts .. "|cff00ff00"
            else
                opts = opts .. "|cffff0000"
            end
            opts = opts .. "accept|r | "
            if QuestHaste_IsAutoComplete(k) then
                opts = opts .. "|cff00ff00"
            else
                opts = opts .. "|cffff0000"
            end
            opts = opts .. "complete|r | "
            if QuestHaste_IsAutoRepeat(k) then
                opts = opts .. "|cffffd700"
            else
                opts = opts .. "|cffff0000"
            end
            opts = opts .. "repeat|r)"
            DEFAULT_CHAT_FRAME:AddMessage(opts)
        end
    elseif command == "pause" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff88QuestHaste|r: |cffff0000paused|r.")
        QuestHaste_UnregisterEvents()
    elseif command == "resume" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff88QuestHaste|r: |cff00ff00active|r.")
        QuestHaste_RegisterEvents()
    elseif command == "complete" then
        QuestHaste_Proceed()
    elseif command == "reset" then
        QuestHaste.autolist = {}
    else
        DEFAULT_CHAT_FRAME:AddMessage("Syntax:\n/qhaste usage\n/qhaste add\n/qhaste repeat\n/qhaste list\n/qhaste complete\n/qhaste pause\n/qhaste resume\n/qhaste reset");
    end
end
SLASH_QUESTHASTE1 = "/questhaste"
SLASH_QUESTHASTE2 = "/qhaste"
SlashCmdList["QUESTHASTE"] = CommandParser
