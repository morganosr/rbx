local Event = {}
Event.__index = Event

export type Connection = {
	Disconnect: (self: Connection) -> (),
	IsConnected: (self: Connection) -> boolean,
}

export type Event<T...> = {
	Connect: (self: Event<T...>, listener: (T...) -> ()) -> Connection,
	ConnectOnce: (self: Event<T...>, listener: (T...) -> ()) -> Connection,
	SetCallback: (self: Event<T...>, listener: (T...) -> any) -> (),
	Fire: (self: Event<T...>, T...) -> (),
	Invoke: (self: Event<T...>, T...) -> any,
	Wait: (self: Event<T...>) -> T...,
	DisconnectAll: (self: Event<T...>) -> (),
	DestroyCallback: (self: Event<T...>) -> (),
	Destroy: (self: Event<T...>) -> (),
}

function Event.new<T...>(): Event<T...>
	local self = setmetatable({
		_listeners = {},
		_callback = nil,
	}, Event)
	return (self :: any) :: Event<T...>
end

function Event:Connect(listener)
	if typeof(listener) ~= "function" then
		error("Listener must be a function", 2)
	end
	local listeners = self._listeners
	local connection = { _listener = listener }
	function connection.Disconnect(conn)
		if not conn._listener then
			return
		end
		conn._listener = nil
		local idx = table.find(listeners, conn)
		if idx then
			table.remove(listeners, idx)
		end
	end
	function connection.IsConnected(conn)
		return conn._listener ~= nil
	end
	table.insert(listeners, connection)
	return connection
end

function Event:ConnectOnce(listener)
	if typeof(listener) ~= "function" then
		error("Listener must be a function", 2)
	end
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		listener(...)
	end)
	return connection
end

function Event:SetCallback(listener)
	if typeof(listener) ~= "function" then
		error("Listener must be a function", 2)
	end
	self._callback = listener
end

function Event:Fire(...)
	local snapshot = table.clone(self._listeners)
	for _, connection in snapshot do
		if connection._listener then
			task.spawn(connection._listener, ...)
		end
	end
	if self._callback then
		task.spawn(self._callback, ...)
	end
end

function Event:Invoke(...)
	local snapshot = table.clone(self._listeners)
	for _, connection in snapshot do
		if connection._listener then
			task.spawn(connection._listener, ...)
		end
	end
	if self._callback then
		return self._callback(...)
	end
	return
end

function Event:Wait()
	local thread = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Event:DisconnectAll()
	local listeners = self._listeners
	for _, connection in listeners do
		connection._listener = nil
	end
	self._listeners = {}
end

function Event:DestroyCallback()
	self._callback = nil
end

function Event:Destroy()
	self:DisconnectAll()
	self._callback = nil
end

return Event
