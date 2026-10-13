-------------------------------------------------------------------------
--
--	Copyright (c) 2019-2021 by Antoine Desmarets.
--	Cixi/Gaya of Remulos Oceanic / WoW Classic Horde
--
--	Dailies is distributed in the hope that it will be useful/entertaining
--	but WITHOUT ANY WARRANTY
--
-------------------------------------------------------------------------

-- Done in v031
--  - Updated ToC for Phase 2
--  - Updated Libraries
--  - Updated to use the newer C_GossipInfo API


-------------------------------------------------------------------------
-- ADDON VARIABLES
-------------------------------------------------------------------------
local dllocal_addonName, Dailies = ... -- the addon name and a table scoped to all addon files referenced in the .toc is passed in by the wow client
local dllocal_addon = LibStub("AceAddon-3.0"):NewAddon(Dailies, dllocal_addonName, "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0")

local AceGUI = LibStub("AceGUI-3.0")
local AceConfig = LibStub("AceConfig-3.0")
local _G = getfenv(0)


local dllocal_version = GetAddOnMetadata(dllocal_addonName, "Version")
local dllocal_statusText = string.format("v%s by Cixi/Gaya@Remulos", dllocal_version)	-- Default status text"
local dllocal_charKey = UnitName("player") .. "-" .. GetRealmName()					-- Character unique name
local dllocal_prefix = "Dailies_Channel"											-- used for addon chat communications
local dllocal_prefix_version = "Dailies_Version"									-- used for addon version check

local dllocal_expac = 3		-- default expac

local dllocal_ldb = LibStub("LibDataBroker-1.1")
local dllocal_Broker = nil
local dllocal_minimapicon = LibStub("LibDBIcon-1.0")
local dllocal_brokervalue = nil
local dllocal_brokerlabel = nil

local dllocal_filter_frame = nil		-- filter sub menu

-- Frame variables
local dllocal_initial = true			-- initial show of the frames
local dllocal_orderlist = {}			-- List of dailies in order
local dllocal_tabgroup = nil			-- tabgroup object 
local dllocal_tabkey = "todo"			-- currently viewed tab

local dllocal_inGuild = false			-- belong to a guild (for sending addon messages)
local dllocal_faction = ""				-- to mark quest as one or the other or both

local dllocal_fullWidth = 680			-- width of the frame
local dllocal_fullHeight = 600			-- height of the frame

local dllocal_questTabs = { ToDo = {}, Completed = {}, Ignored = {}, All = {} }	-- all quests in their respective tabs
local dllocal_info_heading				-- info panel Quest Heading
local dllocal_info_desc					-- info panel Quest Desc
local dllocal_info_npc					-- info panel Quest NPC
local dllocal_info_zone					-- info panel Quest Zone/Subzone
local dllocal_info_count				-- info panel Quest number of times done
local dllocal_info_record               -- info panel Quest fastest completion time
local dllocal_info_coords				-- info panel Coords
local dllocal_info_inst					-- related instance
local dllocal_info_attune				-- related Attune chain
local dllocal_tzdiff = 0 				-- timezone difference in minutes (to check UTC reset times)

local dllocal_timer_handle 				-- handle for the UI reload timer, to be able to cancel while results are still coming

local dllocal_debug = false             -- determine whether debug prints occur

-- Frame variables
local dllocal_frame						-- main frame
local dllocal_scroll					-- scroller inside of the TreeGroup right panel

dllocal_group	= {}				-- quest metadata 
dllocal_reps = {}					-- quest reputations
dllocal_repicons = {}				-- reputation icons
dllocal_repfaction = {}				-- reputation factions
dllocal_attuneId = {}				-- quest Attune IDs
dllocal_exclu = {}					-- mutually exclusive quests
dllocal_ProfessionNames = {} 		-- profession names in all locales

local dllocal_questLog = nil			-- cached snapshot of the quest log, see Dailies.RefreshQuestLog()
local dllocal_pendingDetail = nil		-- details of the daily last shown at a quest giver (confirmed on accept)
local dllocal_turnIn = nil				-- quest ID shown on the reward screen, waiting to be handed in
local dllocal_refreshTimer = nil		-- pending (debounced) list refresh


-------------------------------------------------------------------------
-- 3.3.5 COMPATIBILITY
-- The original addon was written for WotLK Classic (3.4.x). The helpers
-- below replace the Classic-only APIs. They are all local to the addon so
-- nothing leaks into, or gets overwritten from, the global namespace that
-- is shared with every other addon.
-------------------------------------------------------------------------

-- Debug printing
local function PrintHandler(message, debug)
	if dllocal_debug == true or debug == false then
		print(message)
	end
end

-- Minimal C_Timer replacement (C_Timer does not exist in 3.3.5)
local Timer = {}
do
	local timers = {}
	local timerFrame = CreateFrame("Frame")
	timerFrame:Hide()
	timerFrame:SetScript("OnUpdate", function(self)
		local now = GetTime()
		local i = 1
		while i <= #timers do
			local t = timers[i]
			if t.cancelled then
				table.remove(timers, i)
			elseif now >= t.fireAt then
				table.remove(timers, i)
				xpcall(t.callback, geterrorhandler())
			else
				i = i + 1
			end
		end
		if #timers == 0 then self:Hide() end
	end)

	local function Cancel(self) self.cancelled = true end

	function Timer.NewTimer(delay, callback)
		local t = { fireAt = GetTime() + (delay or 0), callback = callback, Cancel = Cancel }
		timers[#timers + 1] = t
		timerFrame:Show()
		return t
	end

	function Timer.After(delay, callback)
		Timer.NewTimer(delay, callback)
	end
end

-- GetPlayerLink() does not exist in 3.3.5
local function PlayerLink(name)
	return "|Hplayer:" .. name .. "|h[" .. name .. "]|h"
end

-- 3.3.5 names have no "-Realm" part, but strip one just in case
local function ShortName(name)
	if not name then return nil end
	return name:match("^([^%-]+)") or name
end

-- Profession names for the client language (enGB clients fall back to enUS)
local function GetProfessionNames()
	return dllocal_ProfessionNames[GetLocale()] or dllocal_ProfessionNames["enUS"] or {}
end

-- Known professions -> { [skillLineID] = rank }
-- In 3.3.5 a collapsed header in the Skills tab hides its skills from
-- GetSkillLineInfo(), so expand them for the scan and collapse them again after.
local function ScanProfessions()
	local byName = {}
	for id, name in pairs(GetProfessionNames()) do byName[name] = id end

	local collapsed = {}
	for i = GetNumSkillLines(), 1, -1 do
		local name, isHeader, isExpanded = GetSkillLineInfo(i)
		if isHeader and not isExpanded then
			collapsed[name] = true
			ExpandSkillHeader(i)
		end
	end

	local found = {}
	for i = 1, GetNumSkillLines() do
		local name, isHeader, _, skillRank = GetSkillLineInfo(i)
		if name and not isHeader and byName[name] then
			found[byName[name]] = skillRank
		end
	end

	if next(collapsed) then
		for i = GetNumSkillLines(), 1, -1 do
			local name, isHeader, isExpanded = GetSkillLineInfo(i)
			if isHeader and isExpanded and collapsed[name] then CollapseSkillHeader(i) end
		end
	end
	return found
end

-- Walk every quest in the log, including quests under collapsed headers
-- (in 3.3.5 a collapsed zone header hides its quests from GetQuestLogTitle()).
-- fn(index, title, isComplete, isDaily, questID) is called for each quest.
local function ForEachQuestInLog(fn)
	local collapsed = {}
	for i = GetNumQuestLogEntries(), 1, -1 do
		local title, _, _, _, isHeader, isCollapsed = GetQuestLogTitle(i)
		if isHeader and isCollapsed then
			collapsed[title] = true
			ExpandQuestHeader(i)
		end
	end

	for i = 1, GetNumQuestLogEntries() do
		local title, _, _, _, isHeader, _, isComplete, isDaily, questID = GetQuestLogTitle(i)
		if title and not isHeader and questID and questID > 0 then
			fn(i, title, isComplete, isDaily, questID)
		end
	end

	if next(collapsed) then
		for i = GetNumQuestLogEntries(), 1, -1 do
			local title, _, _, _, isHeader, isCollapsed = GetQuestLogTitle(i)
			if isHeader and not isCollapsed and collapsed[title] then CollapseQuestHeader(i) end
		end
	end
end

-- Snapshot of the quest log: [questID] = { title, complete, daily }
function Dailies.RefreshQuestLog()
	local log = {}
	ForEachQuestInLog(function(index, title, isComplete, isDaily, questID)
		log[questID] = {
			title = title,
			complete = (isComplete == 1 or isComplete == true),	-- -1 means failed
			daily = (isDaily == 1 or isDaily == true),
		}
	end)
	dllocal_questLog = log
	return log
end

local function QuestLog()
	return dllocal_questLog or Dailies.RefreshQuestLog()
end

function Dailies.FindQuestInLog(title)
	if not title then return nil end
	for questID, entry in pairs(QuestLog()) do
		if entry.title == title then return questID end
	end
	return nil
end

-- 3.3.5 has no GetQuestID(), so work out the ID of the quest currently shown
-- at the quest giver from its title:
--  1) the quest log (quest already accepted: QUEST_PROGRESS / QUEST_COMPLETE)
--  2) a real GetQuestID() if the client has one
--  3) quests we've already learned for our faction (any client language)
--  4) the English title list in DailiesData.lua
function Dailies.CurrentQuestID()
	local title = GetTitleText()
	if not title or title == "" then return nil end

	local id = Dailies.FindQuestInLog(title)
	if id then return id end

	if type(_G.GetQuestID) == "function" then
		local ok, gid = pcall(_G.GetQuestID)
		if ok and type(gid) == "number" and gid > 0 then return gid end
	end

	local sameFaction, otherFaction
	for kq, q in pairs(Dailies_Data.Quests) do
		if q.Title == title then
			if q.Factions and q.Factions[dllocal_faction] == 1 then sameFaction = kq
			else otherFaction = otherFaction or kq end
		end
	end
	return sameFaction or (dllocal_dailyids and dllocal_dailyids[title]) or otherFaction
end

-- Make sure this toon has a usable entry for a quest
function Dailies.EnsureToonQuest(id)
	local quests = Dailies_Data.Toons[dllocal_charKey].Quests
	local tq = quests[id]
	if type(tq) ~= "table" then
		tq = {}
		quests[id] = tq
	end
	if tq.Ignored == nil then tq.Ignored = false end
	if type(tq.Order) ~= "number" then
		local maxOrder = 0
		for _, other in pairs(quests) do
			if type(other) == "table" and type(other.Order) == "number" and other.Order > maxOrder then maxOrder = other.Order end
		end
		tq.Order = maxOrder + 1
	end
	if tq.TimesCompleted == nil then tq.TimesCompleted = 0 end
	return tq
end

-- Store (or refresh) what we know about a daily quest
function Dailies.RegisterDaily(id, info)
	if Dailies_Data.Quests[id] == nil then
		Dailies_Data.Quests[id] = {}
		if Dailies_Settings.showReceivedDailies then print("|cffff00ff[Dailies]|r New daily quest detected: |cffffd100" .. (info.Title or "?") .. "|r") end
	end
	local q = Dailies_Data.Quests[id]
	for k, v in pairs(info) do q[k] = v end
	q.Frequency = "Daily"
	if type(q.Factions) ~= "table" then q.Factions = {} end
	q.Factions[dllocal_faction] = 1
	if type(q.Seen) ~= "table" then q.Seen = {} end
	q.Seen[GetRealmName()] = 1

	Dailies.EnsureToonQuest(id)
	Dailies.MakeGroupDaily(id)
	return q
end

