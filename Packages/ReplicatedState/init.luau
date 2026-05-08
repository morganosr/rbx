local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Remote = require(script.Parent.Remote)
local State = require(script.Parent.State)

local RemoteClient = Remote.RemoteClient

local REMOTE_NAME_PREFIX = "ReplicatedState:"
local READ_ONLY_ERROR = "ReplicatedState mirror is read-only. Mutations must originate on the server."

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

export type PublishOptions = {
	canSubscribe: ((player: Player) -> boolean)?,
}

export type PublishedState = {
	Destroy: (self: PublishedState) -> (),
}

export type Mirror = {
	Data: { [any]: any },
	ID: string,
	Changed: any,
	Get: (self: Mirror, key: string) -> any,
	Observe: (self: Mirror, key: string, callback: (any, string) -> (), scope: string?) -> any,
	Unsubscribe: (self: Mirror) -> (),
}

local PublishedState = {}
PublishedState.__index = PublishedState

local ReplicatedState = {}

local serverRegistry: { [string]: any } = {}
local clientCache: { [string]: any } = {}
local pendingSubscribes: { [string]: { waiters: { thread } } } = {}

function ReplicatedState.publish(state: State.State, name: string?, options: PublishOptions?): PublishedState
	if not RunService:IsServer() then
		error("ReplicatedState.publish can only be called on the server", 2)
	end
	if type(state) ~= "table" then
		error("ReplicatedState.publish expects a State instance", 2)
	end
	if type((state :: any).Changed) ~= "table" then
		error(
			"ReplicatedState.publish: state has no .Changed event — requires State ^1.1.0. "
				.. "Bump the State dependency in your wally.toml.",
			2
		)
	end
	if name == nil then
		name = (state :: any).ID
		if typeof(name) ~= "string" or #(name :: string) == 0 then
			error("ReplicatedState.publish: state has no usable .ID for default naming", 2)
		end
	elseif typeof(name) ~= "string" or #name == 0 then
		error("ReplicatedState.publish expects a non-empty string name or nil", 2)
	end
	if serverRegistry[name :: string] then
		error(`ReplicatedState '{name}' is already published`, 2)
	end

	options = options or {}
	local canSubscribe = (options :: PublishOptions).canSubscribe or function()
		return true
	end
	if typeof(canSubscribe) ~= "function" then
		error("ReplicatedState.publish: options.canSubscribe must be a function", 2)
	end

	local remote = Remote.new(REMOTE_NAME_PREFIX .. (name :: string))
	local subscribers: { [Player]: true } = {}

	local self = setmetatable({
		_state = state,
		_name = name,
		_remote = remote,
		_subscribers = subscribers,
		_destroyed = false,
		_remoteConn = nil,
		_changedConn = nil,
		_playerLeavingConn = nil,
	}, PublishedState)

	self._remoteConn = remote:Connect(function(player, msgType)
		if self._destroyed then
			return
		end
		if msgType == "subscribe" then
			local ok, allowed = pcall(canSubscribe, player)
			if not ok then
				remote:Fire(player, "denied", `canSubscribe errored: {tostring(allowed)}`)
				return
			end
			if not allowed then
				remote:Fire(player, "denied", "permission denied")
				return
			end
			subscribers[player] = true
			remote:Fire(player, "snapshot", deepClone(state.Data))
		elseif msgType == "unsubscribe" then
			subscribers[player] = nil
		end
	end)

	self._changedConn = (state :: any).Changed:Connect(function(key, value)
		if self._destroyed then
			return
		end
		for player in subscribers do
			remote:Fire(player, "delta", key, value)
		end
	end)

	self._playerLeavingConn = Players.PlayerRemoving:Connect(function(player)
		subscribers[player] = nil
	end)

	serverRegistry[name :: string] = self
	return (self :: any) :: PublishedState
end

function PublishedState:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true

	if self._remoteConn then
		self._remoteConn:Disconnect()
		self._remoteConn = nil
	end
	if self._changedConn then
		self._changedConn:Disconnect()
		self._changedConn = nil
	end
	if self._playerLeavingConn then
		self._playerLeavingConn:Disconnect()
		self._playerLeavingConn = nil
	end

	table.clear(self._subscribers)
	self._remote:Destroy()

	if serverRegistry[self._name] == self then
		serverRegistry[self._name] = nil
	end
end

function ReplicatedState.subscribe(name: string): Mirror
	if not RunService:IsClient() then
		error("ReplicatedState.subscribe can only be called on the client", 2)
	end
	if typeof(name) ~= "string" or #name == 0 then
		error("ReplicatedState.subscribe expects a non-empty string name", 2)
	end

	local cached = clientCache[name]
	if cached then
		return cached
	end

	local pending = pendingSubscribes[name]
	if pending then
		table.insert(pending.waiters, coroutine.running())
		local result, payload = coroutine.yield()
		if result == "denied" then
			error(`ReplicatedState.subscribe '{name}' denied: {tostring(payload)}`, 2)
		end
		return payload
	end

	local newPending = { waiters = { coroutine.running() } }
	pendingSubscribes[name] = newPending

	local remoteClient = RemoteClient.get(REMOTE_NAME_PREFIX .. name)
	local mirror: any = nil
	local conn: any = nil
	local subscribed = true

	local function unsubscribeFn(self)
		if not subscribed then
			return
		end
		subscribed = false
		pcall(function()
			remoteClient:Fire("unsubscribe")
		end)
		if conn then
			conn:Disconnect()
			conn = nil
		end
		if clientCache[name] == self then
			clientCache[name] = nil
		end
	end

	local function readOnlyErr()
		error(READ_ONLY_ERROR, 2)
	end

	conn = remoteClient:Connect(function(msgType, ...)
		if msgType == "snapshot" and mirror == nil then
			local snapshot = ...
			mirror = State.new(snapshot)
			mirror.Set = readOnlyErr
			mirror.Increment = readOnlyErr
			mirror.Unsubscribe = unsubscribeFn

			clientCache[name] = mirror
			pendingSubscribes[name] = nil
			local waiters = newPending.waiters
			newPending.waiters = {}
			for _, thread in waiters do
				task.spawn(thread, "ok", mirror)
			end
		elseif msgType == "delta" then
			if mirror then
				State.Set(mirror, ...)
			end
		elseif msgType == "denied" and mirror == nil then
			pendingSubscribes[name] = nil
			local waiters = newPending.waiters
			newPending.waiters = {}
			if conn then
				conn:Disconnect()
				conn = nil
			end
			local reason = ...
			for _, thread in waiters do
				task.spawn(thread, "denied", reason)
			end
		end
	end)

	remoteClient:Fire("subscribe")

	local result, payload = coroutine.yield()
	if result == "denied" then
		error(`ReplicatedState.subscribe '{name}' denied: {tostring(payload)}`, 2)
	end
	return payload
end

return ReplicatedState
