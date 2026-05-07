local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local State = require(script.Parent.State)

local DEFAULT_AUTO_SAVE_INTERVAL = 30
local LOCK_HEARTBEAT_INTERVAL = 30
local LOCK_DEAD_THRESHOLD = 90
local LOCK_ACQUIRE_RETRY_INTERVAL = 6
local LOCK_ACQUIRE_TIMEOUT = 120

local SAVE_FORMAT_VERSION = 1
local FIELD_VERSION = "Version"
local FIELD_DATA = "Data"
local FIELD_SESSION = "Session"

-- Unique per-server identifier. JobId is empty in Studio, so fall back to a GUID.
local SESSION_ID = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)

local activeSaves: { [any]: true } = setmetatable({}, { __mode = "k" }) :: any
local boundToClose = false

local function ensureBoundToClose()
	if boundToClose then
		return
	end
	boundToClose = true
	game:BindToClose(function()
		for sd in activeSaves do
			if not sd._destroyed and sd._loaded and sd._lockStatus == "held" then
				local ok, err = pcall(function()
					sd:_finalize()
				end)
				if not ok then
					warn("[SaveData] save-on-close failed for key", sd._Key, ":", err)
				end
			end
		end
	end)
end

local function deepClone(t)
	if type(t) ~= "table" then
		return t
	end
	local copy = {}
	for k, v in t do
		copy[k] = deepClone(v)
	end
	return copy
end

local function applyTemplate(target, template)
	if type(template) ~= "table" or type(target) ~= "table" then
		return target
	end
	for k, v in template do
		if target[k] == nil then
			target[k] = deepClone(v)
		elseif type(v) == "table" and type(target[k]) == "table" then
			applyTemplate(target[k], v)
		end
	end
	return target
end

local function isWrapped(value): boolean
	return type(value) == "table" and value[FIELD_VERSION] == SAVE_FORMAT_VERSION
end

local function wrap(data: any, session: any)
	return {
		[FIELD_VERSION] = SAVE_FORMAT_VERSION,
		[FIELD_DATA] = data,
		[FIELD_SESSION] = session,
	}
end

local function newSessionMeta()
	return {
		SessionId = SESSION_ID,
		PlaceId = game.PlaceId,
		Heartbeat = os.time(),
	}
end

local function isSessionAlive(session): boolean
	if not session then
		return false
	end
	return (os.time() - (session.Heartbeat or 0)) < LOCK_DEAD_THRESHOLD
end

-- Roblox preserves existing UserIds if the transform returns nil for the 2nd
-- value. Pass nil instead of an empty list so we never clobber prior tags.
local function userIdsOrNil(list: { number }): { number }?
	if #list > 0 then
		return list
	end
	return nil
end

local SaveData = {}
SaveData.__index = SaveData

export type SaveData = {
	State: any,
	Get: (self: SaveData, key: string) -> any,
	Set: (self: SaveData, key: string, value: any) -> any,
	Increment: (self: SaveData, key: string, value: number?) -> number,
	Observe: (self: SaveData, key: string, callback: (any, string) -> (), scope: string?) -> any,
	Load: (self: SaveData) -> (boolean, string?),
	Save: (self: SaveData) -> (boolean, string?),
	ForceSave: (self: SaveData, retries: number?) -> (boolean, string?),
	StartAutoSave: (self: SaveData, interval: number?) -> (),
	StopAutoSave: (self: SaveData) -> (),
	IsLoaded: (self: SaveData) -> boolean,
	IsDirty: (self: SaveData) -> boolean,
	HasLock: (self: SaveData) -> boolean,
	AddUserId: (self: SaveData, userId: number) -> (),
	GetUserIds: (self: SaveData) -> { number },
	Destroy: (self: SaveData) -> (),
}

function SaveData.new(
	datastore: string,
	key: string,
	template: { [any]: any }?,
	userIds: { number }?
): SaveData
	local self = setmetatable({
		_DatastoreName = datastore,
		_Datastore = DataStoreService:GetDataStore(datastore),
		_Key = key,
		_Template = template,
		_userIds = if userIds then table.clone(userIds) else {},
		_loaded = false,
		_dirty = false,
		_saving = false,
		_destroyed = false,
		_lockStatus = "none", -- "none" | "held" | "lost"
		_autoSaveThread = nil,
		_heartbeatThread = nil,
		_autoSaveInterval = DEFAULT_AUTO_SAVE_INTERVAL,
		State = State.new(deepClone(template) or {}),
	}, SaveData)

	-- Patch Set on the State instance so any change marks the SaveData dirty,
	-- whether reached via SaveData proxy or direct .State access.
	-- State:Increment delegates to Set, so this covers both.
	local stateInstance = self.State
	local originalSet = stateInstance.Set
	stateInstance.Set = function(state, k, v)
		self._dirty = true
		return originalSet(state, k, v)
	end

	activeSaves[self] = true
	ensureBoundToClose()
	self:StartAutoSave()
	return (self :: any) :: SaveData
