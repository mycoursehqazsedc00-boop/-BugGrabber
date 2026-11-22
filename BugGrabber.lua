--
-- $Id: BugGrabber.lua 6441 2006-08-01 09:38:54Z fritti $
--

-- Localization
local USAGE = "Usage: /buggrabber <index | list | clear | status>."
local ERROR_INDEX = "The provided index must be a number."
local ERROR_UNKNOWN_INDEX = "The index %d does not exist in the error table."
local STARTUP_ERRORS = "There were %d startup errors:"
local STARTUP_ERRORS_MANY = "There were %d startup errors, please use /buggrabber <number> to print them."
local UNIQUE_CAPTURE = "BugGrabber captured a unique error:\n%s\n---"
local ADDON_CALL_PROTECTED = "[%s] AddOn '%s' tried to call the protected function '%s'."
local ADDON_CALL_PROTECTED_MATCH = "^%[(.*)%] (AddOn '.*' tried to call the protected function '.*'.)$"

if GetLocale() == "koKR" then
	USAGE = "사용법: /buggrabber <색인값(숫자)>."
	ERROR_INDEX = "색인값은 숫자이어야 합니다."
	ERROR_UNKNOWN_INDEX = "불러온 오류목록에 %d번째 오류는 존재하지 않습니다."
	STARTUP_ERRORS = "%d개의 시작시 오류가 발생:"
	STARTUP_ERRORS_MANY = "%d개의 시작시 오류가 발생했습니다, /buggrabber <숫자>를 사용해서 해당 오류를 볼 수 있습니다."
	UNIQUE_CAPTURE = "벌레잡이가 발견한 오류:\n%s\n---"
end

if GetLocale() == "deDE" then
	USAGE = "Benutzung: /buggrabber <index>."
	ERROR_INDEX = "Der zur Verfügung gestellte Index muß eine Zahl sein."
	ERROR_UNKNOWN_INDEX = "Der Index %d existiert nicht in der geladenen Fehlerliste."
	STARTUP_ERRORS = "Es gab %d Errors beim starten:"
	STARTUP_ERRORS_MANY = "Es gab %d Errors beim starten, verwende bitte /buggrabber <nummer>, um sie zu aufzulisten."
	UNIQUE_CAPTURE = "BugGrabber hat einen einzigartigen error aufgezeichnet:\n%s\n---"
end

-- Create our event registering frame
local f = CreateFrame("Frame", "BugGrabber")

local string_gmatch = string.gmatch or string.gfind

-- State variables
BugGrabber.loaded = false
BugGrabber.loadErrors = {}
BugGrabber.bugsackErrors = {}
BugGrabber.errors = {}

-- Our persistent error database
BugGrabberDB = {}
BugGrabberDB.session = 0
BugGrabberDB.save = true
BugGrabberDB.limit = 100
BugGrabberDB.errors = {}

-- Determine the proper DB and return it
function BugGrabber.GetDB()
	if not BugGrabber.loaded then
		return BugGrabber.loadErrors
	end
	if not BugGrabberDB.save then
		return BugGrabber.errors
	end
	return BugGrabberDB.errors
end

local traceParts = {}
local grabbing = false

