local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Event = require(script.Parent.Event)

local FOLDER_NAME = "_Remotes"
local DEFAULT_INVOKE_TIMEOUT = 10

export type Connection = Event.Connection

export type Remote<T...> = {
	Name: string,
	Connect: (self: Remote<T...>, listener: (player: Player, T...) -> ()) -> Connection,
	ConnectOnce: (self: Remote<T...>, listener: (player: Player, T...) -> ()) -> Connection,
	SetResponse: (self: Remote<T...>, callback: (player: Player, T...) -> ...any) -> (),
	Fire: (self: Remote<T...>, player: Player, T...) -> (),
	FireAll: (self: Remote<T...>, T...) -> (),
	FireExcept: (self: Remote<T...>, player: Player, T...) -> (),
	Invoke: (self: Remote<T...>, player: Player, T...) -> ...any,
	Wait: (self: Remote<T...>) -> (Player, T...),
	SetInvokeTimeout: (self: Remote<T...>, seconds: number) -> (),
	Destroy: (self: Remote<T...>) -> (),
}

export type RemoteClient<T...> = {
	Name: string,
	Connect: (self: RemoteClient<T...>, listener: (T...) -> ()) -> Connection,
	ConnectOnce: (self: RemoteClient<T...>, listener: (T...) -> ()) -> Connection,
	SetResponse: (self: RemoteClient<T...>, callback: (T...) -> ...any) -> (),
	Fire: (self: RemoteClient<T...>, T...) -> (),
	Invoke: (self: RemoteClient<T...>, T...) -> ...any,
	Wait: (self: RemoteClient<T...>) -> T...,
	SetInvokeTimeout: (self: RemoteClient<T...>, seconds: number) -> (),
	Destroy: (self: RemoteClient<T...>) -> (),
}

local Remote = {}
Remote.__index = Remote

local RemoteClient = {}
RemoteClient.__index = RemoteClient

local serverRegistry: { [string]: any } = {}
local clientRegistry: { [string]: any } = {}

local function ensureServerRoot(): Folder
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local function ensureRemoteInstances(name: string): (Folder, RemoteEvent, RemoteFunction)
	local root = ensureServerRoot()
	local folder = root:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = root
	end
	local remoteEvent = folder:FindFirstChild("Event")
	if not remoteEvent then
		remoteEvent = Instance.new("RemoteEvent")
		remoteEvent.Name = "Event"
		remoteEvent.Parent = folder
	end
	local remoteFunction = folder:FindFirstChild("Function")
	if not remoteFunction then
		remoteFunction = Instance.new("RemoteFunction")
		remoteFunction.Name = "Function"
		remoteFunction.Parent = folder
	end
	return folder, remoteEvent, remoteFunction
end

-- Wraps a yielding network call with a configurable timeout.
-- Returns the call's results on success, re-raises caller errors,
-- and errors with a clear message on timeout.
local function timedInvoke(callable, args, timeout: number, name: string)
	local thread = coroutine.running()
	local responded = false

	task.spawn(function()
		local ok, results = pcall(function()
			return table.pack(callable(table.unpack(args, 1, args.n)))
		end)
		if responded then
			return
		end
		responded = true
		if ok then
			task.spawn(thread, "ok", results)
		else
			task.spawn(thread, "err", results)
		end
	end)

	if timeout ~= math.huge then
		task.delay(timeout, function()
			if responded then
				return
			end
			responded = true
			task.spawn(thread, "timeout", nil)
		end)
	end

	local status, payload = coroutine.yield()
	if status == "timeout" then
		error(`Invoke on Remote '{name}' timed out after {timeout}s`, 3)
	elseif status == "err" then
		error(payload, 3)
	end
	return table.unpack(payload, 1, payload.n)
end

function Remote.new<T...>(name: string?): Remote<T...>
	if not RunService:IsServer() then
		error("Remote.new can only be called on the server", 2)
	end
	if name == nil then
		name = HttpService:GenerateGUID(false)
	elseif typeof(name) ~= "string" then
		error("Remote.new expects a string name or nil", 2)
	end
	local existing = serverRegistry[name :: string]
	if existing then
		return existing
	end

	local folder, remoteEvent, remoteFunction = ensureRemoteInstances(name :: string)
	local self = setmetatable({
		Name = name,
		_folder = folder,
		_remoteEvent = remoteEvent,
		_remoteFunction = remoteFunction,
		_inbound = Event.new(),
		_signalConn = nil,
		_invokeTimeout = DEFAULT_INVOKE_TIMEOUT,
	}, Remote)
	self._signalConn = remoteEvent.OnServerEvent:Connect(function(player, ...)
		self._inbound:Fire(player, ...)
	end)
	remoteFunction.OnServerInvoke = function(player, ...)
		return self._inbound:Invoke(player, ...)
	end
	serverRegistry[name :: string] = self
	return (self :: any) :: Remote<T...>
end