end

function SaveData:Load(): (boolean, string?)
	if self._destroyed then
		return false, "SaveData destroyed"
	end

	local startTime = os.clock()
	while os.clock() - startTime < LOCK_ACQUIRE_TIMEOUT do
		if self._destroyed then
			return false, "SaveData destroyed"
		end

		local acquiredData
		local blockedByOther = false

		local ok, err = pcall(function()
			self._Datastore:UpdateAsync(self._Key, function(existing)
				local data
				local session
				if isWrapped(existing) then
					data = existing[FIELD_DATA]
					session = existing[FIELD_SESSION]
				else
					-- Legacy / fresh: treat the raw value as data.
					data = existing
					session = nil
				end

				if session and session.SessionId ~= SESSION_ID and isSessionAlive(session) then
					blockedByOther = true
					return nil
				end

				acquiredData = data
				return wrap(data, newSessionMeta()), userIdsOrNil(self._userIds)
			end)
		end)

		if not ok then
			warn("[SaveData] load attempt failed for key", self._Key, ":", err)
			task.wait(LOCK_ACQUIRE_RETRY_INTERVAL)
		elseif blockedByOther then
			task.wait(LOCK_ACQUIRE_RETRY_INTERVAL)
		else
			if acquiredData ~= nil then
				if type(acquiredData) == "table" then
					self.State.Data = acquiredData
					if self._Template then
						applyTemplate(self.State.Data, self._Template)
					end
				else
					warn(
						"[SaveData] loaded value is not a table for key",
						self._Key,
						"; keeping template defaults"
					)
				end
			end
			self._loaded = true
			self._lockStatus = "held"
			self._dirty = false
			self:_startHeartbeat()
			return true
		end
	end

	return false, "Could not acquire session lock within timeout"
end

function SaveData:_sendHeartbeat()
	if self._destroyed or self._lockStatus ~= "held" then
		return
	end
	local lostLock = false
	local ok, err = pcall(function()
		self._Datastore:UpdateAsync(self._Key, function(existing)
			if not isWrapped(existing) then
				lostLock = true
				return nil
			end
			local session = existing[FIELD_SESSION]
			if not session or session.SessionId ~= SESSION_ID then
				lostLock = true
				return nil
			end
			session.Heartbeat = os.time()
			existing[FIELD_SESSION] = session
			return existing, userIdsOrNil(self._userIds)
		end)
	end)
	if not ok then
		warn("[SaveData] heartbeat failed for key", self._Key, ":", err)
		return
	end
	if lostLock then
		warn("[SaveData] lost session lock for key", self._Key)
		self._lockStatus = "lost"
	end
end

function SaveData:_startHeartbeat()
	if self._heartbeatThread then
		return
	end
	self._heartbeatThread = task.spawn(function()
		while not self._destroyed and self._lockStatus == "held" do
			task.wait(LOCK_HEARTBEAT_INTERVAL)
			if self._destroyed or self._lockStatus ~= "held" then
				break
			end
			self:_sendHeartbeat()
		end
	end)
end

function SaveData:_stopHeartbeat()
	if self._heartbeatThread then
		local thread = self._heartbeatThread
		self._heartbeatThread = nil
		pcall(task.cancel, thread)
	end
end

function SaveData:Save(): (boolean, string?)
	if self._destroyed then
		return false, "SaveData destroyed"
	end
	if not self._loaded then
		return false, "Save called before Load"
	end
	if self._lockStatus ~= "held" then
		return false, "No session lock held"
	end
	if self._saving then
		return false, "Save already in progress"
	end

	self._saving = true
	self._dirty = false
	local snapshot = deepClone(self.State.Data)
	local lostLock = false

	local ok, err = pcall(function()
		self._Datastore:UpdateAsync(self._Key, function(existing)
			if existing ~= nil and isWrapped(existing) then
				local session = existing[FIELD_SESSION]
				if session and session.SessionId ~= SESSION_ID and isSessionAlive(session) then
					lostLock = true
					return nil
				end
			end
			return wrap(snapshot, newSessionMeta()), userIdsOrNil(self._userIds)
		end)
	end)

	self._saving = false
	if lostLock then
		self._lockStatus = "lost"
		warn("[SaveData] save aborted — lost session lock for key", self._Key)
		return false, "Lost session lock"
	end
	if not ok then
		self._dirty = true
		warn("[SaveData] save failed for key", self._Key, ":", err)
		return false, err
	end
	return true
