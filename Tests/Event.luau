local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Event = require(ReplicatedStorage.Packages.Event)

local passed, failed = 0, 0
local function check(name, condition, detail)
	if condition then
		passed += 1
		print(`[PASS] {name}`)
	else
		failed += 1
		warn(`[FAIL] {name} — {detail or ""}`)
	end
end

-- Connect / Fire basics
do
	local e = Event.new()
	local fired = false
	e:Connect(function()
		fired = true
	end)
	e:Fire()
	check("Single listener fires on Fire", fired)
end

do
	local e = Event.new()
	local count = 0
	e:Connect(function()
		count += 1
	end)
	e:Connect(function()
		count += 1
	end)
	e:Connect(function()
		count += 1
	end)
	e:Fire()
	check("Multiple listeners all fire", count == 3)
end

do
	local e = Event.new()
	local got
	e:Connect(function(...)
		got = { ... }
	end)
	e:Fire(1, "two", true)
	check("Fire passes args", got[1] == 1 and got[2] == "two" and got[3] == true)
end

-- Connection object shape
do
	local e = Event.new()
	local conn = e:Connect(function() end)
	check("Connect returns object with :Disconnect", typeof(conn.Disconnect) == "function")
	check("Connect returns object with :IsConnected", typeof(conn.IsConnected) == "function")
	check("Connection IsConnected: true after connect", conn:IsConnected())
	conn:Disconnect()
	check("Connection IsConnected: false after disconnect", not conn:IsConnected())
end

do
	local e = Event.new()
	local conn = e:Connect(function() end)
	conn:Disconnect()
	conn:Disconnect()
	check("Disconnect is idempotent", not conn:IsConnected())
end

do
	local e = Event.new()
	local ok = pcall(function()
		e:Connect(123)
	end)
	check("Connect rejects non-function", not ok)
end

-- Regression: index-drift bug. Disconnecting a middle connection used to
-- shift indices and remove the wrong one on later disconnect calls.
do
	local e = Event.new()
	local fired = {}
	e:Connect(function()
		table.insert(fired, "A")
	end)
	local connB = e:Connect(function()
		table.insert(fired, "B")
	end)
	e:Connect(function()
		table.insert(fired, "C")
	end)
	connB:Disconnect()
	e:Fire()
	check("Index-drift: A still fires", table.find(fired, "A") ~= nil)
	check("Index-drift: B (disconnected) does not fire", table.find(fired, "B") == nil)
	check("Index-drift: C still fires", table.find(fired, "C") ~= nil)
	check("Index-drift: exactly two listeners fired", #fired == 2)
end

-- Snapshot during Fire: a listener that disconnects another listener mid-fire
-- doesn't cause the disconnected one to fire (or crash iteration).
do
	local e = Event.new()
	local order = {}
	local connB
	e:Connect(function()
		table.insert(order, "A")
		connB:Disconnect()
	end)
	connB = e:Connect(function()
		table.insert(order, "B")
	end)
	e:Connect(function()
		table.insert(order, "C")
	end)
	e:Fire()
	check("Snapshot: B disconnected by A doesn't fire", table.find(order, "B") == nil)
	check("Snapshot: C still fires after B was disconnected", table.find(order, "C") ~= nil)
	check("Snapshot: only A and C fired", #order == 2)
end

-- A self-disconnecting listener fires once and stops.
do
	local e = Event.new()
	local count = 0
	local conn
	conn = e:Connect(function()
		count += 1
		conn:Disconnect()
	end)
	e:Fire()
	e:Fire()
	check("Self-disconnect: fires only once", count == 1)
end

-- A listener throwing doesn't stop other listeners (task.spawn isolates).
do
	local e = Event.new()
	local secondFired = false
	e:Connect(function()
		error("intentional")
	end)
	e:Connect(function()
		secondFired = true
	end)
	e:Fire()
	check("Throwing listener doesn't strand others", secondFired)
end

-- ConnectOnce
do
	local e = Event.new()
	local count = 0
	e:ConnectOnce(function()
		count += 1
	end)
	e:Fire()
	e:Fire()
	check("ConnectOnce fires only once", count == 1)
end

do
	local e = Event.new()
	local got
	e:ConnectOnce(function(x)
		got = x
	end)
	e:Fire(42)
	check("ConnectOnce passes args on its single fire", got == 42)
end

-- SetCallback / Fire / Invoke
do
	local e = Event.new()
	local cbFired = false
	e:SetCallback(function()
		cbFired = true
	end)
	e:Fire()
	check("SetCallback: callback fires on Fire", cbFired)
end

do
	local e = Event.new()
	e:SetCallback(function(x)
		return x * 2
	end)
	check("Invoke returns callback result", e:Invoke(5) == 10)
end

do
	local e = Event.new()
	local cbFired = false
	e:SetCallback(function()
		cbFired = true
	end)
	check("Invoke fires callback (verified by sentinel)", e:Invoke() == nil and cbFired)
end

do
	local e = Event.new()
	local listenerFired = false
	e:Connect(function()
		listenerFired = true
	end)
	e:SetCallback(function(x)
		return x + 1
	end)
	local result = e:Invoke(10)
	check("Invoke: listeners still fire alongside callback", listenerFired)
	check("Invoke: returns callback's value", result == 11)
end

do
	local e = Event.new()
	e:Connect(function() end)
	check("Invoke without callback returns nothing", e:Invoke() == nil)
end

do
	local e = Event.new()
	local cbFired = false
	e:SetCallback(function()
		cbFired = true
	end)
	e:DestroyCallback()
	e:Fire()
	check("DestroyCallback: callback no longer fires", not cbFired)
end

do
	local e = Event.new()
	local ok = pcall(function()
		e:SetCallback(123)
	end)
	check("SetCallback rejects non-function", not ok)
end

-- Wait
do
	local e = Event.new()
	local got
	task.spawn(function()
		got = e:Wait()
	end)
	e:Fire("hello")
	check("Wait yields and returns next Fire's args", got == "hello")
end

do
	local e = Event.new()
	local a, b
	task.spawn(function()
		a, b = e:Wait()
	end)
	e:Fire("x", 7)
	check("Wait returns multiple args", a == "x" and b == 7)
end

-- DisconnectAll / Destroy
do
	local e = Event.new()
	local fired = false
	local conn = e:Connect(function()
		fired = true
	end)
	e:DisconnectAll()
	e:Fire()
	check("DisconnectAll: listener no longer fires", not fired)
	check("DisconnectAll: held connection reports disconnected", not conn:IsConnected())
end

do
	local e = Event.new()
	e:Connect(function() end)
	e:DisconnectAll()
	-- Should be able to reuse the event after DisconnectAll
	local fired = false
	e:Connect(function()
		fired = true
	end)
	e:Fire()
	check("DisconnectAll: event reusable afterwards", fired)
end

do
	local e = Event.new()
	local listenerFired, cbFired = false, false
	local conn = e:Connect(function()
		listenerFired = true
	end)
	e:SetCallback(function()
		cbFired = true
	end)
	e:Destroy()
	e:Fire()
	check("Destroy: listeners cleared", not listenerFired)
	check("Destroy: callback cleared", not cbFired)
	check("Destroy: held connection reports disconnected", not conn:IsConnected())
end

print(`\n--- {passed} passed, {failed} failed ---`)

return true
