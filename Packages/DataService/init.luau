local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ReplicatedState = require(script.Parent.ReplicatedState)
local SaveData = require(script.Parent.SaveData)

local DEFAULT_DATASTORE_NAME = "PlayerData"
local PUBLISH_NAME_PREFIX = "PlayerData:"

local DataService = {}

local _started = false
local _template: { [any]: any }? = nil
local _datastoreName = DEFAULT_DATASTORE_NAME
local _data: { [Player]: SaveData.SaveData } = {}
local _publishes: { [Player]: any } = {}
local _connections: { RBXScriptConnection } = {}

local function publishFor(player: Player, sd: SaveData.SaveData)
	if _publishes[player] then
		return
	end
	local handle = ReplicatedState.publish(
		(sd :: any).State,
		PUBLISH_NAME_PREFIX .. tostring(player.UserId),
		{
			canSubscribe = function(p: Player)
				return p == player
			end,
		}
	)
	_publishes[player] = handle
end

local function unpublishFor(player: Player)
	local handle = _publishes[player]
	_publishes[player] = nil
	if handle then
		handle:Destroy()
	end
end

local function onPlayerAdded(player: Player)
	if _data[player] then
		return
	end

	local key = "Player_" .. player.UserId
	local sd = SaveData.new(_datastoreName, key, _template, { player.UserId })
	_data[player] = sd

	local ok, err = sd:Load()
	if not ok then
		warn(`[DataService] Failed to load data for {player.Name}: {err}`)
		if _data[player] == sd then
			_data[player] = nil
		end
		sd:Destroy()
		return
	end

	-- Publish only if we're still started AND this player is still tracked
	-- (PlayerRemoving could have fired during the Load yield).
	if _started and _data[player] == sd then
		publishFor(player, sd)
	end
end

local function onPlayerRemoving(player: Player)
	-- Tear down the publish first so clients receive no further deltas during finalize.
	unpublishFor(player)

	-- Remove from the registry first so a concurrent Get() sees nil rather
	-- than handing back a SaveData that's mid-Destroy.
	local sd = _data[player]
	_data[player] = nil
	if sd then
		sd:Destroy() -- atomic finalize: final save + lock release
	end
end

function DataService:Start(template: { [any]: any }?, datastoreName: string?)
	if _started then
		return
	end
	_started = true
	_template = template
	_datastoreName = datastoreName or DEFAULT_DATASTORE_NAME

	table.insert(_connections, Players.PlayerAdded:Connect(onPlayerAdded))
	table.insert(_connections, Players.PlayerRemoving:Connect(onPlayerRemoving))

	-- Pick up any players that joined before Start ran.
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

function DataService:Stop()
	if not _started then
		return
	end
	_started = false

	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)

	-- Tear down publishes BEFORE SaveData destroys so clients see the wire close
	-- before the data goes away.
	local publishesToDestroy = table.clone(_publishes)
	table.clear(_publishes)
	for _, handle in publishesToDestroy do
		handle:Destroy()
	end

	-- Snapshot before iterating: Destroy yields, and we want a stable view.
	local toDestroy = {}
	for player, sd in _data do
		toDestroy[player] = sd
	end
	table.clear(_data)
	for _, sd in toDestroy do
		sd:Destroy()
	end

	_template = nil
	_datastoreName = DEFAULT_DATASTORE_NAME
end

-- Yields until the player's data is loaded, or returns nil if the player
-- has left or load failed.
function DataService:Get(player: Player): SaveData.SaveData?
	if not _started then
		warn("[DataService] Get called before Start")
		return nil
	end

	while _data[player] and not _data[player]:IsLoaded() do
		task.wait()
	end
	return _data[player]
end

-- Non-yielding peek: returns the player's SaveData only if it's already
-- loaded right now. Returns nil if the player isn't tracked, hasn't finished
-- loading yet, or DataService hasn't been started.
function DataService:GetIfLoaded(player: Player): SaveData.SaveData?
	if not _started then
		return nil
	end
	local sd = _data[player]
	if sd and sd:IsLoaded() then
		return sd
	end
	return nil
end

-- Returns a list of all currently-loaded SaveDatas for players who haven't
-- started leaving. The array is fresh each call; mutating it (or Stopping
-- DataService) during iteration won't affect the loop. SaveDatas inside are
-- live references — mutating them mutates real data.
function DataService:GetAll(): { SaveData.SaveData }
	local result: { SaveData.SaveData } = {}
	if _started then
		for _, sd in _data do
			if sd:IsLoaded() then
				table.insert(result, sd)
			end
		end
	end
	return result
end

-- Client-side API: mirrors the Remote.RemoteClient pattern.
local DataClient = {}

-- Yields until the local player's data is published and the snapshot arrives.
-- Returns a ReplicatedState Mirror — :Get / :Observe / .Changed work; writes
-- error (writes must originate on the server through SaveData).
function DataClient.get(): any
	if not RunService:IsClient() then
		error("DataService.DataClient.get can only be called on the client", 2)
	end
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		error("DataService.DataClient.get: no LocalPlayer found", 2)
	end
	return ReplicatedState.subscribe(PUBLISH_NAME_PREFIX .. tostring(localPlayer.UserId))
end

DataService.DataClient = DataClient

return DataService