-- Error handler
function BugGrabber.GrabError(self, err)
	if grabbing then
		return
	end
	grabbing = true

	-- Support direct calls like GrabError(msg) as well as method calls Frame:SetText(msg)
	if err == nil and type(self) == "string" then
		err = self
	end
	err = tostring(err or "")

	-- Get the full backtrace
	local stack = debugstack and debugstack(4) or ""
	if stack ~= "" then
		err = err .. "\n" .. stack
	end

	-- Normalize the full paths into last directory component and filename.
	local n = 0
	local looping = false
	for trace in string_gmatch(err .. "\n", "(.-)\n") do
		if trace ~= "" then
			local match, found, path, file, line, msg
			found = false

			-- First detect an endless loop so as to abort it below
			if string.find(trace, "BugGrabber", 1, true) then
				looping = true
			end

			-- "path\to\file.lua:linenum:message" (supports both \ and /)
			if not found then
				match, _, path, file, line, msg = string.find(trace, "^.-([^\\/]+[\\/])([^\\/]-)(:%d+):(.*)$")
				if match then
					found = true
				end
			end

			-- "[string \"path\\to\\file.lua:<foo>\":linenum:message"
			if not found then
				match, _, path, file, line, msg = string.find(trace, "^%[string \".-([^\\/]+[\\/])([^\\/]-)\"%](:%d+):(.*)$")
				if match then
					found = true
				end
			end

			-- "[string \"FOO\":linenum:message"
			if not found then
				match, _, file, line, msg = string.find(trace, "^%[string (\".-\")%](:%d+):(.*)$")
				if match then
					found = true
					path = '<string>:'
				end
			end

			-- "[C]:message"
			if not found then
				match, _, msg = string.find(trace, "^%[C%]:(.*)$")
				if match then
					found = true
					path = '<in C code>'
					file = ''
					line = ''
				end
			end

			-- ADDON_ACTION_BLOCKED
			if not found then
				match, _, file, msg = string.find(trace, ADDON_CALL_PROTECTED_MATCH)
				if match then
					found = true
					path = '<event>'
					file = 'ADDON_ACTION_BLOCKED'
					line = ''
				end
			end

			-- Anything else
			if not found then
				path = '<unknown>'
				file = ''
				line = ''
				msg = trace
			end

			-- Add it to the formatted error
			n = n + 1
			traceParts[n] = path .. file .. line .. ":" .. msg
		end
	end

	local errmsg = table.concat(traceParts, "\n", 1, n)
	if errmsg ~= "" then
		errmsg = errmsg .. "\n"
	end

	-- Now store the error (reset grabbing even if SaveError fails)
	pcall(BugGrabber.SaveError, errmsg, looping)
	grabbing = false
end

function BugGrabber.SaveError(message, looping)
	-- Start with the date, time and session
	local oe = {}
	oe.message = message .. "\n  ---"
	oe.session = BugGrabberDB.session
	oe.time = date("%Y/%m/%d %H:%M:%S")
	oe.counter = 1

	-- WoW crashes when strings > 983 characters are stored in the
	-- SavedVariables file, so make sure we don't exceed that limit.
	-- Truncate while preserving a clear closing marker.
	if string.len(oe.message) > 980 then
		oe.message = string.sub(oe.message, 1, 970) .. "\n...  ---"
	end

	local added = false

	-- Insert the error into the correct database if it's not there already.
	-- If it is, just increment the counter.
	local found = false
	local db = BugGrabber.GetDB()
	for i, err in ipairs(db) do
		if err.message == oe.message and err.session == oe.session then
			-- This error already exists in the current session, just increment
			-- the counter on it.
			if not err.counter or type(err.counter) ~= "number" then
				err.counter = 1
			end
			err.counter = err.counter + 1

			-- Update the current error for the event firing later.
			oe.counter = err.counter
			oe.time = err.time
			found = true
			break
		end
	end

	-- If the error was not found in the current session, append it to the
	-- database.
	if not found then
		table.insert(db, oe)
		added = true
	end

	-- Also insert it into the temporary capture database that we maintain
	-- to silence loading errors while we wait for BugSack to load
	if BugGrabber.bugsackErrors and type(BugGrabber.bugsackErrors) == "table" then
		found = false
		for i, err in ipairs(BugGrabber.bugsackErrors) do
			if err.message == oe.message and err.session == oe.session then
				if not err.counter or type(err.counter) ~= "number" then
					err.counter = 1
				end
				err.counter = err.counter + 1
				found = true
				break
			end
		end
		if not found then
			table.insert(BugGrabber.bugsackErrors, oe)
			added = true
		end
	end

	-- Save only the last <limit> errors (otherwise the SV gets too big)
	if table.getn(db) > BugGrabberDB.limit then
		table.remove(db, 1)
	end

	-- Now trigger an event if someone's listening. If not, just print
	-- it to the chat frame so it doesn't get lost.
	if not looping and not BugGrabber.bugsackErrors and
	  AceLibrary and AceLibrary:HasInstance("AceEvent-2.0") and
	  AceLibrary("AceEvent-2.0"):IsEventRegistered("BugGrabber_BugGrabbed") then
		if added then
			AceLibrary("AceEvent-2.0"):TriggerEvent("BugGrabber_BugGrabbed", oe)
		else
			AceLibrary("AceEvent-2.0"):TriggerEvent("BugGrabber_BugGrabbedAgain", oe)
		end
	elseif not looping and not BugGrabber.bugsackErrors and added then
		DEFAULT_CHAT_FRAME:AddMessage(string.format(UNIQUE_CAPTURE, oe.message))
	end