function Remote:Connect(listener)
	if typeof(listener) ~= "function" then
		error("Listener must be a function", 2)
	end
	return self._inbound:Connect(listener)
end

function Remote:ConnectOnce(listener)
	if typeof(listener) ~= "function" then
		error("Listener must be a function", 2)
	end
	return self._inbound:ConnectOnce(listener)
end

function Remote:SetResponse(callback)
	if typeof(callback) ~= "function" then
		error("Callback must be a function", 2)
	end
	self._inbound:SetCallback(callback)
end

function Remote:Fire(player, ...)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		error("Remote:Fire expects a Player as the first argument", 2)
	end
	self._remoteEvent:FireClient(player, ...)
end

function Remote:FireAll(...)
	self._remoteEvent:FireAllClients(...)
end

function Remote:FireExcept(player, ...)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		error("Remote:FireExcept expects a Player as the first argument", 2)
	end
	for _, p in Players:GetPlayers() do
		if p ~= player then
			self._remoteEvent:FireClient(p, ...)
		end
	end
end

function Remote:Invoke(player, ...)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		error("Remote:Invoke expects a Player as the first argument", 2)
	end
	local rf = self._remoteFunction
	return timedInvoke(function(...)
		return rf:InvokeClient(player, ...)
	end, table.pack(...), self._invokeTimeout, self.Name)
end

function Remote:Wait()
	return self._inbound:Wait()
end

function Remote:SetInvokeTimeout(seconds: number)
	if typeof(seconds) ~= "number" or seconds < 0 then
		error("SetInvokeTimeout expects a non-negative number", 2)
	end
	self._invokeTimeout = if seconds == 0 then math.huge else seconds
end

function Remote:Destroy()
	if self._signalConn then
		self._signalConn:Disconnect()
		self._signalConn = nil
	end
	self._inbound:Destroy()
	if self._remoteFunction then
		self._remoteFunction.OnServerInvoke = nil
	end
	if serverRegistry[self.Name] == self then
		serverRegistry[self.Name] = nil
	end
	if self._folder then
		self._folder:Destroy()
		self._folder = nil
		self._remoteEvent = nil
		self._remoteFunction = nil
	end
end

function RemoteClient.get<T...>(name: string): RemoteClient<T...>
	if not RunService:IsClient() then
		error("RemoteClient.get can only be called on the client", 2)
	end
	if typeof(name) ~= "string" then
		error("RemoteClient.get expects a string name", 2)
	end
	local existing = clientRegistry[name]
	if existing then
		return existing
	end

	local root = ReplicatedStorage:WaitForChild(FOLDER_NAME)
	local folder = root:WaitForChild(name)
	local remoteEvent = folder:WaitForChild("Event")
	local remoteFunction = folder:WaitForChild("Function")

	local self = setmetatable({
		Name = name,
		_remoteEvent = remoteEvent,
		_remoteFunction = remoteFunction,
		_inbound = Event.new(),
		_signalConn = nil,
		_invokeTimeout = DEFAULT_INVOKE_TIMEOUT,
	}, RemoteClient)
	self._signalConn = remoteEvent.OnClientEvent:Connect(function(...)
		self._inbound:Fire(...)
	end)
	remoteFunction.OnClientInvoke = function(...)
		return self._inbound:Invoke(...)
	end
	clientRegistry[name] = self
	return (self :: any) :: RemoteClient<T...>
end

function RemoteClient:Connect(listener)
	if typeof(listener) ~= "function" then
		error("Listener must be a function", 2)
	end
	return self._inbound:Connect(listener)
end

function RemoteClient:ConnectOnce(listener)
	if typeof(listener) ~= "function" then
		error("Listener must be a function", 2)
	end
	return self._inbound:ConnectOnce(listener)
end

function RemoteClient:SetResponse(callback)
	if typeof(callback) ~= "function" then
		error("Callback must be a function", 2)
	end
	self._inbound:SetCallback(callback)
end

function RemoteClient:Fire(...)
	self._remoteEvent:FireServer(...)
end

function RemoteClient:Invoke(...)
	local rf = self._remoteFunction
	return timedInvoke(function(...)
		return rf:InvokeServer(...)
	end, table.pack(...), self._invokeTimeout, self.Name)
end

function RemoteClient:Wait()
	return self._inbound:Wait()
end

function RemoteClient:SetInvokeTimeout(seconds: number)
	if typeof(seconds) ~= "number" or seconds < 0 then
		error("SetInvokeTimeout expects a non-negative number", 2)
	end
	self._invokeTimeout = if seconds == 0 then math.huge else seconds
end

function RemoteClient:Destroy()
	if self._signalConn then
		self._signalConn:Disconnect()
		self._signalConn = nil
	end
	self._inbound:Destroy()
	if clientRegistry[self.Name] == self then
		clientRegistry[self.Name] = nil
	end
end

Remote.RemoteClient = RemoteClient
return Remote