-- Tidy up saved data that older versions (or earlier errors) may have left half-written
function Dailies.SanitizeSavedData()
	if type(Dailies_Data.Quests) ~= "table" then Dailies_Data.Quests = {} end
	if type(Dailies_Data.Toons) ~= "table" then Dailies_Data.Toons = {} end

	-- quest IDs must be numbers and entries must be tables
	local badKeys = {}
	for k, q in pairs(Dailies_Data.Quests) do
		if type(k) ~= "number" or type(q) ~= "table" then badKeys[#badKeys + 1] = k end
	end
	for _, k in ipairs(badKeys) do
		local q = Dailies_Data.Quests[k]
		Dailies_Data.Quests[k] = nil
		local n = tonumber(k)
		if n and type(q) == "table" and Dailies_Data.Quests[n] == nil then Dailies_Data.Quests[n] = q end
	end

	for k, q in pairs(Dailies_Data.Quests) do
		if type(q.Title) ~= "string" or q.Title == "" then q.Title = "Quest #" .. k end
		if type(q.Text) ~= "string" then q.Text = "" end
		if type(q.Zone) ~= "string" then q.Zone = "" end
		if type(q.SubZone) ~= "string" then q.SubZone = "" end
		if type(q.NPC) ~= "string" then q.NPC = "" end
		q.Money = tonumber(q.Money) or 0
		q.Honor = tonumber(q.Honor) or 0
		q.Xp = tonumber(q.Xp) or 0
		if q.TodayUntil ~= nil then q.TodayUntil = tonumber(q.TodayUntil) end
		if type(q.Factions) ~= "table" then q.Factions = {} end
		if type(q.Seen) ~= "table" then q.Seen = {} end
	end

	for kt, t in pairs(Dailies_Data.Toons) do
		if type(t) ~= "table" then
			Dailies_Data.Toons[kt] = nil
		elseif type(t.Quests) ~= "table" then
			t.Quests = {}
		else
			for kq, tq in pairs(t.Quests) do
				if type(tq) ~= "table" then t.Quests[kq] = nil end
			end
		end
	end

	if type(Dailies_Settings.minimapButtonPosition) ~= "table" then Dailies_Settings.minimapButtonPosition = {} end
end

-- Daily completion tracking.
-- On 3.3.5 servers daily quests never appear in the "completed quests" list
-- (GetQuestsCompleted), so the addon keeps its own record: a daily counts as
-- done if we handed it in after the most recent daily reset.
function Dailies.IsCompletedToday(kq)
	if Dailies.AlreadyHaveQuest(kq) then return false end	-- still in the log, so not handed in

	local tq = Dailies_Data.Toons[dllocal_charKey] and Dailies_Data.Toons[dllocal_charKey].Quests[kq]
	if tq and tq.Completed then
		return tq.Completed >= Dailies.LastResetTime()
	end
	return false
end

-- Called once a hand-in has been confirmed
function Dailies.RecordCompletion(id)
	local q = Dailies_Data.Quests[id]
	if not q then return end
	local tq = Dailies.EnsureToonQuest(id)
	local now = time()

	-- a daily can only be handed in once per reset: never count it twice
	if tq.Completed and tq.Completed >= Dailies.LastResetTime() then return end

	tq.Completed = now
	tq.TimesCompleted = (tq.TimesCompleted or 0) + 1

	if type(tq.Duration) ~= "table" then tq.Duration = {} end
	local d = tq.Duration
	if tq.Accepted and now >= tq.Accepted then
		d.Current = now - tq.Accepted
		if d.Fastest == nil or d.Current < d.Fastest then d.Fastest = d.Current end
		if d.Slowest == nil or d.Current > d.Slowest then d.Slowest = d.Current end
	end
	tq.Accepted = nil

	local toon = Dailies_Data.Toons[dllocal_charKey]
	toon.TotalGold = (toon.TotalGold or 0) + (q.Money or 0)
	toon.TotalDailies = (toon.TotalDailies or 0) + 1
	Dailies_Data.TotalGold = (Dailies_Data.TotalGold or 0) + (q.Money or 0)
	Dailies_Data.TotalDailies = (Dailies_Data.TotalDailies or 0) + 1

	-- if it came from a random pool (fishing, cooking, dungeon...), it was today's one
	Dailies.MakeGroupDaily(id)
	Dailies.ScheduleRefresh(0.2)
end

-- Every hand-in goes through GetQuestReward(). Count the quest once it has
-- actually left the log (a hand-in can be refused, e.g. with full bags).
hooksecurefunc("GetQuestReward", function()
	local id = dllocal_turnIn
	dllocal_turnIn = nil
	if not id or not Dailies_Data or not Dailies_Data.Quests or not Dailies_Data.Quests[id] then return end

	local attempts = 0
	local function check()
		attempts = attempts + 1
		if not Dailies.RefreshQuestLog()[id] then
			Dailies.RecordCompletion(id)
		elseif attempts < 4 then
			Timer.After(1.5, check)
		end
	end
	Timer.After(0.5, check)
end)

-- Debounced refresh of the quest buckets / broker / open window
function Dailies.ScheduleRefresh(delay)
	if dllocal_refreshTimer then dllocal_refreshTimer:Cancel() end
	dllocal_refreshTimer = Timer.NewTimer(delay or 1, function()
		dllocal_refreshTimer = nil
		if dllocal_frame and dllocal_frame:IsVisible() then
			Dailies.ShowTabContent()		-- re-classifies as well
		else
			Dailies.ClassifyQuests()
		end
	end)
end

-- Today's to-do daily with this title, if any
function Dailies.ToDoQuestByTitle(title)
	if not title then return nil end
	for id in pairs(dllocal_questTabs.ToDo) do
		if Dailies_Data.Quests[id] and Dailies_Data.Quests[id].Title == title then return id end
	end
	return nil
end

-- Gossip quest lists. In 3.3.5 GetGossipAvailableQuests() returns 5 values per
-- quest (title, level, isTrivial, isDaily, isRepeatable) and
-- GetGossipActiveQuests() returns 4 (title, level, isTrivial, isComplete).
-- The stride is worked out from the counts in case a server sends otherwise.
local function GossipStride(num, default, ...)
	local total = select("#", ...)
	if num and num > 0 and total >= num and total % num == 0 then return total / num end
	return default
end

local function CollectGossipQuests(stride, ...)
	local quests = {}
	for i = 1, select("#", ...), stride do
		local title, level, isTrivial, flag4 = select(i, ...)
		quests[#quests + 1] = { title = title, level = level, isTrivial = isTrivial, flag4 = flag4 }
	end
	return quests
end

local function GossipAvailableQuests()
	local stride = GossipStride(GetNumGossipAvailableQuests(), 5, GetGossipAvailableQuests())
	local quests = CollectGossipQuests(stride, GetGossipAvailableQuests())
	for _, quest in ipairs(quests) do
		-- only trust the daily flag when the layout is the known 3.3.5 one
		if stride == 5 then quest.isDaily = quest.flag4 and true or false end
	end
	return quests
end

local function GossipActiveQuests()
	local stride = GossipStride(GetNumGossipActiveQuests(), 4, GetGossipActiveQuests())
	return CollectGossipQuests(stride, GetGossipActiveQuests())
end

local dllocal_options = {
    name = "Dailies",
    handler = Dailies,
    type = "group",
    args = {
		spacer10 = {
			type = "description",
			name = " ",
			width = "full",
			order = 10,
		},
		showMinimapButton = {
			type = "toggle",
			name = "Show the Minimap button",
			desc = "Display a Minimap button to quickly access the addon interface or options.",
			get = function(info) return not Dailies_Settings.minimapButtonPosition.hide end,
			set = function(info, val)
					if val then dllocal_minimapicon:Show("Dailies_Broker") else dllocal_minimapicon:Hide("Dailies_Broker") end
					Dailies_Settings.minimapButtonPosition.hide = not val
					Dailies_Settings.showMinimapButton = val
				end,
			width = "full",
			order = 20,
		},		
		spacer20 = {
			type = "description",
			name = " ",
			width = "full",
			order = 30,
		},
		runScanOnLogin = {
			type = "toggle",
			name = "Perform an automatic scan on login",
			desc = "This runs a scan to find out about today's dailies when you enter the game.",
			get = function(info) return Dailies_Settings.runScanOnLogin end,
			set = function(info, val) Dailies_Settings.runScanOnLogin = val end,
			width = "full",
			order = 40,
		},
		scanForAnyDailies = {
			type = "toggle",
			name = "Scan for all daily quests, not just today's dailies",
			desc = "Check this to make the scan look for *any* daily quest, not just the dailies specific to today.",
			get = function(info) return Dailies_Settings.scanForAnyDailies end,
			set = function(info, val) Dailies_Settings.scanForAnyDailies = val end,
			width = "full",
			order = 50,
		},
		serverDailyResetTime = {
			type = "range",
			name = "Fallback Daily Reset Hour (UTC)",
			desc = "The reset time is normally read from the server. This hour (UTC) is only used if the server doesn't report it.",
            min = 0,
            max = 23,
            step = 1,
			get = function(info) return Dailies_Settings.serverDailyResetTime end,
			set = function(info, val) Dailies_Settings.serverDailyResetTime = val end,
			width = "full",
			order = 60,
		},
		spacer30 = {
			type = "description",
			name = " ",
			width = "full",
			order = 70,
		},
		showReceivedDailies = {
			type = "toggle",
			name = "Show incoming messages about today's dailies",
			desc = "This lets you know via a chat message when you receive the information about today's dailies from another player.",
			get = function(info) return Dailies_Settings.showReceivedDailies end,
			set = function(info, val) Dailies_Settings.showReceivedDailies = val end,
			width = "full",
			order = 80,
		},
		showQuestRewardTotal = {
			type = "toggle",
			name = "Display the total gold and reputation to be earned",
			desc = "This adds a summary line at the bottom of the daily list with the gold and repuration totals.",
			get = function(info) return Dailies_Settings.showQuestRewardTotal end,
			set = function(info, val) 
				Dailies_Settings.showQuestRewardTotal = val
				if dllocal_frame and dllocal_frame:IsVisible() then Dailies.ShowTabContent() end
			end,
			width = "full",
			order = 90,
		},
		showQuestInfoPanel = {
			type = "toggle",
			name = "Display the quest information panel",
			desc = "This opens up a little panel below the quest list and provides the quest description, quest giver name and area.",
			get = function(info) return Dailies_Settings.showQuestInfoPanel end,
			set = function(info, val) 
				Dailies_Settings.showQuestInfoPanel = val
				if dllocal_frame and dllocal_frame:IsVisible() then Dailies.ShowTabContent() end
			end,
			width = "full",
			order = 100,
		},
		showOnlyForKnownProfessions = {
			type = "toggle",
			name = "Only show profession quests for known professions",
			desc = "This will hide quests related to professions this toon doesn't have.",
			get = function(info) return Dailies_Settings.showOnlyForKnownProfessions end,
			set = function(info, val) 
				Dailies_Settings.showOnlyForKnownProfessions = val
				if dllocal_frame and dllocal_frame:IsVisible() then Dailies.ShowTabContent() end
			end,
			width = "full",
			order = 105,
		},
		spacer40 = {
			type = "description",
			name = " ",
			width = "full",
			order = 110,
		},
		autoAcceptQuests = {
			type = "toggle",
			name = "Auto-accept quests in your to-do list",
			desc = "This will automatically accept any quest from your To-Do list whenever you acces the quest giver.",
			get = function(info) return Dailies_Settings.autoAcceptQuests end,
			set = function(info, val) Dailies_Settings.autoAcceptQuests = val end,
			width = "full",
			order = 120,
		},
		autoCompleteQuests = {
			type = "toggle",
			name = "Auto-complete quests in your to-do list",
			desc = "This will automatically complete any quest from your To-Do list whenever you acces the quest giver - Assuming there is no reward to pick.",
			get = function(info) return Dailies_Settings.autoCompleteQuests end,
			set = function(info, val) Dailies_Settings.autoCompleteQuests = val end,
			width = "full",
			order = 130,
		},
		spacer50 = {
			type = "description",
			name = " ",
			width = "full",
			order = 140,
		},
		showTBCDailies = {
			type = "toggle",
			name = "Show TBC Dailies",
			desc = "Show dailies linked to The Burning Crusade content.",
			get = function(info) return Dailies_Settings.showTBCDailies end,
			set = function(info, val) 
				Dailies_Settings.showTBCDailies = val 
				-- need async otherwise the quest is not detected as completed
				Dailies.ScheduleRefresh(0.2)
			end,
			width = "full",
			order = 150,
		},
		showWotLKDailies = {
			type = "toggle",
			name = "Show WotLK Dailies",
			desc = "Show dailies linked to Wrath of the Lich King content.",
			get = function(info) return Dailies_Settings.showWotLKDailies end,
			set = function(info, val)
				Dailies_Settings.showWotLKDailies = val 
				-- need async otherwise the quest is not detected as completed
				Dailies.ScheduleRefresh(0.2)
			end,
			width = "full",
			order = 160,
		},
		showSeasonalDailies = {
			type = "toggle",
			name = "Show Seasonal Dailies",
			desc = "Show dailies linked to seasonal events (like Brewfest or Midsummer Fire Festival for example).",
			get = function(info) return Dailies_Settings.showSeasonalDailies end,
			set = function(info, val) 
				Dailies_Settings.showSeasonalDailies = val 
				-- need async otherwise the quest is not detected as completed
				Dailies.ScheduleRefresh(0.2)
			end,
			width = "full",
			order = 170,
		},
		showWrathDungeonDailies = {
			type = "toggle",
			name = "Show Wrath Dungeon Dailies",
			desc = "Show dailies linked to Wrath of the Lich King dungeons (removed with patch 3.3, Icecrown Citadel).",
			get = function(info) return Dailies_Settings.showWrathDungeonDailies end,
			set = function(info, val) 
				Dailies_Settings.showWrathDungeonDailies = val 
				-- need async otherwise the quest is not detected as completed
				Dailies.ScheduleRefresh(0.2)
			end,
			width = "full",
			order = 180,
		},
		spacer4 = {
			type = "description",
			name = " \n \n \n ",
			width = "full",
			order = 190,
		},
		credits = {
			type = "description",
			name = " Join the discord server to bugs/suggestions/comments:\n |cffffd100https://discord.gg/MpfDeBZ|r\n\n Hope you like the addon,\n /Hug from Cixi/Gaya @ Remulos Horde",
			width = "full",
			fontSize = "medium",
			order = 200,
		},
	}
}


-- Thanks to Roadblock on Discord for this cool little snippet suggestion (and many other coding bits!)
-- I know you'll read this, thanks ;-)
local capture = _G.ERR_CHAT_PLAYER_NOT_FOUND_S:gsub("%%s","(.+)")
local function noPlayerFilter(self,event,msg,sender,...)
	local noPlayer = msg:match(capture)
  	if noPlayer then
	    return true
  	else -- other system message just let it pass through
	    return false, msg, sender, ...
  	end
end

function Dailies:AddFilter()
	-- re-adding an already added filter is automatically ignored
	if not Dailies._filterActive then
		ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", noPlayerFilter)
		Dailies._filterActive = true
		PrintHandler("Filter |cff00ff00Active|r", true)
	end
end

function Dailies:RemoveFilter()
	-- trying to remove a non-existent filter doesn't error no extra checks needed
	if Dailies._filterActive then
		ChatFrame_RemoveMessageEventFilter("CHAT_MSG_SYSTEM", noPlayerFilter)
		Dailies._filterActive = nil
		PrintHandler("Filter |cffff0000Inactive|r", true)
	end
end

-------------------------------------------------------------------------
-- EVENT: Addon is Initialized
-------------------------------------------------------------------------

function Dailies:OnInitialize()
	LibStub("AceConfig-3.0"):RegisterOptionsTable("Dailies", dllocal_options, nil)
	LibStub("AceConfigDialog-3.0"):AddToBlizOptions("Dailies"):SetParent(InterfaceOptionsFramePanelContainer)
	--AceConfig:RegisterOptionsTable(dllocal_addonName.."_cmd", nil, nil)
	print("|cffff00ff[Dailies]|r "..dllocal_statusText)
end

-- mark new today's daily
-- /run Dailies.MakeGroupDaily(11341)

-- /run Dailies_Data = {}

-- /run print(C_QuestLog.GetQuestInfo(11377))
-- /run print(C_QuestLog.GetQuestObjectives(11377))
-- /run print(C_QuestLog.IsQuestFlaggedCompleted(11379))
-- https://wowwiki-archive.fandom.com/wiki/World_of_Warcraft_API#Quest
-- https://wowwiki-archive.fandom.com/wiki/Events/Quest

-------------------------------------------------------------------------
-- EVENT: Addon is enabled
-------------------------------------------------------------------------

function Dailies:OnEnable()
	-- Called when the addon is enabled
	self:RegisterEvent("QUEST_DETAIL")					--	get quest details from quest screen, even if not accepted
	self:RegisterEvent("QUEST_ACCEPTED")				-- 	quest accept
	self:RegisterEvent("QUEST_FINISHED")				--	quest window closed
	self:RegisterEvent("UNIT_QUEST_LOG_CHANGED")		--  used to check quest abandons
	self:RegisterEvent("QUEST_LOG_UPDATE")				--  invalidates the cached quest log
	self:RegisterEvent("QUEST_COMPLETE")				--  reward screen: remembers the quest for hand-in tracking, auto-complete (step 2)
	self:RegisterEvent("QUEST_PROGRESS")				--  used to trigger auto-complete (step 1)
	self:RegisterEvent("GOSSIP_SHOW")					--  used to trigger auto-complete and auto-accept
	self:RegisterEvent("QUEST_GREETING")				--  same, for quest givers that use the quest greeting window instead of gossip
	-- Guild info is often not ready yet at login on 3.3.5, so always listen for it
	self:RegisterEvent("GUILD_ROSTER_UPDATE")
	self:RegisterEvent("PLAYER_GUILD_UPDATE")
	dllocal_inGuild = IsInGuild() and true or false
	if dllocal_inGuild then GuildRoster() end

	local _,_,_,v = GetBuildInfo()
	dllocal_expac = Dailies.Round((tonumber(v) or 30300)/10000,0)


	dllocal_tzdiff = time() - time(date("!*t"))			--  pick up the timezone offset
	PrintHandler(dllocal_tzdiff, true)
	-- example tzdiff
	-- 36000 in Sydney (+10h)
	-- 34200 in Adelaide (+9.5h)

	Dailies:RegisterComm(dllocal_prefix)
	Dailies:RegisterComm(dllocal_prefix_version)

	dllocal_faction = UnitFactionGroup("player")

	if Dailies_Data == nil then Dailies_Data = {} end

	-- adding the Toons group to make the saved data clearer
	if Dailies_Data.Toons == nil then
		Dailies_Data.Toons = {}
		-- moving any existing toon group to the new Toons group for backward compatibility
		for kt, t in pairs(Dailies_Data) do --all toons

			if type(kt) == "string" and string.find(kt, "-") then --key has a hyphen so it's a toon
				Dailies_Data.Toons[kt] = t 		-- add new
				Dailies_Data[kt] = nil			-- remove old
			end
		end
	end

	if Dailies_Data.Quests == nil then Dailies_Data.Quests = {} end
	if Dailies_Settings == nil then Dailies_Settings = {} end
	Dailies.SanitizeSavedData()

	if Dailies_Data.Toons[dllocal_charKey] == nil then Dailies_Data.Toons[dllocal_charKey] = {} end
	if Dailies_Data.Toons[dllocal_charKey].Quests == nil then Dailies_Data.Toons[dllocal_charKey].Quests = {} end
	if Dailies_Data.Toons[dllocal_charKey].TotalGold == nil then Dailies_Data.Toons[dllocal_charKey].TotalGold = 0 end
	if Dailies_Data.Toons[dllocal_charKey].TotalDailies == nil then Dailies_Data.Toons[dllocal_charKey].TotalDailies = 0 end
	--if Dailies_Data.Toons[dllocal_charKey].RepFilter == nil then Dailies_Data.Toons[dllocal_charKey].RepFilter = nil end -- unneeded, nil is default


	if Dailies_Data.TotalGold == nil then Dailies_Data.TotalGold = 0 end
	if Dailies_Data.TotalDailies == nil then Dailies_Data.TotalDailies = 0 end


	if Dailies_Settings.showReceivedDailies == nil then Dailies_Settings.showReceivedDailies = true end
	if Dailies_Settings.showQuestInfoPanel == nil then Dailies_Settings.showQuestInfoPanel = true end
	if Dailies_Settings.showOnlyForKnownProfessions == nil then Dailies_Settings.showOnlyForKnownProfessions = true end

	if Dailies_Settings.showQuestRewardTotal == nil then Dailies_Settings.showQuestRewardTotal = true end
	if Dailies_Settings.autoAcceptQuests == nil then Dailies_Settings.autoAcceptQuests = false end
	if Dailies_Settings.autoCompleteQuests == nil then Dailies_Settings.autoCompleteQuests = false end
	if Dailies_Settings.showMinimapButton == nil then Dailies_Settings.showMinimapButton = true end
	if Dailies_Settings.minimapButtonPosition == nil then Dailies_Settings.minimapButtonPosition = {} end

	if Dailies_Settings.runScanOnLogin == nil then Dailies_Settings.runScanOnLogin = true end
	if Dailies_Settings.scanForAnyDailies == nil then Dailies_Settings.scanForAnyDailies = false end
	if Dailies_Settings.serverDailyResetTime == nil then Dailies_Settings.serverDailyResetTime = 6 end

	if Dailies_Settings.showSeasonalDailies == nil then Dailies_Settings.showSeasonalDailies = true end
	if Dailies_Settings.showTBCDailies == nil then Dailies_Settings.showTBCDailies = true end
	if Dailies_Settings.showWotLKDailies == nil then Dailies_Settings.showWotLKDailies = true end
	if Dailies_Settings.showWrathDungeonDailies == nil then Dailies_Settings.showWrathDungeonDailies = false end


	-- set defaults for existing dailies on new toons
	for kq, q in pairs(Dailies_Data.Quests) do

		q.Text = q.Text:gsub("\n", "#N#") -- replace extra slashes
		q.Text = q.Text:gsub("\\r", "")
		q.Text = q.Text:gsub("\\", "")
		q.Text = q.Text:gsub("#N##N#", "#N#")
		--q.Text = q.Text:gsub("#R#", "\r")
		q.Text = q.Text:gsub("#N#", "\n")

		Dailies.EnsureToonQuest(kq)

		if dllocal_temp[kq] == nil then
			--add up the seen realm for non temp quests
			q.Seen[GetRealmName()] = 1
		end

	end

	-- find out what professions this toon has, as some quests are prof specific
	Dailies_Data.Toons[dllocal_charKey].Professions = ScanProfessions() -- rebuilt each login, to keep up to date


	-- detect any daily quest that the player might already have in their log
	ForEachQuestInLog(function(index, questTitle, isComplete, isDaily, questID)
		if (isDaily == 1 or isDaily == true) and Dailies_Data.Quests[questID] == nil then
			-- quest log rewards are read from the selected entry
			local previous = GetQuestLogSelection()
			SelectQuestLogEntry(index)
			local money = GetQuestLogRewardMoney() or 0
			local honor = (GetQuestLogRewardHonor and GetQuestLogRewardHonor()) or 0
			SelectQuestLogEntry(previous or 0)

			Dailies.RegisterDaily(questID, {
				Title = questTitle or "",
				Text = "Placeholder. This will be populated next time you take the quest.",
				Money = money,
				Xp = 0,
				Honor = honor,
				SubZone = "",			-- will be populated later
				Zone = "",				-- will be populated later
				NPC = "",				-- will be populated later
			})
		end
	end)

	Dailies.ClassifyQuests()

	if Dailies_Settings.runScanOnLogin then
		-- Ask guildies for today's dailies once guild info has had time to arrive
		Timer.After(9, function()
			if IsInGuild() then
				print("|cffff00ff[Dailies]|r Sending automatic request for "..(Dailies_Settings.scanForAnyDailies and "all" or "today's") .. " dailies.")
				Dailies:SendCommMessage(dllocal_prefix, (Dailies_Settings.scanForAnyDailies and "GET_ALL_DAILIES" or "GET_TODAYS_DAILIES"), "GUILD", "")
			end
		end)
	end


	Dailies_Broker = Dailies_Broker or dllocal_ldb:NewDataObject("Dailies_Broker", {
		type = "data source",
		label = "Dailies",
		text = "Click me!",
		icon = "Interface\\AddOns\\Dailies\\Images\\dailies",
		OnClick = function(self, button)
			if button=="LeftButton" then
				dllocal_frame = Dailies.getFrame()
			elseif button=="RightButton" then
				InterfaceOptionsFrame_Show()
				-- called twice: the first call doesn't always scroll to the panel on 3.3.5
				InterfaceOptionsFrame_OpenToCategory("Dailies")
				InterfaceOptionsFrame_OpenToCategory("Dailies")
			end
		end,
		OnTooltipShow = function(tooltip)
			tooltip:AddLine("|cFFffffffDailies|r |cff808080v"..dllocal_version.."|r")

			if 	dllocal_brokerlabel ~= nil and dllocal_brokervalue ~= nil then
				tooltip:AddLine(" ")
				if dllocal_brokerlabel == "All Done!" then
					tooltip:AddLine("|cffc0c0c0Next Step:|r None!")
				else
					tooltip:AddLine("|cffc0c0c0Next Step:|r |cffffffff" .. dllocal_brokervalue .. " the |r"..dllocal_brokerlabel.."|cffffffff quest|r.")
				end
				Dailies_Broker.text = dllocal_brokervalue .. " " .. dllocal_brokerlabel
			end

			tooltip:AddLine(" ")
			tooltip:AddLine("|cffffd100Left Click   |rOpen quest list\n|cffffd100Right Click |rOpen settings", 0.2, 1, 0.2)
		end,
	})

	if Dailies_Broker and dllocal_brokervalue and dllocal_brokerlabel then Dailies_Broker.text = dllocal_brokervalue .. " " .. dllocal_brokerlabel end

	dllocal_minimapicon:Register("Dailies_Broker", Dailies_Broker, Dailies_Settings.minimapButtonPosition)
	if Dailies_Settings.minimapButtonPosition.hide 
	then dllocal_minimapicon:Hide("Dailies_Broker"); dllocal_minimapicon:Hide("Dailies_Broker") 
	else dllocal_minimapicon:Show("Dailies_Broker"); dllocal_minimapicon:Show("Dailies_Broker") 
	end

end

-------------------------------------------------------------------------
-- EVENT: Addon is disabled
-------------------------------------------------------------------------

function Dailies:OnDisable()
	-- Called when the addon is disabled
	print("|cffff00ff[Dailies]|r Addon disabled")
end

-------------------------------------------------------------------------

function Dailies:QUEST_DETAIL(event)
	PrintHandler("Quest shown", true)
	dllocal_pendingDetail = nil

	if not (QuestIsDaily and QuestIsDaily()) then return end

	local info = {
		Title = GetTitleText() or "",
		Text = GetObjectiveText() or "",
		Frequency = "Daily",
		Money = GetRewardMoney() or 0,
		Xp = (GetRewardXP and GetRewardXP()) or 0,
		Honor = (GetRewardHonor and GetRewardHonor()) or 0,
		SubZone = GetSubZoneText() or "",
		Zone = GetZoneText() or "",
		TodayUntil = Dailies.DailyResetTime(),
		NPC = UnitName("npc") or UnitName("target") or "",
	}
	-- kept until the quest is accepted, where the quest log gives us the real ID
	dllocal_pendingDetail = info

	local id = Dailies.CurrentQuestID()
	if not id then
		PrintHandler("No quest ID yet for " .. info.Title .. ", it will be recorded when accepted", true)
		return
	end

	--log this quest information
	Dailies.RegisterDaily(id, info)
	Dailies.ClassifyQuests()
	if dllocal_frame and dllocal_frame:IsVisible() then Dailies.ShowTabContent() end

	-- spam the info
	local ser = id.."|"..Dailies.serialize(Dailies_Data.Quests[id]):gsub(" = ", "="):gsub("   ", ""):gsub(" }", "}")
	if IsInGuild() then
		Dailies:SendCommMessage(dllocal_prefix, ser, "GUILD", "")
	end

	-- auto-accept if needed
	if dllocal_questTabs.ToDo[id] and Dailies_Settings.autoAcceptQuests then
		AcceptQuest()
	end
end

-------------------------------------------------------------------------

function Dailies:QUEST_ACCEPTED(event, logIndex)
	dllocal_questLog = nil

	-- 3.3.5 passes the quest log index; the 9th value of GetQuestLogTitle is the quest ID
	local title, _, _, _, isHeader, _, _, isDaily, id = GetQuestLogTitle(logIndex or 0)
	local pending = dllocal_pendingDetail
	dllocal_pendingDetail = nil

	if isHeader or not id or id == 0 then
		-- the index didn't point at the quest: find it by the title shown at the quest giver
		title = pending and pending.Title
		id = Dailies.FindQuestInLog(title)
		isDaily = id and QuestLog()[id].daily and 1 or nil
	end
	if not id then return end

	-- a daily we couldn't identify at the quest giver (unknown title, other client language,
	-- shared quest...): record it now that we know its ID
	if Dailies_Data.Quests[id] == nil then
		if pending and pending.Title == title then
			Dailies.RegisterDaily(id, pending)
		elseif isDaily == 1 or isDaily == true then
			Dailies.RegisterDaily(id, {
				Title = title or "",
				Text = "Placeholder. This will be populated next time you take the quest.",
				Money = 0, Xp = 0, Honor = 0, SubZone = "", Zone = "", NPC = "",
				TodayUntil = Dailies.DailyResetTime(),
			})
		end
	end

	if Dailies_Data.Quests[id] then
		local tq = Dailies.EnsureToonQuest(id)
		tq.Accepted = time()
		tq.Completed = nil
		if type(tq.Duration) ~= "table" then tq.Duration = {} end
		tq.Duration.Last = tq.Duration.Current
		tq.Duration.Current = nil

		-- need async otherwise the quest is not detected as completed
		Dailies.ScheduleRefresh(1)
	end
end

-------------------------------------------------------------------------

function Dailies:QUEST_FINISHED(event)
	-- Just refresh the UI when quest dialog closes
	-- Hand-ins are tracked through the GetQuestReward hook (see RecordCompletion)
	dllocal_questLog = nil
	Dailies.ScheduleRefresh(1)
end

-------------------------------------------------------------------------

function Dailies:QUEST_COMPLETE(event)
	-- Reward screen. Remember which quest it is: it is counted as completed
	-- only once it has actually been handed in (GetQuestReward hook).
	dllocal_questLog = nil
	local id = Dailies.CurrentQuestID()
	dllocal_turnIn = id

	-- auto-complete if needed (only when there's no reward to pick and nothing to pay)
	if id and dllocal_questTabs.ToDo[id] and Dailies_Settings.autoCompleteQuests then
		local choices = GetNumQuestChoices() or 0
		local cost = (GetQuestMoneyToGet and GetQuestMoneyToGet()) or 0
		if choices <= 1 and cost <= 0 then
			GetQuestReward(choices)
		end
	end
end

-------------------------------------------------------------------------

function Dailies:QUEST_PROGRESS(event)
	local id = Dailies.CurrentQuestID()

	-- auto-complete if needed
	if id and dllocal_questTabs.ToDo[id] and Dailies_Settings.autoCompleteQuests and IsQuestCompletable() then
		CompleteQuest()
	end
end

-------------------------------------------------------------------------

function Dailies:GOSSIP_SHOW(event)
	if not (Dailies_Settings.autoAcceptQuests or Dailies_Settings.autoCompleteQuests) then return end
	Dailies.ClassifyQuests()		-- up to date to-do list and quest log

	-- auto accepts
	if Dailies_Settings.autoAcceptQuests then
		for index, quest in ipairs(GossipAvailableQuests()) do
			if quest.isDaily ~= false and Dailies.ToDoQuestByTitle(quest.title) then
				SelectGossipAvailableQuest(index)
				return
			end
		end
	end

	-- auto completes
	if Dailies_Settings.autoCompleteQuests then
		for index, quest in ipairs(GossipActiveQuests()) do
			local id = Dailies.ToDoQuestByTitle(quest.title)
			if id and Dailies.ReadyToComplete(id) then
				SelectGossipActiveQuest(index)
				return
			end
		end
	end
end

-------------------------------------------------------------------------

-- Some quest givers use the quest greeting window instead of gossip
function Dailies:QUEST_GREETING(event)
	if not (Dailies_Settings.autoAcceptQuests or Dailies_Settings.autoCompleteQuests) then return end
	Dailies.ClassifyQuests()

	if Dailies_Settings.autoAcceptQuests then
		for i = 1, (GetNumAvailableQuests() or 0) do
			if Dailies.ToDoQuestByTitle(GetAvailableTitle(i)) then
				SelectAvailableQuest(i)
				return
			end
		end
	end

	if Dailies_Settings.autoCompleteQuests then
		for i = 1, (GetNumActiveQuests() or 0) do
			local id = Dailies.ToDoQuestByTitle((GetActiveTitle(i)))
			if id and Dailies.ReadyToComplete(id) then
				SelectActiveQuest(i)
				return
			end
		end
	end
end

-------------------------------------------------------------------------

function Dailies:QUEST_LOG_UPDATE(event)
	dllocal_questLog = nil		-- re-read next time it's needed
end

-------------------------------------------------------------------------

function Dailies:UNIT_QUEST_LOG_CHANGED(event, unit)
	if unit and unit ~= "player" then return end	-- also fires for party members
	dllocal_questLog = nil

	if dllocal_frame and dllocal_frame:IsVisible() then
		Dailies.ScheduleRefresh(0.5) -- slight delay for the quest to be abandonned *before* the log refresh
	end

end

-------------------------------------------------------------------------

function Dailies:GUILD_ROSTER_UPDATE(event, canRequestUpdate)
	self._guildOnlineCache = self._guildOnlineCache or {}
	dllocal_inGuild = IsInGuild() and true or false
	for i=1, GetNumGuildMembers(true) do
		local name, rank, rankIndex, level, class, zone, note, officernote, online = GetGuildRosterInfo(i)
		if name and name ~= _G.UNKNOWNOBJECT then
			self._guildOnlineCache[ShortName(name)] = online and true or false
		end
	end
end

-------------------------------------------------------------------------

function Dailies:PLAYER_GUILD_UPDATE(event, unit)
	-- 3.3.5 may fire this without a unit
	if unit == nil or UnitIsUnit(unit,"player") then
		dllocal_inGuild = IsInGuild() and true or false
		if dllocal_inGuild then GuildRoster() end
	end
end

-------------------------------------------------------------------------
-- /dump Dailies.DailyResetTime()
-- /dump date("!*t", 1644210000)
-- /dump date("!*t")

-- Time (epoch seconds) of the next daily quest reset
function Dailies.DailyResetTime()
	-- The server reports the time left until the reset; that is right whatever
	-- the realm's timezone or reset hour is.
	-- (Right after login it can briefly return garbage, hence the range check.)
	if GetQuestResetTime then
		local secs = GetQuestResetTime()
		if secs and secs > 0 and secs <= 86400 then
			local nextReset = time() + secs
			if Dailies_Settings then Dailies_Settings.knownResetTime = nextReset end
			return nextReset
		end
	end

	-- Fallback 1: roll the last reset time the server gave us forward to the next one
	local known = Dailies_Settings and tonumber(Dailies_Settings.knownResetTime)
	if known then
		local now = time()
		if known <= now then known = known + (math.floor((now - known) / 86400) + 1) * 86400 end
		return known
	end

	-- Fallback 2: the reset hour (UTC) from the settings
	local reset = Dailies_Settings.serverDailyResetTime or 6

	local time_utc = date("!*t")

	-- next day if we're just past the reset time
	if time_utc.hour*60+time_utc.min >= reset*60 then time_utc.day = time_utc.day + 1 end
	time_utc.hour = reset
	time_utc.min = 0
	time_utc.sec = 0

	return time(time_utc) + dllocal_tzdiff
end

-- Time (epoch seconds) of the most recent daily quest reset
function Dailies.LastResetTime()
	return Dailies.DailyResetTime() - 86400
end

-------------------------------------------------------------------------
-- Create the Main UI Frame
-------------------------------------------------------------------------

function Dailies.getFrame()

	-- professions may have been learned/unlearned since login
	Dailies_Data.Toons[dllocal_charKey].Professions = ScanProfessions()

	-- if view already exists, just return it
	 if dllocal_frame then
		Dailies.ShowTabContent()
		dllocal_frame:Show()
		dllocal_filter_frame.frame:Show()
		return dllocal_frame 
	end

	dllocal_frame = AceGUI:Create("Frame", "DailiesFrame")
	dllocal_frame:SetTitle("  Dailies")
	dllocal_frame:SetStatusText(dllocal_statusText)
	dllocal_frame:SetHeight(dllocal_fullHeight)
	dllocal_frame:SetWidth(dllocal_fullWidth)

	if dllocal_frame.frame.SetResizeBounds then
		dllocal_frame.frame:SetResizeBounds(dllocal_fullWidth, dllocal_fullHeight)
	else 
		dllocal_frame.frame:SetMinResize(dllocal_fullWidth, dllocal_fullHeight)
		dllocal_frame.frame:SetMaxResize(dllocal_fullWidth, 3000)
	end
	dllocal_frame:SetLayout("Flow")

--	dllocal_frame:ClearAllPoints()
--	dllocal_frame:SetPoint("TOPLEFT", UIParent, "TOPRIGHT", 0, 0)

    -- Register the global variable `Dailies_MainFrame` as a "special frame"
    -- so that it is closed when the escape key is pressed.
	_G["Dailies_MainFrame"] = dllocal_frame.frame
	tinsert(UISpecialFrames, "Dailies_MainFrame")


	dllocal_frame.frame:SetFrameStrata("HIGH")

	-- Hacking into the Ace3 frame to reduce the size of the statusbox, to allow us room for other buttons
	local closebutton, statusbg, _, _, _, _, _ = dllocal_frame.content.obj.frame:GetChildren()
	statusbg:ClearAllPoints()
	statusbg:SetPoint("BOTTOMLEFT", 15, 14)     -- taken from AceGUIContainer-Frame.lua
	statusbg:SetPoint("BOTTOMRIGHT", -398, 14)  -- taken from AceGUIContainer-Frame.lua, modified from -132
	closebutton:SetWidth(80)


	-- Tabs 
	dllocal_tabgroup = AceGUI:Create("TabGroup")
	dllocal_tabgroup:SetTabs({{value="todo", text="To Do"}, {value="completed", text="Completed"}, {value="ignored", text="Ignored"}, {value="all", text="All Dailies"}, {value="stats", text="Statistics"}})
	dllocal_tabgroup:SelectTab("todo")
	dllocal_tabgroup:SetLayout("flow")
	dllocal_tabgroup:SetFullWidth(true)
	dllocal_tabgroup:SetFullHeight(true)
	dllocal_tabgroup:SetCallback("OnGroupSelected", function(source, event, tabkey)
		dllocal_tabkey = tabkey
		Dailies.ShowTabContent()
	end)
	dllocal_frame:AddChild(dllocal_tabgroup)
	
	--Dailies.ShowTabContent()


	-- SCAN BUTTON
	local scanbutton = CreateFrame("Button", "Dailies_ScanButton", dllocal_frame.content.obj.frame, "UIPanelButtonTemplate")
	scanbutton:SetPoint("BOTTOMRIGHT", -110, 17)
	scanbutton:SetFrameStrata("DIALOG")
	scanbutton:SetHeight(20)
	scanbutton:SetWidth(80)
	scanbutton:SetText("Scan")
	
	scanbutton:SetScript("OnEnter", function() dllocal_frame:SetStatusText("Scan guildies for dailies.") end)
	scanbutton:SetScript("OnLeave", function() dllocal_frame:SetStatusText(dllocal_statusText) end)
	scanbutton:SetScript("OnClick", function()
		if IsInGuild() then
			Dailies:SendCommMessage(dllocal_prefix, (Dailies_Settings.scanForAnyDailies and "GET_ALL_DAILIES" or "GET_TODAYS_DAILIES"), "GUILD", "") 
		end
--		Dailies:SendCommMessage(dllocal_prefix, (Dailies_Settings.scanForAnyDailies and "GET_ALL_DAILIES" or "GET_TODAYS_DAILIES"), "YELL", "")
		print("|cffff00ff[Dailies]|r Sending request for "..(Dailies_Settings.scanForAnyDailies and "all" or "today's") .. " dailies.")
	end)



	-- FILTER DROPDOWN
	dllocal_filter_frame = AceGUI:Create("Dropdown")
	dllocal_filter_frame:SetWidth(200)
	dllocal_filter_frame.frame:SetFrameStrata("DIALOG")
	dllocal_filter_frame:SetPoint("TOPRIGHT", scanbutton,"TOPLEFT", -5, 2)
	-- this AceGUI version only adds items once a list exists
	dllocal_filter_frame:SetList({})
	dllocal_filter_frame:AddItem(0, "|TInterface\\AddOns\\Dailies\\Images\\ignored:16|t No reputation filter")
	if dllocal_repicons then
		local function FactionName(id) return GetFactionInfoByID(id) or ("Faction " .. id) end
		for kr, r in Dailies.spairs(dllocal_repicons, function(t,a,b)
			return FactionName(a) < FactionName(b) end) do --sorted reps
			dllocal_filter_frame:AddItem(kr, "|T" .. r .. ":16|t " .. FactionName(kr))
		end
	end
	dllocal_filter_frame:SetCallback("OnValueChanged", function(widget, event, value)
		if value == nil or value == 0 then Dailies_Data.Toons[dllocal_charKey].RepFilter = nil
		else Dailies_Data.Toons[dllocal_charKey].RepFilter = value
		end
		Dailies.ShowTabContent()
	end )
	if Dailies_Data.Toons[dllocal_charKey].RepFilter == nil then dllocal_filter_frame:SetValue(0) 
	else dllocal_filter_frame:SetValue(Dailies_Data.Toons[dllocal_charKey].RepFilter) 
	end

	-- Register the global variable `Dailies_MainFrame` as a "special frame"
    -- so that it is closed when the escape key is pressed.
	_G["Dailies_RepFilterFrame"] = dllocal_filter_frame.frame
	tinsert(UISpecialFrames, "Dailies_RepFilterFrame")

	closebutton:SetScript("OnClick", function() 
		dllocal_filter_frame.frame:Hide()	
		dllocal_frame:Hide()
	
	end)



	Dailies.ShowTabContent()



	dllocal_frame:Show()

	dllocal_initial = false
	return dllocal_frame

end

-------------------------------------------------------------------------

function Dailies.ShowTabContent()

	if dllocal_tabgroup ~= nil then 

		dllocal_tabgroup:ReleaseChildren()

		if dllocal_tabkey == "stats" then 

			local one_q = 0
			local one_g = 0
			local all_q = 0
			local all_g = 0
			local one_fav = ""
			local one_cnt = 0
			local all_fav = ""
			local all_cnt = 0
			local one_fastest_name = ""
			local one_fastest_val = 999999999
			local all_fastest_name = ""
			local all_fastest_val = 999999999

			for kt, t in pairs(Dailies_Data.Toons) do --all toons

				for kd, d in pairs(t.Quests) do --all dailies

					if Dailies_Data.Quests[kd] then 
						if d.TimesCompleted and d.TimesCompleted > 0 then 
							all_q = all_q + d.TimesCompleted
							if Dailies_Data.Quests[kd] and Dailies_Data.Quests[kd].Money then 
								all_g = all_g + ( d.TimesCompleted * Dailies_Data.Quests[kd].Money)
							end
							if d.TimesCompleted > all_cnt then 
								all_cnt = d.TimesCompleted
								all_fav = Dailies_Data.Quests[kd].Title
							end
							if d.Duration and d.Duration.Fastest and d.Duration.Fastest < all_fastest_val then 
								all_fastest_val = d.Duration.Fastest
								all_fastest_name = Dailies_Data.Quests[kd].Title
							end

							--toon stats
							if kt == dllocal_charKey then 
								one_q = one_q + d.TimesCompleted
								if Dailies_Data.Quests[kd] and Dailies_Data.Quests[kd].Money then 
									one_g = one_g + ( d.TimesCompleted * Dailies_Data.Quests[kd].Money)
								end
								if d.TimesCompleted > one_cnt then 
									one_cnt = d.TimesCompleted
									one_fav = Dailies_Data.Quests[kd].Title
								end
								if d.Duration and d.Duration.Fastest and d.Duration.Fastest < one_fastest_val then 
									one_fastest_val = d.Duration.Fastest
									one_fastest_name = Dailies_Data.Quests[kd].Title
								end
							end 
						end
					end
				end
			end

			local stats = AceGUI:Create("SimpleGroup")
			stats:SetFullWidth(true)
			stats:SetAutoAdjustHeight(true)
			stats:SetLayout("Flow")

				local meh = AceGUI:Create("Label")
				meh:SetText("\n Here's a few meaningless statistics collected about your dailies")
				meh:SetFullWidth(true)
				meh:SetFont(GameFontNormal:GetFont(), 12)
				stats:AddChild(meh)

				local spacer = AceGUI:Create("Label")
				spacer:SetText(" ")
				spacer:SetFullWidth(true)
				spacer:SetFont(GameFontNormal:GetFont(), 12)
				stats:AddChild(spacer)

				local oneh = AceGUI:Create("Heading")
				oneh:SetText("|cffffffff" .. dllocal_charKey .. "|r")
				oneh:SetFullWidth(true)
				stats:AddChild(oneh)

				local oneq = AceGUI:Create("Label")
				oneq:SetText("\n    Total daily quests completed:  |cffffd100" .. one_q .. "|r")
				oneq:SetFullWidth(true)
				oneq:SetFont(GameFontNormal:GetFont(), 12)
				stats:AddChild(oneq)

				local oneg = AceGUI:Create("Label")
				oneg:SetText("\n    Total gold from daily quests:  " .. GetMoneyString(one_g, true))
				oneg:SetFullWidth(true)
				oneg:SetFont(GameFontNormal:GetFont(), 12)
				stats:AddChild(oneg)

				local onem = AceGUI:Create("Label")
				if one_cnt > 0 then 
					onem:SetText("\n    Most repeated daily:  |cffffd100" .. one_fav .. "|r (" .. one_cnt .. " times)")
				else
					onem:SetText("\n    Most repeated daily:  |cffffd100-|r")
				end
				onem:SetFullWidth(true)
				onem:SetFont(GameFontNormal:GetFont(), 12)
				stats:AddChild(onem)

				local onef = AceGUI:Create("Label")
				if one_fastest_name ~= "" then 
					onef:SetText("\n    Fastest completed daily:  |cffffd100" .. one_fastest_name .. "|r (" .. Dailies.formatTime(one_fastest_val) .. ")")
				else
					onef:SetText("\n    Fastest completed daily:  |cffffd100-|r")
				end
				onef:SetFullWidth(true)
				onef:SetFont(GameFontNormal:GetFont(), 12)
				stats:AddChild(onef)



				local spacer = AceGUI:Create("Label")
				spacer:SetText(" ")
				spacer:SetFullWidth(true)
				spacer:SetFont(GameFontNormal:GetFont(), 12)
				stats:AddChild(spacer)

				local clearOne = AceGUI:Create("Button")
				clearOne:SetText("Reset data for this toon")
				clearOne:SetCallback("OnClick", function() 
					for kq, q in pairs(Dailies_Data.Toons[dllocal_charKey].Quests) do 
						q.TimesCompleted = nil
					end
					Dailies.ShowTabContent()
				end)
				stats:AddChild(clearOne)

				local spacer = AceGUI:Create("Label")
				spacer:SetText(" ")
				spacer:SetFullWidth(true)
				spacer:SetFont(GameFontNormal:GetFont(), 12)
				stats:AddChild(spacer)




				local allh = AceGUI:Create("Heading")
				allh:SetText("|cffffffffAcross all characters|r")
				allh:SetFullWidth(true)
				stats:AddChild(allh)

				local allq = AceGUI:Create("Label")
				allq:SetText("\n    Total daily quests completed:  |cffffd100" .. all_q .. "|r")
				allq:SetFullWidth(true)
				allq:SetFont(GameFontNormal:GetFont(), 12)
				stats:AddChild(allq)

				local allg = AceGUI:Create("Label")
				allg:SetText("\n    Total gold from daily quests:  " .. GetMoneyString(all_g, false))
				allg:SetFullWidth(true)
				allg:SetFont(GameFontNormal:GetFont(), 12)
				stats:AddChild(allg)

				local allm = AceGUI:Create("Label")
				if all_cnt > 0 then 
					allm:SetText("\n    Most repeated daily:  |cffffd100" .. all_fav .. "|r (" .. all_cnt .. " times)")
				else
					allm:SetText("\n    Most repeated daily:  |cffffd100-|r")
				end
				allm:SetFullWidth(true)
				allm:SetFont(GameFontNormal:GetFont(), 12)
				stats:AddChild(allm)

				local allf = AceGUI:Create("Label")
				if all_fastest_name ~= "" then 
					allf:SetText("\n    Fastest completed daily:  |cffffd100" .. all_fastest_name .. "|r (" .. Dailies.formatTime(all_fastest_val) .. ")")
				else
					allf:SetText("\n    Fastest completed daily:  |cffffd100-|r")
				end
				allf:SetFullWidth(true)
				allf:SetFont(GameFontNormal:GetFont(), 12)
				stats:AddChild(allf)

				local spacer = AceGUI:Create("Label")
				spacer:SetText(" ")
				spacer:SetFullWidth(true)
				spacer:SetFont(GameFontNormal:GetFont(), 12)
				stats:AddChild(spacer)

				local clearAll = AceGUI:Create("Button")
				clearAll:SetText("Reset all data")
				clearAll:SetCallback("OnClick", function() 
					for kt, t in pairs(Dailies_Data.Toons) do 
						for kq, q in pairs(t.Quests) do 
							q.TimesCompleted = nil
						end
					end
					Dailies.ShowTabContent()
				end)
				stats:AddChild(clearAll)

			dllocal_tabgroup:AddChild(stats)


		else

			local showTotal = Dailies_Settings.showQuestRewardTotal
			if dllocal_tabkey == "all" then showTotal = false end			-- removing totals from the ALL tab, as they are wrong (all dungeon dailies counted for example)

			Dailies.ClassifyQuests()
			
			local scroll = AceGUI:Create("ScrollFrame")
			scroll:SetLayout("Flow")
			scroll:SetFullWidth(true)
			local hh = 0
			if Dailies_Settings.showQuestInfoPanel then 
				hh = hh  + 130		--	130 is the size of the info panel
			end

			if showTotal then 
				hh = hh  + 45		--	45 is the size of the info panel
			end

			local lastHeight = nil
			scroll.frame:SetScript("OnUpdate", function()
				-- auto resize scroll zone when frame is resized
				if Dailies_Settings.showQuestInfoPanel or showTotal then
					local height = dllocal_frame.frame:GetHeight() - 120 - hh  --120 is the offset for the frame
					if height ~= lastHeight then
						lastHeight = height
						scroll:SetHeight(height)
					end
				end
			end)
			-- AceGUI recycles widgets: take the script off again, otherwise it keeps
			-- resizing whatever addon gets this scroll frame next
			scroll:SetCallback("OnRelease", function(widget)
				widget.frame:SetScript("OnUpdate", nil)
			end)

			if hh ~= 0 then 
				scroll:SetHeight(dllocal_frame.frame:GetHeight() - 120 - hh)  --120 is the offset for the frame
				scroll:SetAutoAdjustHeight(false)
			else
				scroll:SetFullHeight(true)
			end

			dllocal_tabgroup:AddChild(scroll)



			local count = 0
			dllocal_orderlist = {}

			local completedGroups = {}  -- used to not repeat completed quests from the same group
			local listedGroups = {}  -- used to not repeat completed quests from the same group
			
			local list = dllocal_questTabs.ToDo
			if dllocal_tabkey == "all" then list = dllocal_questTabs.All end 
			if dllocal_tabkey == "completed" then list = dllocal_questTabs.Completed end 
			if dllocal_tabkey == "ignored" then list = dllocal_questTabs.Ignored end 


			local totalGold = 0
			local totalHonor = 0
			local totalReps = {}
			local previousHeader = ""
			local fullday = 24 * 60 * 60
			local lastReset = Dailies.LastResetTime()

			for kq, ql in Dailies.spairs(list,
				function(t,a,b) 	
					if dllocal_tabkey == "all" then 
						return 	(dllocal_group[a] and dllocal_group[a].group or "ZZZ") .. "_" ..
								(Dailies_Data.Quests[a].Zone or "YYY") .. "_" ..
								Dailies_Data.Quests[a].Title 
								< 
								(dllocal_group[b] and dllocal_group[b].group or "ZZZ") .. "_" ..
								(Dailies_Data.Quests[b].Zone or "YYY") .. "_" ..
								Dailies_Data.Quests[b].Title

					else 
						return 	Dailies_Data.Toons[dllocal_charKey].Quests[a].Order < Dailies_Data.Toons[dllocal_charKey].Quests[b].Order 
					end
				end) do --all dailies

				local q = Dailies_Data.Quests[kq]

				local expac = 2
				if kq > 12000 	or kq == 11153		or kq == 11472		or kq == 11940		or kq == 11960		or kq == 11945		or kq == 11391		then expac = 3 end

				if (Dailies_Settings.showTBCDailies and expac == 2) or (Dailies_Settings.showWotLKDailies and expac == 3) then 
					
					if dllocal_seasonal[kq] == nil or (Dailies_Settings.showSeasonalDailies and dllocal_seasonal[kq] ~= nil) then 

						local header = string.upper(dllocal_group[kq] and dllocal_group[kq].group or "")
						if header == "" then header = string.upper(q.Zone or "") end
						if header == "" then header = "OTHER (Missing Zone)" end

						-- only mark as completed those that actually got completed in the group.
						-- by default the API marks all quests of a group as completed together, so we need to check our data to know which one.
						local completed = Dailies.IsCompletedToday(kq)
						--if completed and q.TodayUntil == nil then completed = false end  
						
		--				if completed and Dailies_Data.Toons[dllocal_charKey].Quests[kq].Completed == nil then completed = false end  
		--				
		--				if q.TodayUntil ~= nil then 
		--					if t.Quests[kq].Completed > q.TodayUntil - fullday then 

						-- add to listed groups to avoid the generic group line
						if completed and dllocal_group[kq] then listedGroups[dllocal_group[kq].group] = true; end
						if Dailies_Data.Toons[dllocal_charKey].Quests[kq].Ignored and dllocal_group[kq] then listedGroups[dllocal_group[kq].group] = true; end

						dllocal_orderlist[Dailies.count(dllocal_orderlist)+1] = kq

						-- Check if we already have the quest in our log
						local alreadyHaveIt = Dailies.AlreadyHaveQuest(kq)


						-- Now check if that quest if part of a group where you can only have 1 of the group at the time
						-- for example the fishing daily, or the cooking daily, or the daily dungeon

						-- logic to follow:
						--  - if you already have the quest, then show that.
						--  - if it is the daily, then show it UNLESS we already have one of that group in our log.
						--  - if the quest is not daily and not already in log, skip it
						--  - if we've done one from the group, skip all and put a placeholder with the group name
						--  - if we know the daily and it's not the one we have, then add an alternative line to say this quest can be picked up instead if needed

						local todaysDaily = true
						-- if a group, check if it's todays
						--AD if dllocal_group[kq] then if dllocal_group[kq].today == nil then todaysDaily = false end	end
						if q.TodayUntil == nil then 
							todaysDaily = false
						elseif time() > q.TodayUntil then
							q.TodayUntil = nil
							todaysDaily = false 
						end

						local haveAnotherAlready = false
						if dllocal_group[kq] then  -- part of a group
							for kq2, q2 in pairs(dllocal_group) do 
								if dllocal_group[kq2].group == dllocal_group[kq].group and kq2 ~= kq then
									if Dailies.AlreadyHaveQuest(kq2) then 
										haveAnotherAlready = true 
										--print("disregarding "..kq.. " since " .. kq2 .. " is already selected")
									end
								end
							end
						end


						-- add to listed groups to avoid the generic group line
						if dllocal_group[kq] and listedGroups[dllocal_group[kq].group] == nil then listedGroups[dllocal_group[kq].group] = true end
						


						if header ~= previousHeader and dllocal_tabkey == "all" then  
							local head = AceGUI:Create("Label")
							if previousHeader ~= "" then head:SetText("\n" .. header)
							else head:SetText(header)  end -- display the header, add a blank row first if not the first header
							head:SetFullWidth(true)
							-- head:SetJustifyH("LEFT")
							head:SetFont(GameFontNormal:GetFont(), 12)
							
							scroll:AddChild(head)
						end 


						--Compact view
						local tit = "|cffffd100" .. q.Title .. "|r"
						local status = "|TInterface\\AddOns\\Dailies\\Images\\available:16|t"
						local desc = "This quest is available for you to pick up."
						if alreadyHaveIt then 
							if Dailies.ReadyToComplete(kq) then 
								status = "|TInterface\\AddOns\\Dailies\\Images\\selecteddone:16|t"; 
								desc = "This quest is ready to turn in."
								tit = "|cff00ff00" .. q.Title .. "|r" -- green is quest is ready to turn in 
							else
								status = "|TInterface\\AddOns\\Dailies\\Images\\selected:16|t";
								desc = "You have that quest in your quest log."
							end
						end

						-- Pool quests (dungeon, heroic, fishing, cooking...): only one of the pool is offered
						-- each day, so unless this is known to be today's one, don't present it as available.
						if dllocal_group[kq] and not todaysDaily and not alreadyHaveIt then
							local poolName = dllocal_group[kq].group
							local todaysPick = nil
							for kq2 in pairs(dllocal_group) do
								if kq2 ~= kq and dllocal_group[kq2].group == poolName and Dailies_Data.Quests[kq2]
										and Dailies_Data.Quests[kq2].TodayUntil and Dailies_Data.Quests[kq2].TodayUntil > time() then
									todaysPick = kq2
								end
							end
							status = "|TInterface\\AddOns\\Dailies\\Images\\nottoday:16|t"
							tit = "|cff808080" .. q.Title .. "|r"
							if todaysPick then
								desc = "Part of the " .. poolName .. " pool, but not today's quest.\nToday's is |cffffd100" .. Dailies_Data.Quests[todaysPick].Title .. "|r|cffa0a0a0."
							else
								desc = "Part of the " .. poolName .. " pool: only one of these is offered each day.\nToday's isn't known yet, so it may or may not be this one."
							end
						end

						if completed then status = "|TInterface\\AddOns\\Dailies\\Images\\completed:16|t"; desc = "You have completed this quest today" end 
						if Dailies_Data.Toons[dllocal_charKey].Quests[kq].Ignored then status = "|TInterface\\AddOns\\Dailies\\Images\\ignored:16|t"; desc = "You are ignoring this quest" end 

						-- check if any other toon has already completed this quest and add them to the tool tip
						local otherCompleted = ""

						for kt, t in pairs(Dailies_Data.Toons) do --all toons
							if t.Quests[kq] and t.Quests[kq].Completed ~= nil then
								if t.Quests[kq].Completed >= lastReset then
									otherCompleted = otherCompleted .. "\n" ..  " |TInterface\\AddOns\\Dailies\\Images\\completed:16|t " .. kt
								end
							end
						end

						local quest = AceGUI:Create("SimpleGroup")
						quest:SetFullWidth(true)
						quest:SetAutoAdjustHeight(true)
						quest:SetLayout("Flow")
							local showprof = true
							if dllocal_group[kq] then 
								if dllocal_group[kq].short then 
									tit = tit .. "|cff808080 - |r|cffffffff" .. dllocal_group[kq].short .. "|r"
								end

								if dllocal_tabkey ~= "all" then 
									tit = tit .. "|cff808080 - " .. dllocal_group[kq].group .. "|r"
								end
								showprof = false
							end

							if dllocal_prof[kq] and showprof then
								local profName = GetProfessionNames()[dllocal_prof[kq]]
								if profName then
									tit = tit .. "|cff808080 - " .. profName .. "|r"
								end
							end

							if dllocal_seasonal[kq] then 
								tit = tit .. "|cff808080 - Seasonal|r"
							end

							local title = AceGUI:Create("InteractiveLabel")
							title:SetText(status.." "..tit)
							if dllocal_tabkey ~= "all" then 
								title:SetWidth(380)
							else
								title:SetWidth(380 +20 +20)  --to make up for the arrows being hidden
							end
							-- title:SetJustifyH("LEFT")
							title:SetFont(GameFontNormal:GetFont(), 12)
							title:SetCallback("OnEnter", function() 
								GameTooltip:SetOwner(title.frame,"ANCHOR_NONE")
								GameTooltip:SetPoint("TOPLEFT", title.frame,"BOTTOMLEFT", 20, -8)
								local dd = desc
								if Dailies_Settings.showQuestInfoPanel then dd = dd .. "\nClick for more info." end

								if otherCompleted ~= "" then dd = dd .. "\n\n|cffffffffAlready completed by:\n"..otherCompleted.."|r" end
								GameTooltip:SetText("|cffa0a0a0" .. dd .. "|r")
							end)

							title:SetCallback("OnClick", function() 
								if Dailies_Settings.showQuestInfoPanel then 
									if q.NPC and q.NPC ~= "" then 
										dllocal_info_npc:SetText("Quest giver: |cffffd100" .. q.NPC .. "|r") 
									else
										dllocal_info_npc:SetText("Quest giver: |cffffd100-|r") 
									end 
									if q.Zone and q.Zone ~= "" then dllocal_info_zone:SetText(q.Zone) else dllocal_info_zone:SetText("- ") end 

									local timesCompleted = 0
									if Dailies_Data.Toons[dllocal_charKey].Quests[kq].TimesCompleted then 
										timesCompleted = Dailies_Data.Toons[dllocal_charKey].Quests[kq].TimesCompleted
									end
									dllocal_info_count:SetText("Times completed: |cffffd100" .. timesCompleted.."|r")

                                    if Dailies_Data.Toons[dllocal_charKey].Quests[kq].Duration ~= nil and Dailies_Data.Toons[dllocal_charKey].Quests[kq].Duration.Fastest ~= nil then
                                        dllocal_info_record:SetText("Fastest completion: |cffffd100" .. Dailies.formatTime(Dailies_Data.Toons[dllocal_charKey].Quests[kq].Duration.Fastest) .. "|r")
                                    else
                                        dllocal_info_record:SetText("")
                                    end
									if q.SubZone and q.SubZone ~= ""  then dllocal_info_coords:SetText(q.SubZone) else dllocal_info_coords:SetText("- ") end
									if q.Text then 
										--dllocal_info_desc:SetText("\n|cffa0a0a0" .. q.Text:gsub("\\\\", "\\") .. "|r"); 
										dllocal_info_desc:SetText("\n|cffa0a0a0" .. q.Text .. "|r"); 
										-- dllocal_info_desc:SetJustifyH("LEFT") 
									end
									if q.Title then dllocal_info_heading:SetText("|cffffffff" .. q.Title .. "|r") end


									if dllocal_group[kq] and dllocal_group[kq].long then 
										dllocal_info_inst:SetText("Instance: |cffffd100" .. dllocal_group[kq].long .. "|r");
										dllocal_info_inst.frame:Show()
									else 
										dllocal_info_inst:SetText("") 
										dllocal_info_inst.frame:Hide()
									end
									
									dllocal_info_attune:SetText("") 
									dllocal_info_attune.frame:Hide()
									if dllocal_attuneId[kq] and Attune_Data then 

										local attId = nil
										if type(dllocal_attuneId[kq]) == "table" then attId = dllocal_attuneId[kq][dllocal_faction] else attId = dllocal_attuneId[kq] end

										for i, a in pairs(Attune_Data.attunes) do
											if tonumber(a.ID) == attId then
												dllocal_info_attune:SetText("Click to open Attune on: |cffffd100" .. a.NAME .. "|r")
												dllocal_info_attune.frame:Show()

												dllocal_info_attune:SetCallback("OnClick", function() 
													if Attune_Data then 
														Attune_SlashCommandHandler("")
														Attune_Select("" .. attId)
													end
												end)					
											end
										end
									end

								end

							end)
							title:SetCallback("OnLeave", function() GameTooltip:Hide() end)
							quest:AddChild(title)



							local repText = ""
							local tooltip = ""
							if q.Honor > 0 then 
								repText = q.Honor .. " |TInterface\\AddOns\\Dailies\\Images\\pvp-arenapoints-icon:16|t"  
								tooltip = "|TInterface\\AddOns\\Dailies\\Images\\pvp-arenapoints-icon:16|t |cffa0a0a0+" .. q.Honor .. " Honor Points|r"
							end
							totalHonor = totalHonor + q.Honor
							if dllocal_reps[kq] then 
								for kr, r in Dailies.spairs(dllocal_reps[kq], function(t,a,b) 	return a < b end) do --sorted reps
									if dllocal_repfaction[kr] == nil or dllocal_repfaction[kr] == dllocal_faction then 
										repText = "  |T" .. dllocal_repicons[kr] .. ":16|t" .. repText
										local name, _, _, _, _, earnedValue = GetFactionInfoByID(kr)
										tooltip = "|T" .. dllocal_repicons[kr] .. ":16|t |cffa0a0a0+" .. r .. " " .. (name or "Unknown Reputation") .. " rep|r\n" .. tooltip
										if totalReps[kr] == nil then totalReps[kr] = r else totalReps[kr] = totalReps[kr] + r end
									end
								end
							end
							local rep = AceGUI:Create("InteractiveLabel")
							rep:SetText(repText)
							rep:SetWidth(60)
							-- rep:SetJustifyH("RIGHT")
							rep:SetFont(GameFontNormal:GetFont(), 12)
							if tooltip ~= "" then 
								rep:SetCallback("OnEnter", function() 
									GameTooltip:SetOwner(rep.frame,"ANCHOR_NONE")
									GameTooltip:SetPoint("TOPLEFT", rep.frame,"TOPRIGHT", 10, 3)
									GameTooltip:SetText(tooltip)
								end)				
								rep:SetCallback("OnLeave", function() GameTooltip:Hide() end)
							end
							quest:AddChild(rep)



							local rewardText = ""
							if q.Money > 0 then rewardText = GetMoneyString(q.Money, true) end
							totalGold = totalGold + q.Money
							local reward = AceGUI:Create("InteractiveLabel")
							reward:SetText(rewardText)
							reward:SetWidth(80)
							-- reward:SetJustifyH("RIGHT")
							reward:SetFont(GameFontNormal:GetFont(), 12)
							quest:AddChild(reward)

							-- don't show arrows on All tab (quests are sorted by group)
							if dllocal_tabkey ~= "all" then 
								local moveup = AceGUI:Create("InteractiveLabel")
								moveup:SetWidth(20)
								-- moveup:SetJustifyH("CENTER")
								moveup:SetCallback("OnEnter", function() 
									GameTooltip:SetOwner(moveup.frame,"ANCHOR_NONE")
									GameTooltip:SetPoint("TOPLEFT", moveup.frame,"BOTTOMLEFT", 10, 0)
									GameTooltip:SetText("Move this daily up")
								end)				
								moveup:SetCallback("OnLeave", function() GameTooltip:Hide() end)
								if count == 1 then 
									moveup:SetDisabled(true)
									moveup:SetText("|TInterface\\AddOns\\Dailies\\Images\\moveup:16|t")
								else
									moveup:SetText("|TInterface\\AddOns\\Dailies\\Images\\moveup:16|t")
									moveup:SetCallback("OnClick", function() 
										local prev = 0
										for ko, o in pairs(dllocal_orderlist) do 
											if o == kq then prev = dllocal_orderlist[ko-1] end
										end
											
										if prev ~= nil and prev ~= 0 then  -- checking if top of list
											local ord = Dailies_Data.Toons[dllocal_charKey].Quests[prev].Order
											Dailies_Data.Toons[dllocal_charKey].Quests[prev].Order = Dailies_Data.Toons[dllocal_charKey].Quests[kq].Order
											Dailies_Data.Toons[dllocal_charKey].Quests[kq].Order = ord
											Dailies.ShowTabContent()
										end
									end)
								end
								quest:AddChild(moveup)

										
								local movedn = AceGUI:Create("InteractiveLabel")
								movedn:SetWidth(20)
								-- movedn:SetJustifyH("CENTER")
								movedn:SetCallback("OnEnter", function() 
									GameTooltip:SetOwner(movedn.frame,"ANCHOR_NONE")
									GameTooltip:SetPoint("TOPLEFT", movedn.frame,"BOTTOMLEFT", 10, 0)
									GameTooltip:SetText("Move this daily down")
								end)
								movedn:SetCallback("OnLeave", function() GameTooltip:Hide() end)
								movedn:SetText("|TInterface\\AddOns\\Dailies\\Images\\movedn:16|t")
								movedn:SetCallback("OnClick", function() 
									local prev = 0
									--print(Dailies.count(dllocal_orderlist))
									for ko, o in pairs(dllocal_orderlist) do 
										if o == kq then prev = dllocal_orderlist[ko+1] end
									end
									
									if prev ~= nil and prev ~= 0 then  -- checking if bottom of list
										local ord = Dailies_Data.Toons[dllocal_charKey].Quests[prev].Order
										Dailies_Data.Toons[dllocal_charKey].Quests[prev].Order = Dailies_Data.Toons[dllocal_charKey].Quests[kq].Order
										Dailies_Data.Toons[dllocal_charKey].Quests[kq].Order = ord
										Dailies.ShowTabContent()
									end
								end)
								quest:AddChild(movedn)
							end

							local ignore = AceGUI:Create("InteractiveLabel")
							-- ignore:SetJustifyH("CENTER")
							--if dllocal_tabkey ~= "ignored" then 
							if Dailies_Data.Toons[dllocal_charKey].Quests[kq].Ignored == false then 
								ignore:SetText("|TInterface\\AddOns\\Dailies\\Images\\ignored:16|t")
								ignore:SetWidth(20)
								ignore:SetCallback("OnClick", function() 
									Dailies_Data.Toons[dllocal_charKey].Quests[kq].Ignored = true
									Dailies.ShowTabContent()
								end)
								ignore:SetCallback("OnEnter", function() 
									GameTooltip:SetOwner(ignore.frame,"ANCHOR_NONE")
									GameTooltip:SetPoint("TOPLEFT", ignore.frame,"BOTTOMLEFT", 10, 0)
									GameTooltip:SetText("Move this daily to the Ignore list")
								end)
							else 
								ignore:SetText("|TInterface\\AddOns\\Dailies\\Images\\completed:16|t")
								ignore:SetWidth(20)
								ignore:SetCallback("OnClick", function() 
									Dailies_Data.Toons[dllocal_charKey].Quests[kq].Ignored = false
									Dailies.ShowTabContent()
								end)
								ignore:SetCallback("OnEnter", function() 
									GameTooltip:SetOwner(ignore.frame,"ANCHOR_NONE")
									GameTooltip:SetPoint("TOPLEFT", ignore.frame,"BOTTOMLEFT", 10, 0)
									GameTooltip:SetText("Remove this daily from the Ignore list")
								end)
							end		
							ignore:SetCallback("OnLeave", function() GameTooltip:Hide() end)	
							quest:AddChild(ignore)


							--give alternative to group quest if any available (today's daily of the same group)
							local actualDaily = nil
							if dllocal_group[kq] then -- part of a group
								for kq2, q2 in pairs(dllocal_group) do 
									if dllocal_group[kq2].group == dllocal_group[kq].group and kq2 ~= kq then -- others from same group
										if Dailies_Data.Quests[kq2] and Dailies_Data.Quests[kq2].TodayUntil and Dailies_Data.Quests[kq2].TodayUntil > time() then actualDaily = kq2 end
										--if dllocal_group[kq2].today then actualDaily = kq2 end
									end
								end
							end

							if actualDaily and dllocal_tabkey == "todo" then 
								local daily = AceGUI:Create("Label")
								daily:SetText("     |TInterface\\AddOns\\Dailies\\Images\\alternative:16|t|cff808080If you prefer, today's daily is actually |r|cffffd100" .. Dailies_Data.Quests[actualDaily].Title .. "|r")
								daily:SetFullWidth(true)
								-- daily:SetJustifyH("LEFT")
								daily:SetFont(GameFontNormal:GetFont(), 12)
								quest:AddChild(daily)
							end

						scroll:AddChild(quest)

						-- ensuring groups are only listed once
						if completed and dllocal_group[kq] then completedGroups[dllocal_group[kq].group] = true end

						previousHeader = header
					end
				end
			end


			-- adding generic groups when today's dailies are not known yet
			-- but only for the todo tab and only if no rep filter
			local extras = 0 -- how many to add to the tab count
			
			if Dailies_Data.Toons[dllocal_charKey].RepFilter == nil then 
				
				-- find all groups with no quest listed
				for km, m in pairs(dllocal_group) do 
					if m.faction == nil or m.faction == dllocal_faction then 
						for kall, all in pairs(dllocal_questTabs.ToDo) do 
							if km == kall then 
								listedGroups[m.group] = true
							end
						end
						for kall, all in pairs(dllocal_questTabs.Ignored) do 
							if km == kall then 
								listedGroups[m.group] = true
							end
						end
						for kall, all in pairs(dllocal_questTabs.Completed) do 
							if km == kall then 
								listedGroups[m.group] = true
							end
						end
					end
				end

				for km, m in pairs(dllocal_group) do 
					local skipgeneric = false
					--check group is for the right expac
					--if m.expac == nil or m.expac <= dllocal_expac then 
					if m.expac == nil or (Dailies_Settings.showTBCDailies and m.expac <= 2) or (Dailies_Settings.showWotLKDailies and m.expac == 3) then 
						if (m.group ~= "Wrath Dungeon" and m.group ~= "Wrath Heroic") or (Dailies_Settings.showWrathDungeonDailies) then
						    if dllocal_seasonal[km] == nil or (Dailies_Settings.showSeasonalDailies and dllocal_seasonal[km] ~= nil) then 

                                if m.faction == nil or m.faction == dllocal_faction then 

						    		if Dailies_Settings.showOnlyForKnownProfessions and dllocal_prof[km] and Dailies_Data.Toons[dllocal_charKey].Professions[dllocal_prof[km]] == nil then skipgeneric = true end

						    		if skipgeneric == false then 
						    			local found = false
						    			for kl, l in pairs(listedGroups) do 
						    				if m.group == kl then found = true end
						    			end
						    			
						    			if found == false then
						    				--print("found")
						    				extras = extras + 1
						    				listedGroups[m.group] = true		
                            
						    				if dllocal_tabkey == "todo" then 
                            
						    					--print(m.group)
						    					local quest = AceGUI:Create("SimpleGroup")
						    					quest:SetFullWidth(true)
						    					quest:SetAutoAdjustHeight(true)
						    					quest:SetLayout("Flow")
                            
						    						local title = AceGUI:Create("InteractiveLabel")
						    						title:SetText("|TInterface\\AddOns\\Dailies\\Images\\available:16|t |cff808080Unknown " .. m.group .. " Daily|r")
						    						title:SetWidth(360)
						    						-- title:SetJustifyH("LEFT") Broken, removed
						    						title:SetFont(GameFontNormal:GetFont(), 12)
						    						--title:SetCallback("OnEnter", function()  		end)
                            
						    						title:SetCallback("OnClick", function() 
						    	
						    							if Dailies_Settings.showQuestInfoPanel then 
                            
						    								local groupCount = 0
						    								for km2, m2 in pairs(dllocal_group) do 
						    									if m.group == m2.group then groupCount = groupCount +1 end
						    								end
						    		
						    								dllocal_info_heading:SetText("") 
						    								dllocal_info_npc:SetText(" ") 
						    								dllocal_info_zone:SetText(" ")
						    								dllocal_info_count:SetText(" ")
                                                            dllocal_info_record:SetText(" ")
						    								dllocal_info_coords:SetText(" ")
						    								dllocal_info_attune:SetText(" ")
						    								dllocal_info_attune.frame:Hide()
						    								dllocal_info_inst:SetText(" ")
						    								dllocal_info_inst.frame:Hide()
						    								dllocal_info_desc:SetText("This daily quest is taken randomly from a pool of |cffffd100" .. groupCount .. " quests|r.|nWe don't yet know which one is the selected one for today."); 
						    								
						    							end
                            
						    						end)							
						    						quest:AddChild(title)
                            
						    					scroll:AddChild(quest)
						    				end
						    			end
						    		end
						    	end
                            end
						end
					end
				end
			end
			dllocal_tabgroup:SetTabs({{value="todo", text="To Do ("..(Dailies.count(dllocal_questTabs.ToDo) + extras)..")"}, {value="completed", text="Completed ("..Dailies.count(dllocal_questTabs.Completed)..")"}, {value="ignored", text="Ignored ("..Dailies.count(dllocal_questTabs.Ignored)..")"}, {value="all", text="All Dailies ("..(Dailies.count(dllocal_questTabs.All))..")"}, {value="stats", text="Statistics"}})


			-- if absolutely nothing was found, put a default message
			if Dailies.count(list) == 0 then 
				local msg = AceGUI:Create("Label")
				msg:SetText("\n\nYou do not appear to have any matching daily quest")
				msg:SetFullWidth(true)
				-- msg:SetJustifyH("CENTER") Broken, removed
				msg:SetFont(GameFontNormal:GetFont(), 12)
				scroll:AddChild(msg)
			end





			if showTotal then 

				local total = AceGUI:Create("SimpleGroup")
				total:SetFullWidth(true)
				total:SetLayout("Flow")

					local heading = AceGUI:Create("Heading")
					heading:SetText("")
					heading:SetFullWidth(true)
					heading.left:SetAlpha(0.4)
					heading.right:SetAlpha(0.4)
					total:AddChild(heading)

					local totaltext = AceGUI:Create("Label")
					totaltext:SetText("|cffc0c0c0Total for all listed Dailies:|r")
					totaltext:SetWidth(200)
					-- totaltext:SetJustifyH("LEFT")
					totaltext:SetFont(GameFontNormal:GetFont(), 12)
					total:AddChild(totaltext)

					
					local repText = ""
					local tooltip = ""
					if totalHonor > 0 then 
						repText = "  |TInterface\\AddOns\\Dailies\\Images\\pvp-arenapoints-icon:16|t" 
						tooltip = "|TInterface\\AddOns\\Dailies\\Images\\pvp-arenapoints-icon:16|t |cffa0a0a0+" .. totalHonor .. " Honor Points|r\n"
					end
					for kr, r in pairs(totalReps) do 
						if dllocal_repfaction[kr] == nil or dllocal_repfaction[kr] == dllocal_faction then 
							repText = "  |T" .. dllocal_repicons[kr] .. ":16|t" .. repText
							local name, _, _, _, _, earnedValue = GetFactionInfoByID(kr)
							tooltip = "|T" .. dllocal_repicons[kr] .. ":16|t |cffa0a0a0+" .. r .. " " .. (name or "Unknown Reputation") .. " rep|r\n" .. tooltip
						end
					end
					local totalrep = AceGUI:Create("InteractiveLabel")
					totalrep:SetText(repText)
					totalrep:SetWidth(230)
					-- totalrep:SetJustifyH("RIGHT")
					totalrep:SetFont(GameFontNormal:GetFont(), 12)
					if tooltip ~= "" then 
						totalrep:SetCallback("OnEnter", function() 
							GameTooltip:SetOwner(totalrep.frame,"ANCHOR_NONE")
							GameTooltip:SetPoint("TOPLEFT", totalrep.frame,"TOPRIGHT", 10, 3)
							GameTooltip:SetText(tooltip)
						end)				
						totalrep:SetCallback("OnLeave", function() GameTooltip:Hide() end)
					end
					total:AddChild(totalrep)


					local goldString = ""
					if totalGold > 0 then goldString = GetMoneyString(totalGold, true) end
					local totalvalue = AceGUI:Create("Label")
					totalvalue:SetText(goldString)
					totalvalue:SetWidth(80)
					-- totalvalue:SetJustifyH("RIGHT")
					totalvalue:SetFont(GameFontNormal:GetFont(), 12)
					total:AddChild(totalvalue)

					local totalspacer = AceGUI:Create("Label")
					totalspacer:SetText("")
					totalspacer:SetWidth(3*20)
					totalspacer:SetFont(GameFontNormal:GetFont(), 12)
					total:AddChild(totalspacer)

				dllocal_tabgroup:AddChild(total)

			end


			if Dailies_Settings.showQuestInfoPanel then 

				local info = AceGUI:Create("SimpleGroup")
				info:SetFullWidth(true)
				info:SetLayout("Flow")

					dllocal_info_heading = AceGUI:Create("Heading")
					dllocal_info_heading:SetText("")
					dllocal_info_heading:SetFullWidth(true)
					info:AddChild(dllocal_info_heading)
		
					dllocal_info_npc = AceGUI:Create("Label")
					dllocal_info_npc:SetText(" ")
					dllocal_info_npc:SetRelativeWidth(0.50)
					-- dllocal_info_npc:SetJustifyH("LEFT")
					dllocal_info_npc:SetFont(GameFontNormal:GetFont(), 12)
					info:AddChild(dllocal_info_npc)
		
					dllocal_info_zone = AceGUI:Create("Label")
					dllocal_info_zone:SetText(" ")
					dllocal_info_zone:SetRelativeWidth(0.50)
					-- dllocal_info_zone:SetJustifyH("RIGHT")
					dllocal_info_zone:SetFont(GameFontNormal:GetFont(), 12)
					info:AddChild(dllocal_info_zone)
		
					dllocal_info_count = AceGUI:Create("Label")
					dllocal_info_count:SetText(" ")
					dllocal_info_count:SetRelativeWidth(0.50)
					-- dllocal_info_count:SetJustifyH("LEFT")
					dllocal_info_count:SetFont(GameFontNormal:GetFont(), 12)
					info:AddChild(dllocal_info_count)
		
					dllocal_info_coords = AceGUI:Create("Label")
					dllocal_info_coords:SetText(" ")
					dllocal_info_coords:SetRelativeWidth(0.50)
					-- dllocal_info_coords:SetJustifyH("RIGHT")
					dllocal_info_coords:SetFont(GameFontNormal:GetFont(), 12)
					info:AddChild(dllocal_info_coords)

					dllocal_info_record = AceGUI:Create("Label")
					dllocal_info_record:SetText(" ")
					dllocal_info_record:SetRelativeWidth(0.50)
					-- dllocal_info_record:SetJustifyH("LEFT")
					dllocal_info_record:SetFont(GameFontNormal:GetFont(), 12)
					info:AddChild(dllocal_info_record)	

					dllocal_info_inst = AceGUI:Create("Label")
					dllocal_info_inst:SetText(" ")
					dllocal_info_inst:SetRelativeWidth(0.50)
					-- dllocal_info_inst:SetJustifyH("LEFT")
					dllocal_info_inst:SetFont(GameFontNormal:GetFont(), 12)
					info:AddChild(dllocal_info_inst)

					dllocal_info_attune = AceGUI:Create("InteractiveLabel")
					dllocal_info_attune:SetText(" ")
					dllocal_info_attune:SetRelativeWidth(0.50)
					-- dllocal_info_attune:SetJustifyH("RIGHT")
					dllocal_info_attune:SetFont(GameFontNormal:GetFont(), 12)
					info:AddChild(dllocal_info_attune)			

					dllocal_info_desc = AceGUI:Create("Label")
					dllocal_info_desc:SetText("Hover over one of the quests in the list to see more details\n \n ")
					dllocal_info_desc:SetFullWidth(true)
					-- dllocal_info_desc:SetJustifyH("CENTER")
					dllocal_info_desc:SetFont(GameFontNormal:GetFont(), 11)
					info:AddChild(dllocal_info_desc)

				dllocal_tabgroup:AddChild(info)

			end

		end

	end

end

-------------------------------------------------------------------------
-- /dump C_QuestLog.IsQuestFlaggedCompleted(11381)

function Dailies.ClassifyQuests()

	dllocal_questTabs = {}
	dllocal_questTabs.ToDo = {}
	dllocal_questTabs.Completed = {}
	dllocal_questTabs.Ignored = {}
	dllocal_questTabs.All = {}

	local completedGroups = {}  -- used to not repeat completed quests from the same group
	local listedGroups = {}  	-- used to not repeat completed quests from the same group
	local listedExclu = {}  	-- used to not repeat completed quests from the same group
	local first = true			-- used to show the first quest in broker

	if not (Dailies_Data and Dailies_Data.Quests and Dailies_Data.Toons and Dailies_Data.Toons[dllocal_charKey]) then return end

	Dailies.RefreshQuestLog()

	-- every quest needs an entry (with an Order) for this toon before sorting
	for kq in pairs(Dailies_Data.Quests) do Dailies.EnsureToonQuest(kq) end

	for kq, q in Dailies.spairs(Dailies_Data.Quests, function(t,a,b) 	return Dailies_Data.Toons[dllocal_charKey].Quests[a].Order < Dailies_Data.Toons[dllocal_charKey].Quests[b].Order end) do --all dailies

		-- super dirty way to handle quest expac
		local expac = 2
		if kq > 12000 	or kq == 11153		or kq == 11472		or kq == 11940		or kq == 11960		or kq == 11945		or kq == 11391		then expac = 3 end

		if (Dailies_Settings.showTBCDailies and expac == 2) or (Dailies_Settings.showWotLKDailies and expac == 3) then 

			if dllocal_seasonal[kq] == nil or (Dailies_Settings.showSeasonalDailies and dllocal_seasonal[kq] ~= nil) then 

				-- only show quests available to this faction
				if Dailies_Data.Quests[kq].Factions and Dailies_Data.Quests[kq].Factions[dllocal_faction] == 1 then 

					if Dailies_Data.Quests[kq].Seen and  Dailies_Data.Quests[kq].Seen[GetRealmName()] == 1 then 

						if dllocal_group[kq] == nil or dllocal_group[kq].faction == nil or dllocal_group[kq].faction == dllocal_faction then 

							local skip = false

							local completed = Dailies.IsCompletedToday(kq)
						--	if completed and Dailies_Data.Quests[kq].TodayUntil == nil then completed = false end  


							-- Check if we already have the quest in our log
							local alreadyHaveIt = Dailies.AlreadyHaveQuest(kq)

							local todaysDaily = true
							local haveAnotherAlready = false

							-- check if that quest if part of a group where you can only have 1 of the group at the time
							-- for example the fishing daily, or the cooking daily, or the daily dungeon
							if dllocal_group[kq] then  -- part of a group

								-- if a group, check if it's todays
								if q.TodayUntil == nil then 
									todaysDaily = false
								elseif time() > q.TodayUntil then
									q.TodayUntil = nil
									todaysDaily = false 
								end

								for kq2, q2 in pairs(dllocal_group) do 
									if dllocal_group[kq2].group == dllocal_group[kq].group and kq2 ~= kq then
										if Dailies.AlreadyHaveQuest(kq2) then haveAnotherAlready = true end
									end
								end

							end


							-- This is to make sure the completed quest has actually been completed, and is not just showing because it's part of a completed group
							if completed == true and todaysDaily == false then completed = false end

							-- add to listed groups to avoid the generic group line
							if completed and dllocal_group[kq] then listedGroups[dllocal_group[kq].group] = true; end
							if completed and dllocal_exclu[kq] then listedGroups[dllocal_exclu[kq].group] = true; end
							
							if Dailies_Data.Toons[dllocal_charKey].Quests[kq].Ignored and dllocal_group[kq] then listedGroups[dllocal_group[kq].group] = true; end
							if Dailies_Data.Toons[dllocal_charKey].Quests[kq].Ignored and dllocal_exclu[kq] then listedGroups[dllocal_exclu[kq].group] = true; end
						

							if alreadyHaveIt == false and todaysDaily == false then skip = true end
							if haveAnotherAlready == true and todaysDaily == true then skip = true end

							if completed then skip = false 	end

							-- check if that quest is a temporaty quest, to be replaced by another at some point
							-- if the new one exists, then never show the old one
							-- for example the SSO phase quests
							if dllocal_temp[kq] then  -- part of a temp
								if Dailies_Data.Quests[dllocal_temp[kq]] then 
									if Dailies_Data.Quests[dllocal_temp[kq]].Seen and Dailies_Data.Quests[dllocal_temp[kq]].Seen[GetRealmName()] then 
										skip = true 
									end
								end
							end		

							if dllocal_group[kq] and completedGroups[dllocal_group[kq].group] then skip = true end
							if dllocal_exclu[kq] and completedGroups[dllocal_exclu[kq].group] then skip = true end


							-- professions
							if Dailies_Settings.showOnlyForKnownProfessions and dllocal_prof[kq] and Dailies_Data.Toons[dllocal_charKey].Professions[dllocal_prof[kq]] == nil then skip = true end

							-- add to listed groups to avoid the generic group line
							if dllocal_group[kq] and listedGroups[dllocal_group[kq].group] == nil then listedGroups[dllocal_group[kq].group] = true end
							
							-- check quests against filter
							if Dailies_Data.Toons[dllocal_charKey].RepFilter ~= nil then 
								if type(dllocal_reps[kq]) == "table" then
									-- keep the quest if any of its reputations matches the filter
									if dllocal_reps[kq][Dailies_Data.Toons[dllocal_charKey].RepFilter] == nil then skip = true end
								else
									skip = true -- no rep attached, skip if filter is active
								end
							end
						
							-- put in buckets
							--if skip == false then dllocal_questTabs.All[kq] = 1 end
							dllocal_questTabs.All[kq] = 1
							if skip == false and completed == true then dllocal_questTabs.Completed[kq] = 1
							elseif skip == false and Dailies_Data.Toons[dllocal_charKey].Quests[kq].Ignored then dllocal_questTabs.Ignored[kq] = 1
							elseif skip == false then dllocal_questTabs.ToDo[kq] = 1 
								if first then 
									first = false
									dllocal_brokerlabel = Dailies_Data.Quests[kq].Title
									if alreadyHaveIt then 
										if Dailies.ReadyToComplete(kq) then 
											dllocal_brokervalue = "|cff00ff00Turn In|r"
										else
											dllocal_brokervalue = ""
										end
									else
										dllocal_brokervalue = "|cff4040ffPick Up|r"
									end
									if Dailies_Broker then Dailies_Broker.text = dllocal_brokervalue .. " " .. dllocal_brokerlabel	end
								end
							end
									
							-- ensuring groups are only listed once
							if completed and dllocal_group[kq] then completedGroups[dllocal_group[kq].group] = true end
							if completed and dllocal_exclu[kq] then completedGroups[dllocal_exclu[kq].group] = true end

						end
					end
				end
			end
		end

	end

	if Dailies.count(dllocal_questTabs.ToDo) == 0  then 
		dllocal_brokervalue = "" 
		dllocal_brokerlabel = "All Done!"
		if Dailies_Broker then Dailies_Broker.text = dllocal_brokervalue .. " " .. dllocal_brokerlabel	end
	end

end

-------------------------------------------------------------------------

function Dailies.MakeGroupDaily(qid)
	-- if part of a group, mark as today's daily
	if dllocal_group[qid] then -- part of a group

		if Dailies_Data.Quests[qid] then 
			--Dailies_Data.Quests[qid].Today = true 
			local reset = Dailies.DailyResetTime()
			if Dailies_Data.Quests[qid].TodayUntil == nil or reset > Dailies_Data.Quests[qid].TodayUntil then Dailies_Data.Quests[qid].TodayUntil = reset end
		end

		for kq, q in pairs(dllocal_group) do 
			if dllocal_group[kq].group == dllocal_group[qid].group and kq ~= qid then -- others from same group
				if Dailies_Data.Quests[kq] then 
					--Dailies_Data.Quests[kq].Today = nil 
					Dailies_Data.Quests[kq].TodayUntil = nil
				end
			end
		end
	end
end

-------------------------------------------------------------------------

function Dailies.AlreadyHaveQuest(qid)
	-- uses the cached quest log, which also sees quests under collapsed headers
	return QuestLog()[qid] ~= nil
end

-------------------------------------------------------------------------

function Dailies.ReadyToComplete(qid)
	-- isComplete is 1 when done, -1 when failed: only the first counts
	local entry = QuestLog()[qid]
	return entry ~= nil and entry.complete
end

-------------------------------------------------------------------------

function Dailies.sendProgress(id, bytesSent, bytesTotal)
	local percentComplete = bytesSent/bytesTotal * 100
	if percentComplete == 100 then
		--Dailies:Print(format("%s: %d%%",id, percentComplete)) -- DEBUG: comment out before packaging
		-- the system message involves a roundtrip to the server it's not instant when the player is not found
	else
		--Dailies:Print(format("%s: %.2f%%",id, percentComplete)) -- DEBUG: comment out before packaging
	end
	local recipient, part = id:match("([^:]+):(%d+)")
	if Dailies._recipientQueue and Dailies._recipientQueue[recipient] then
		local totalParts = Dailies._recipientQueue[recipient][1]
		if part and tonumber(part) == totalParts and percentComplete == 100 then
			Dailies._recipientQueue[recipient] = nil
		end
	end
	Timer.After(1, function()
		if not Dailies._recipientQueue or Dailies.count(Dailies._recipientQueue) == 0 then
			Dailies:RemoveFilter()
		end
	end)
end

-------------------------------------------------------------------------
function Dailies:OnCommReceived(prefix, message, distribution, sender)

	if not (Dailies_Data and Dailies_Data.Quests and Dailies_Settings) then return end	-- not enabled yet

	if prefix == dllocal_prefix and sender ~= UnitName("player") then

		--Someone requested the list of today's dailies
		if message == "GET_TODAYS_DAILIES" or message == "GET_ALL_DAILIES" then
			Dailies._recipientQueue = Dailies._recipientQueue or {}
			Dailies._recipientQueue[sender] = nil
			if not Dailies.CheckExists(sender) then return end

			local count, totalLen = 0, 0
			for kq, q in pairs(Dailies_Data.Quests) do 
				if q.Factions and q.Factions[dllocal_faction] == 1 then
					if (message == "GET_ALL_DAILIES") or (message == "GET_TODAYS_DAILIES" and (dllocal_group[kq] and q.TodayUntil and q.TodayUntil > time())) then -- today's daily or all dailies
						--send each daily back
						local ser = kq.."|"..Dailies.serialize(q):gsub(" = ", "="):gsub("   ", ""):gsub(" }", "}")
						totalLen = totalLen + #ser
						Dailies:AddFilter()
						count = count + 1
						local messageKey = format("%s:%d",sender,count)
						Dailies:SendCommMessage(dllocal_prefix, ser, "WHISPER", sender, "NORMAL", Dailies.sendProgress, messageKey)
					end
				end
			end
			if count > 0 then -- we queued at least 1 message
				Dailies._recipientQueue[sender] = {count, totalLen, GetTime()}
			end
		elseif type(message) == "string" then 
			-- "<questID>|<serialized quest>" (the quest text itself may contain "|")
			local idText, data = message:match("^(%d+)|(.*)$")
			local id = tonumber(idText)

			if id and data then 

				if dllocal_timer_handle then dllocal_timer_handle:Cancel() end

				local newDaily = Dailies.deserialize(data)

				-- check the data received is actually populated.
				-- Zone is typically one of the last things to be updated
				if type(newDaily) == "table" and newDaily.Title and newDaily.Zone and newDaily.Text then 

					if Dailies_Data.Quests[id] == nil then Dailies_Data.Quests[id] = {} end
					local q = Dailies_Data.Quests[id]
					q.Title = tostring(newDaily.Title or "")
					q.Text = tostring(newDaily.Text or "")
					q.Frequency = newDaily.Frequency or ""
					q.Money = tonumber(newDaily.Money) or 0
					q.Xp = tonumber(newDaily.Xp) or 0
					q.Honor = tonumber(newDaily.Honor) or 0 
					q.SubZone = tostring(newDaily.SubZone or "")
					q.Zone = tostring(newDaily.Zone or "")
					q.NPC = tostring(newDaily.NPC or "")

					-- don't overwrite Faction. Add to it instead
					if type(q.Factions) ~= "table" then q.Factions = {} end 
					q.Factions[dllocal_faction] = 1

					local todayUntil = tonumber(newDaily.TodayUntil)
					if todayUntil ~= nil then 
						if q.TodayUntil == nil or q.TodayUntil < todayUntil then 
							q.TodayUntil = todayUntil
							if dllocal_group[id] and Dailies_Settings.showReceivedDailies then print("|cffff00ff[Dailies]|r Today's "..dllocal_group[id].group.. " daily is |cffffd100" .. q.Title .. "|r (from |cffffd100" .. PlayerLink(sender) .. "|r)") end
						end

						--mark as today's daily if it's a grouped one
						Dailies.MakeGroupDaily(id)
					end

					if type(q.Seen) ~= "table" then q.Seen = {} end
					q.Seen[GetRealmName()] = 1

					local tq = Dailies.EnsureToonQuest(id)
					if type(tq.Duration) ~= "table" then tq.Duration = {} end
					
					dllocal_timer_handle = Timer.NewTimer(5, function()
						--print("Load Over")
						Dailies.ScheduleRefresh(0)
					end)
				end
			end
		end
	elseif prefix ==  dllocal_prefix_version and sender ~= UnitName("player") then 
		if message == 'VERSION' then 
			if Dailies.CheckExists(sender) then Dailies:SendCommMessage(dllocal_prefix_version, dllocal_version, "WHISPER", sender ) end
		else
			print("|cffff00ff[Dailies]|r |cffffd100" .. PlayerLink(sender) .. "|r is using |cffffd100v" .. tostring(message) .. "|r") 
		end

	end
end 



-- Is this guildie (still) online? Used to avoid whispering someone who just logged off.
function Dailies.CheckExists(player)
	-- don't send update request when guild frame is open, it's already requesting / breaks show offline behavior
	if not (GuildFrame and GuildFrame:IsShown()) then
		-- this is not instant we need to update our cache of online guildies at the respective event
		-- the server response to request for new guild information is also throttled to ~10sec so data will never be 100% correct/real-time
		GuildRoster()
	end
	-- 3.3.5 names have no realm part, and the roster cache is keyed on the plain name
	local name = ShortName(player)
	local cache = Dailies._guildOnlineCache
	if not name then return false end
	if not cache or cache[name] == nil then
		return true		-- not in our cache yet: they just messaged us, so they are online
	end
	return cache[name]
end

-------------------------------------------------------------------------
-- encode data and show popup to copy it
-------------------------------------------------------------------------

function Dailies.spairs(t, order)
    -- collect the keys
    local keys = {}
    for k in pairs(t) do keys[Dailies.count(keys)+1] = k end

    -- if order function given, sort by it by passing the table and keys a, b,
    -- otherwise just sort the keys
    if order then
        table.sort(keys, function(a,b) return order(t, a, b) end)
    else
        table.sort(keys)
    end

    -- return the iterator function
    local i = 0
    return function()
        i = i + 1
        if keys[i] then
            return keys[i], t[keys[i]]
        end
    end
end

-------------------------------------------------------------------------

function Dailies.count(tab)
	local dllocal_count = 0
	for Index, Value in pairs(tab) do
		dllocal_count = dllocal_count + 1
	end
	return dllocal_count
end

-------------------------------------------------------------------------

function Dailies.serialize (o)
	local res = ""
	if type(o) == "number" then
	  res = res .. o
	elseif type(o) == "string" then
		res = res .. string.format("%q", o)
	elseif type(o) == "table" then
		res = res .. "{ "
	  for k,v in pairs(o) do
		if type(k) == "number" then
			res = res .. "  [" .. k .. "] = "
		elseif type(k) == "string" then
			 res = res .. "  [\"" .. k .. "\"] = "
		end
		res = res .. Dailies.serialize(v)
		res = res .. ", "
	  end
	  res = res ..  "}"
	elseif type(o) == "boolean" then
		if o then res = res .. "true"
		else res = res .. "false" end
	else
	  error("cannot serialize a " .. type(o))
	end
	return res
end

-------------------------------------------------------------------------
 
function Dailies.deserialize(input)
	if type(input) == 'string' then
	   	local data = input
	   	local pos = 0
	   	function input(undo)
			if undo then
				pos = pos - 1
		  	else
				pos = pos + 1
				return string.sub(data, pos, pos)
		  	end
	   	end
	end

	if type(input) ~= 'function' then return nil end

	local c
	repeat
		c = input()
	until c ~= ' ' and c ~= ','

	if c == '"' then
		--string value, written with %q: undo its escapes (\" \\ \<newline> \r \ddd)
	   	local s = ''
	   	repeat
		  	c = input()
		  	if c == '"' then
				--print("s = "..s)
				return s
		  	end
			if c == '\\' then
				c = input()
				if c == 'r' then c = '\r'
				elseif c == 'n' then c = '\n'
				elseif Dailies.is_digit(c) then
					local code = c
					for _ = 1, 2 do
						local nextc = input()
						if Dailies.is_digit(nextc) then code = code .. nextc else input(true) break end
					end
					c = string.char(tonumber(code) % 256)
				end
			end
		  	s = s..c
	   	until c == ''

	elseif c == '-' or Dailies.is_digit(c) then
		-- number value
	   	local s = c
	   	repeat
			c = input()
			local d = Dailies.is_digit(c) or c == '.'
			if d then
				s = s..c
		  	end
	   	until not d
	   	input(true)
		--print("n = "..s)
	   return tonumber(s)

	elseif c == '[' then
		--print("[]")
		--Associative
	   	local o = ''
	   	repeat
		  c = input()
		  if c == ']' then
			 break
		  end
		  o = o..c
	   	until c == ''
		o = o:gsub('"', "") -- removing extra ""
	   	repeat
			c = input()
		until c == '=' or c == ''
		if c == '' then return nil end		-- truncated message
		--print("o = "..o)

		local subarr = {}
		local elem = Dailies.deserialize(input)
		
		table.insert(subarr, "assoc")
		table.insert(subarr, o)
		table.insert(subarr, elem)
		return subarr

	elseif c == '{' then
		--array
		--print("{}")
	   	local arr = {}
	   	local elem
	   	repeat
		  	elem = Dailies.deserialize(input)
			--print(type(elem))
		  	if type(elem) == 'table' then
				if elem[1] == "assoc" then 
					arr[elem[2]] = elem[3]
				else 
					table.insert(arr, elem)
				end
		  	else 
		  		table.insert(arr, elem)
			end
	   	until not elem
	   	return arr
	end
 end

------------------------------------------------------------------------- 

function Dailies.is_number(str)
	local newstr = ""
	for i = 1, #str do
		local c = str:sub(i,i)
		if Dailies.is_digit(c) then
			newstr = newstr .. c
		end
	end
	return newstr
end

-------------------------------------------------------------------------

function Dailies.is_digit(c)
	return c >= '0' and c <= '9'
end

-------------------------------------------------------------------------

local b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/' -- You will need this for encoding/decoding
-- encoding
function Dailies.enc(data)
    return ((data:gsub('.', function(x)
        local r,b='',x:byte()
        for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
        return r;
    end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if (#x < 6) then return '' end
        local c=0
        for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
        return b:sub(c+1,c+1)
    end)..({ '', '==', '=' })[#data%3+1])
end

-------------------------------------------------------------------------
-- decoding
function Dailies.dec(data)
    data = string.gsub(data, '[^'..b..'=]', '')
    return (data:gsub('.', function(x)
        if (x == '=') then return '' end
        local r,f='',(b:find(x)-1)
        for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
        return r;
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
		if (#x ~= 8) then return '' end
        local c=0
        for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
            return string.char(c)
    end))
end

-------------------------------------------------------------------------

function Dailies.formatTime(sec)
	local str = ""

	if sec ~= nil then
		local minutes, hours
		if (sec<60) then
			str = ""..sec.."sec"
		else
			minutes = math.floor(sec/60)
			sec = sec - (minutes*60)
			if (minutes<60) then
				str =  ""..minutes.."min"
			else
				hours = math.floor(minutes/60)
				minutes = minutes - (hours*60)
				str = ""..hours.."h"
				if (minutes > 0) then str = str .. " "..minutes.."min" end
			end
			if (sec > 0) then str = str .. " "..sec.."sec" end
		end
	else
		str = ""
	end
	return str
end

-------------------------------------------------------------------------

function Dailies.split(str, sep)
	local t = {}
	local ind = string.find(str, sep)
	while (ind ~= nil) do
		table.insert(t, string.sub(str, 1, ind-1))
		str = string.sub(str, ind+1)
		ind = string.find(str, sep, 1, true)
	end
	if (str ~="") then table.insert(t, str) end
	return t
end

-------------------------------------------------------------------------
-- find if key exists in table
function Dailies.locate(table, value)
    for i = 1, #table do
        if table[i] == value then return true end
    end
    return false
end

-------------------------------------------------------------------------

function Dailies.Round(num, numDecimalPlaces)
	local mult = 10^(numDecimalPlaces or 0)
	return math.floor(num * mult + 0.5) / mult
end

-------------------------------------------------------------------------


function Dailies_SlashCommandHandler( msg )

	if msg == 'version' then 
		print("|cffff00ff[Dailies]|r Sending version check.")
		if IsInGuild() then 
			Dailies:SendCommMessage(dllocal_prefix_version, "VERSION", "GUILD", "") 
		end
--		Dailies:SendCommMessage(dllocal_prefix_version, "VERSION", "YELL", "") 
	else 
		dllocal_frame = Dailies.getFrame()
	end

end

-------------------------------------------------------------------------
SlashCmdList["Dailies"] = Dailies_SlashCommandHandler
SLASH_Dailies1 = "/Dailies"



_G[dllocal_addonName] = Dailies -- comment this out if we don't want our addon object accessible from the outside