end

-- Event handlers
function BugGrabber.AddonLoaded()
	BugGrabber.loaded = true

	-- Persist defaults and make sure we have sane SavedVariables
	if not BugGrabberDB or type(BugGrabberDB) ~= "table" then
		BugGrabberDB = {}
	end
	if not BugGrabberDB.session or type(BugGrabberDB.session) ~= "number" then
		BugGrabberDB.session = 0
	end
	if not BugGrabberDB.errors or type(BugGrabberDB.errors) ~= "table" then
		BugGrabberDB.errors = {}
	end
	if not BugGrabberDB.limit or type(BugGrabberDB.limit) ~= "number" then
		BugGrabberDB.limit = 100
	end
	if BugGrabberDB.save == nil or type(BugGrabberDB.save) ~= "boolean" then
		BugGrabberDB.save = true
	end

	-- From now on we can persist errors. Create a new session.
	BugGrabberDB.session = BugGrabberDB.session + 1

	-- Determine the correct database
	local db = BugGrabber.GetDB()

	-- Cut down on the nr of errors if it is over 100
	while table.getn(db) + table.getn(BugGrabber.loadErrors) > BugGrabberDB.limit do
		table.remove(db, 1)
	end

	-- Save the errors that occurred while our variables were loading
	-- in the correct database, preserving chronological order.
	for _, err in ipairs(BugGrabber.loadErrors) do
		err.session = BugGrabberDB.session
		table.insert(db, err)
	end

	-- Enforce limit even if loadErrors alone exceeded BugGrabberDB.limit
	while table.getn(db) > BugGrabberDB.limit do
		table.remove(db, 1)
	end

	-- Now do away with the temporary database
	BugGrabber.loadErrors = nil
end

local temporaryList = nil
function BugGrabber.PrintLoadError(index)
	local arg = string.gsub(tostring(index or ""), "^%s*(.-)%s*$", "%1")
	if arg == "" then
		DEFAULT_CHAT_FRAME:AddMessage(USAGE)
		return
	end

	local cmd = string.lower(arg)
	if cmd == "list" then
		local list = temporaryList or BugGrabber.GetDB()
		local count = table.getn(list)
		if count == 0 then
			DEFAULT_CHAT_FRAME:AddMessage("BugGrabber: No errors recorded.")
			return
		end
		local startIdx = math.max(1, count - 9)
		DEFAULT_CHAT_FRAME:AddMessage(string.format("BugGrabber: Showing %d-%d of %d errors:", startIdx, count, count))
		for i = startIdx, count do
			local e = list[i]
			if type(e) == "table" and type(e.message) == "string" then
				local _, _, firstLine = string.find(e.message, "^([^\n]+)")
				DEFAULT_CHAT_FRAME:AddMessage(string.format("%d. [x%d] %s", i, tonumber(e.counter) or 1, firstLine or e.message))
			end
		end
		return
	elseif cmd == "clear" then
		BugGrabber.errors = {}
		if BugGrabberDB and type(BugGrabberDB) == "table" then
			BugGrabberDB.errors = {}
		end
		temporaryList = nil
		DEFAULT_CHAT_FRAME:AddMessage("BugGrabber: Cleared recorded errors.")
		return
	elseif cmd == "status" then
		local db = BugGrabber.GetDB()
		DEFAULT_CHAT_FRAME:AddMessage(string.format(
			"BugGrabber: session=%d, errors=%d/%d, save=%s, BugSack=%s",
			tonumber(BugGrabberDB and BugGrabberDB.session) or 0,
			table.getn(db),
			tonumber(BugGrabberDB and BugGrabberDB.limit) or 100,
			tostring(BugGrabberDB and BugGrabberDB.save),
			tostring(type(BugSack) == "table")
		))
		return
	end

	local idx = tonumber(arg)
	if not idx then
		DEFAULT_CHAT_FRAME:AddMessage(ERROR_INDEX)
		return
	end
	local list = temporaryList or BugGrabber.GetDB()
	if not list or not list[idx] then
		DEFAULT_CHAT_FRAME:AddMessage(string.format(ERROR_UNKNOWN_INDEX, idx))
		return
	end
	local err = list[idx]
	if type(err) ~= "table" or type(err.message) ~= "string" then return end
	DEFAULT_CHAT_FRAME:AddMessage(tostring(idx) .. ". " .. err.message)