end

-- Atomic final-save + lock release. Used by Destroy and BindToClose.
function SaveData:_finalize(): (boolean, string?)
	if not self._loaded or self._lockStatus ~= "held" then
		return false, "not loaded or lock not held"
	end

	self._saving = true
	self._dirty = false
	local snapshot = deepClone(self.State.Data)
	local lostLock = false

	local ok, err = pcall(function()
		self._Datastore:UpdateAsync(self._Key, function(existing)
			if existing ~= nil and isWrapped(existing) then
				local session = existing[FIELD_SESSION]
				if session and session.SessionId ~= SESSION_ID and isSessionAlive(session) then
					lostLock = true
					return nil
				end
			end
			return wrap(snapshot, nil), userIdsOrNil(self._userIds) -- nil session = released
		end)
	end)

	self._saving = false
	if lostLock then
		self._lockStatus = "lost"
		return false, "Lost session lock"
	end
	if not ok then
		self._dirty = true
		return false, err
	end
	self._lockStatus = "none"
	return true
end

function SaveData:Get(key: string)
	return self.State:Get(key)
end

function SaveData:Set(key: string, value: any)
	return self.State:Set(key, value)
end

function SaveData:Increment(key: string, value: number?): number
	return self.State:Increment(key, value)
end

function SaveData:Observe(key: string, callback: (any, string) -> (), scope: string?)
	return self.State:Observe(key, callback, scope)
end

function SaveData:StartAutoSave(interval: number?)
	if self._destroyed or self._autoSaveThread then
		return
	end
	if interval then
		self._autoSaveInterval = interval
	end
	self._autoSaveThread = task.spawn(function()
		while not self._destroyed do
			task.wait(self._autoSaveInterval)
			if
				not self._destroyed
				and self._loaded
				and self._dirty
				and not self._saving
				and self._lockStatus == "held"
			then
				self:Save()
			end
		end
	end)
end

function SaveData:StopAutoSave()
	if self._autoSaveThread then
		local thread = self._autoSaveThread
		self._autoSaveThread = nil
		pcall(task.cancel, thread)
	end
end

function SaveData:IsLoaded(): boolean
	return self._loaded == true
end

function SaveData:IsDirty(): boolean
	return self._dirty == true
end

function SaveData:HasLock(): boolean
	return self._lockStatus == "held"
end

-- Yields until the save has been committed (or all retries exhausted).
-- Use this for operations like trades where you must know the data is durable.
function SaveData:ForceSave(retries: number?): (boolean, string?)
	local maxRetries = retries or 3
	local lastErr: string?

	for attempt = 0, maxRetries do
		if self._destroyed then
			return false, "SaveData destroyed"
		end
		if not self._loaded then
			return false, "Save called before Load"
		end
		if self._lockStatus ~= "held" then
			return false, "No session lock held"
		end

		-- Wait for any in-flight save (auto-save or a prior ForceSave).
		-- Bounded so a stuck _saving flag doesn't hang us forever.
		local waitStart = os.clock()
		while self._saving and os.clock() - waitStart < 30 do
			task.wait(0.05)
		end
		if self._saving then
			return false, "Timed out waiting for in-flight save"
		end

		local ok, err = self:Save()
		if ok then
			return true
		end
		lastErr = err

		-- Permanent failures: don't retry.
		if
			err == "Lost session lock"
			or err == "SaveData destroyed"
			or err == "Save called before Load"
			or err == "No session lock held"
		then
			return false, err
		end

		-- "Save already in progress" loses a race we just verified — retry without backoff.
		-- Anything else is a DataStore hiccup; back off exponentially.
		if attempt < maxRetries and err ~= "Save already in progress" then
			task.wait(2 ^ attempt) -- 1s, 2s, 4s, ...
		end
	end

	return false, lastErr or "ForceSave exhausted retries"
end

function SaveData:AddUserId(userId: number)
	if not table.find(self._userIds, userId) then
		table.insert(self._userIds, userId)
	end
end

function SaveData:GetUserIds(): { number }
	return table.clone(self._userIds)
end

function SaveData:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true

	-- Let any in-flight auto-save complete before we move on.
	while self._saving do
		task.wait(0.05)
	end

	-- Final save + lock release (atomic).
	if self._loaded and self._lockStatus == "held" then
		local ok, err = pcall(function()
			self:_finalize()
		end)
		if not ok then
			warn("[SaveData] final save failed:", err)
		end
	end

	self:StopAutoSave()
	self:_stopHeartbeat()
	activeSaves[self] = nil
end

return SaveData