end

local function RegisterSlashCommand()
	local _G = getfenv(0)
	if type(_G) ~= "table" or type(_G.SlashCmdList) ~= "table" then
		return
	end
	local name = "BUGGRABBERCMD"
	local counter = 0
	repeat
		name = "BUGGRABBERCMD" .. tostring(counter)
		counter = counter + 1
	until not _G.SlashCmdList[name] and not _G["SLASH_" .. name .. "1"]
	_G.SlashCmdList[name] = BugGrabber.PrintLoadError
	_G["SLASH_" .. name .. "1"] = "/buggrabber"
end

function BugGrabber.PlayerLogin()
	-- On player login, check to see whether we had load time errors and
	-- display them in the chat frame if we can't find BugSack. We cheat
	-- by letting BugSack reset BugGrabber.bugsackErrors so we can just
	-- check that.
	local err = BugGrabber.bugsackErrors
	if err and type(err) == "table" and table.getn(err) > 0 then
		local num = table.getn(err)
		if num > 4 then
			DEFAULT_CHAT_FRAME:AddMessage(string.format(STARTUP_ERRORS_MANY, num))
			temporaryList = {}
			for _, v in ipairs(err) do
				table.insert(temporaryList, v)
			end
		else
			DEFAULT_CHAT_FRAME:AddMessage(string.format(STARTUP_ERRORS, num))
			for k, e in ipairs(err) do
				DEFAULT_CHAT_FRAME:AddMessage(tostring(k) .. ". " .. e.message)
			end
		end
	end

	RegisterSlashCommand()

	-- No need to wait for BugSack to load anymore
	BugGrabber.bugsackErrors = nil
end

function BugGrabber.OnEvent()
	if event == "ADDON_LOADED" and arg1 == "!BugGrabber" then
		BugGrabber.AddonLoaded()
	elseif event == "PLAYER_LOGIN" then
		BugGrabber.PlayerLogin()
	elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		BugGrabber.GrabError(nil, string.format(ADDON_CALL_PROTECTED, tostring(event), tostring(arg1 or "?"), tostring(arg2 or "?")))
	end
end

-- Simple setters/getters for settings, meant to be accessed by BugSack
function BugGrabber.GetSave()
	return BugGrabberDB.save
end

function BugGrabber.ToggleSave()
	BugGrabberDB.save = not BugGrabberDB.save
	if BugGrabberDB.save then
		BugGrabberDB.errors = BugGrabber.errors
		BugGrabber.errors = {}
	else
		BugGrabber.errors = BugGrabberDB.errors
		BugGrabberDB.errors = {}
	end
end

function BugGrabber.GetLimit()
	return BugGrabberDB.limit
end

function BugGrabber.SetLimit(l)
	if not l or type(l) ~= "number" or l < 10 or l > 100 then
		return false
	end

	BugGrabberDB.limit = math.floor(l)

	local db = BugGrabber.GetDB()
	while table.getn(db) > BugGrabberDB.limit do
		table.remove(db, 1)
	end
	return true
end

-- Save the old handlers in case someone wants to restore them
if ScriptErrors_Message and ScriptErrors then
	BugGrabber.oldset = ScriptErrors_Message.SetText
	BugGrabber.oldshow = ScriptErrors.Show
	ScriptErrors_Message.SetText = BugGrabber.GrabError
	ScriptErrors.Show = function() end
end
BugGrabber.olderrorhandler = geterrorhandler()
seterrorhandler = function() end

-- Now register for our needed events
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("ADDON_ACTION_BLOCKED")
f:RegisterEvent("ADDON_ACTION_FORBIDDEN")
f:SetScript("OnEvent", BugGrabber.OnEvent)

-- vim:set ts=4:
