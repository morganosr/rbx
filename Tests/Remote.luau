local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remote = require(ReplicatedStorage.Packages.Remote)
local RemoteClient = Remote.RemoteClient

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

local function waitFor(predicate, timeout)
	timeout = timeout or 5
	local elapsed = 0
	while not predicate() and elapsed < timeout do
		task.wait(0.05)
		elapsed += 0.05
	end
	return predicate()
end

if RunService:IsServer() then
	-- Registry caching
	do
		local r1 = Remote.new("__test_registry")
		local r2 = Remote.new("__test_registry")
		check("Remote.new returns the same wrapper for the same name", r1 == r2)
	end

	-- Instance shape
	do
		local _ = Remote.new("__test_shape")
		local root = ReplicatedStorage:FindFirstChild("_Remotes")
		check("Server creates _Remotes folder", root ~= nil and root:IsA("Folder"))
		local folder = root and root:FindFirstChild("__test_shape")
		check("Server creates per-remote folder", folder ~= nil)
		local remoteEvent = folder and folder:FindFirstChild("Event")
		local remoteFunction = folder and folder:FindFirstChild("Function")
		check("Folder contains Event RemoteEvent", remoteEvent ~= nil and remoteEvent:IsA("RemoteEvent"))
		check("Folder contains Function RemoteFunction", remoteFunction ~= nil and remoteFunction:IsA("RemoteFunction"))
	end

	-- Destroy clears registry; re-create yields fresh wrapper
	do
		local r1 = Remote.new("__test_destroy")
		r1:Destroy()
		local r2 = Remote.new("__test_destroy")
		check("Destroy clears registry, .new returns a new wrapper", r1 ~= r2)
		r2:Destroy()
	end

	-- Destroy tears down the underlying folder + instances (no leak)
	do
		local r = Remote.new("__test_cleanup")
		local root = ReplicatedStorage:FindFirstChild("_Remotes")
		local folder = root and root:FindFirstChild("__test_cleanup")
		check("Folder exists after Remote.new", folder ~= nil)
		r:Destroy()
		check("Server :Destroy removes the underlying folder", folder ~= nil and folder.Parent == nil)
	end

	-- Argument validation
	do
		local ok = pcall(function()
			Remote.new(123 :: any)
		end)
		check("Remote.new rejects non-string name", not ok)
	end
	do
		local r = Remote.new("__test_validate")
		local ok = pcall(function()
			r:Connect(42 :: any)
		end)
		check("Remote:Connect rejects non-function", not ok)
		local ok2 = pcall(function()
			r:SetResponse(42 :: any)
		end)
		check("Remote:SetResponse rejects non-function", not ok2)
		local ok3 = pcall(function()
			r:Fire(nil :: any)
		end)
		check("Remote:Fire rejects non-Player", not ok3)
		local ok4 = pcall(function()
			r:FireExcept(nil :: any)
		end)
		check("Remote:FireExcept rejects non-Player", not ok4)
		local ok5 = pcall(function()
			r:Invoke(nil :: any)
		end)
		check("Remote:Invoke rejects non-Player", not ok5)
		local ok6 = pcall(function()
			r:ConnectOnce(42 :: any)
		end)
		check("Remote:ConnectOnce rejects non-function", not ok6)
		local ok7 = pcall(function()
			r:SetInvokeTimeout(-1)
		end)
		check("Remote:SetInvokeTimeout rejects negative number", not ok7)
		local ok8 = pcall(function()
			r:SetInvokeTimeout("nope" :: any)
		end)
		check("Remote:SetInvokeTimeout rejects non-number", not ok8)
		r:Destroy()
	end

	-- Server cannot call RemoteClient.get
	do
		local ok = pcall(function()
			RemoteClient.get("__test_should_error")
		end)
		check("RemoteClient.get errors on the server", not ok)
	end

	-- Unnamed Remotes get auto-generated UUID names
	do
		local r = Remote.new()
		check("Remote.new() returns a wrapper with a non-empty .Name", typeof(r.Name) == "string" and #r.Name > 0)
		local r2 = Remote.new()
		check("Two unnamed Remotes get different names", r.Name ~= r2.Name)
	end

	-- Broker that hands clients fresh UUID-named Remotes
	local rtUuidBroker = Remote.new("__rt_uuid_broker")
	rtUuidBroker:SetResponse(function(_player)
		local fresh = Remote.new()
		fresh:SetResponse(function(_p, n)
			return n * 3
		end)
		return fresh.Name
	end)

	-- Round-trip handlers for client tests
	local rtFire = Remote.new("__rt_fire")
	rtFire:Connect(function(player, n)
		rtFire:Fire(player, n * 2)
	end)

	local rtInvoke = Remote.new("__rt_invoke")
	rtInvoke:SetResponse(function(_player, n)
		return n + 100
	end)

	local rtFireAll = Remote.new("__rt_fireall")
	rtFireAll:Connect(function(_player)
		rtFireAll:FireAll("hello")
	end)

	-- Server-side Connect listener receives the firing player
	local rtPlayerArg = Remote.new("__rt_player_arg")
	rtPlayerArg:Connect(function(player)
		rtPlayerArg:Fire(player, player == player and player.Name or "?")
	end)

	-- Round-trip: ConnectOnce — server fires twice, client should only see one
	local rtConnectOnceTrigger = Remote.new("__rt_connect_once_trigger")
	local rtConnectOnceTarget = Remote.new("__rt_connect_once_target")
	rtConnectOnceTrigger:Connect(function(player)
		rtConnectOnceTarget:Fire(player, "first")
		task.wait(0.1)
		rtConnectOnceTarget:Fire(player, "second")
	end)

	-- Round-trip: Wait
	local rtWaitTrigger = Remote.new("__rt_wait_trigger")
	local rtWaitTarget = Remote.new("__rt_wait_target")
	rtWaitTrigger:Connect(function(player)
		rtWaitTarget:Fire(player, "wait_value", 42)
	end)

	-- Round-trip: FireExcept — excluded player should not receive 'should_not_arrive'
	local rtFireExceptTrigger = Remote.new("__rt_fire_except_trigger")
	local rtFireExceptTarget = Remote.new("__rt_fire_except_target")
	rtFireExceptTrigger:Connect(function(player)
		rtFireExceptTarget:FireExcept(player, "should_not_arrive")
		task.wait(0.2)
		rtFireExceptTarget:Fire(player, "definitive")
	end)

	-- Round-trip: server :Invoke + client :SetResponse
	local rtServerInvoke = Remote.new("__rt_server_invoke")
	local rtServerInvokeResult = Remote.new("__rt_server_invoke_result")
	rtServerInvoke:Connect(function(player)
		local ok, result = pcall(function()
			return rtServerInvoke:Invoke(player, 8)
		end)
		rtServerInvokeResult:Fire(player, ok, result)
	end)

	-- Round-trip: Invoke timeout — slow SetResponse on the server
	local rtSlowInvoke = Remote.new("__rt_slow_invoke")
	rtSlowInvoke:SetResponse(function()
		task.wait(60)
		return "too_late"
	end)

	print(`[server] {passed} passed, {failed} failed`)
end

if RunService:IsClient() then
	-- Registry caching
	do
		local r1 = RemoteClient.get("__rt_fire")
		local r2 = RemoteClient.get("__rt_fire")
		check("RemoteClient.get returns the same wrapper for the same name", r1 == r2)
	end

	-- Argument validation
	do
		local ok = pcall(function()
			RemoteClient.get(123 :: any)
		end)
		check("RemoteClient.get rejects non-string name", not ok)
	end
	do
		local r = RemoteClient.get("__rt_fire")
		local ok = pcall(function()
			r:Connect(42 :: any)
		end)
		check("RemoteClient:Connect rejects non-function", not ok)
	end

	-- Client cannot call Remote.new
	do
		local ok = pcall(function()
			Remote.new("__should_error")
		end)
		check("Remote.new errors on the client", not ok)
	end

	-- Round-trip Fire (client → server → client)
	do
		local r = RemoteClient.get("__rt_fire")
		local got
		r:Connect(function(n)
			got = n
		end)
		r:Fire(21)
		local ok = waitFor(function()
			return got ~= nil
		end)
		check("Round-trip Fire: server doubles 21 to 42", ok and got == 42, `got={tostring(got)}`)
	end

	-- Round-trip Invoke
	do
		local r = RemoteClient.get("__rt_invoke")
		local result = r:Invoke(7)
		check("Round-trip Invoke: server adds 100 to 7", result == 107, `got={tostring(result)}`)
	end

	-- Round-trip FireAll (client triggers, server FireAlls back)
	do
		local r = RemoteClient.get("__rt_fireall")
		local got
		r:Connect(function(s)
			got = s
		end)
		r:Fire()
		local ok = waitFor(function()
			return got ~= nil
		end)
		check("Round-trip FireAll: client receives broadcast 'hello'", ok and got == "hello", `got={tostring(got)}`)
	end

	-- Server-side Connect listener gets (player, ...)
	do
		local r = RemoteClient.get("__rt_player_arg")
		local localPlayer = game:GetService("Players").LocalPlayer
		local got
		r:Connect(function(name)
			got = name
		end)
		r:Fire()
		local ok = waitFor(function()
			return got ~= nil
		end)
		check(
			"Server :Connect listener receives Player as first arg",
			ok and got == (localPlayer and localPlayer.Name or nil),
			`got={tostring(got)}`
		)
	end

	-- Anonymous Remote: server hands client a UUID via broker, client uses it
	do
		local broker = RemoteClient.get("__rt_uuid_broker")
		local uuid = broker:Invoke()
		check("UUID broker returns a non-empty string", typeof(uuid) == "string" and #uuid > 0)
		if typeof(uuid) == "string" and #uuid > 0 then
			local fresh = RemoteClient.get(uuid)
			check("RemoteClient.get(uuid) exposes .Name matching the uuid", fresh.Name == uuid)
			local result = fresh:Invoke(5)
			check("Anonymous Remote round-trip Invoke (5 * 3 = 15)", result == 15, `got={tostring(result)}`)
		end
	end

	-- ConnectOnce: only fires for the first server fire
	do
		local trigger = RemoteClient.get("__rt_connect_once_trigger")
		local target = RemoteClient.get("__rt_connect_once_target")
		local count = 0
		target:ConnectOnce(function()
			count += 1
		end)
		trigger:Fire()
		task.wait(0.5)
		check("ConnectOnce fires only once when the server fires twice", count == 1, `count={count}`)
	end

	-- Wait: yields and resumes with next fire's args
	do
		local trigger = RemoteClient.get("__rt_wait_trigger")
		local target = RemoteClient.get("__rt_wait_target")
		local got
		task.spawn(function()
			local a, b = target:Wait()
			got = { a, b }
		end)
		trigger:Fire()
		waitFor(function()
			return got ~= nil
		end)
		check(
			"Wait resumes with the next fire's args",
			got and got[1] == "wait_value" and got[2] == 42,
			`got={tostring(got and got[1])},{tostring(got and got[2])}`
		)
	end

	-- FireExcept: excluded local player does not receive 'should_not_arrive'
	do
		local trigger = RemoteClient.get("__rt_fire_except_trigger")
		local target = RemoteClient.get("__rt_fire_except_target")
		local received = {}
		target:Connect(function(s)
			table.insert(received, s)
		end)
		trigger:Fire()
		waitFor(function()
			return table.find(received, "definitive") ~= nil
		end)
		check(
			"FireExcept does not deliver to the excluded player",
			table.find(received, "should_not_arrive") == nil and table.find(received, "definitive") ~= nil,
			`received={table.concat(received, ",")}`
		)
	end

	-- Server :Invoke + client :SetResponse round-trip
	do
		local rt = RemoteClient.get("__rt_server_invoke")
		local rtResult = RemoteClient.get("__rt_server_invoke_result")
		rt:SetResponse(function(n)
			return n + 1000
		end)
		local got
		rtResult:Connect(function(ok, result)
			got = { ok = ok, result = result }
		end)
		rt:Fire()
		waitFor(function()
			return got ~= nil
		end)
		check(
			"Server :Invoke calls client :SetResponse and gets the response (8 + 1000 = 1008)",
			got and got.ok == true and got.result == 1008,
			`got={tostring(got and got.ok)},{tostring(got and got.result)}`
		)
	end

	-- Invoke timeout
	do
		local rt = RemoteClient.get("__rt_slow_invoke")
		rt:SetInvokeTimeout(0.5)
		local startTime = os.clock()
		local ok, err = pcall(function()
			rt:Invoke()
		end)
		local elapsed = os.clock() - startTime
		check("Invoke errors when the server takes too long", not ok)
		check(
			"Invoke timeout error message mentions 'timed out'",
			not ok and typeof(err) == "string" and string.find(err, "timed out") ~= nil,
			`err={tostring(err)}`
		)
		check("Invoke timeout fires near the configured timeout", elapsed < 2, `elapsed={elapsed}`)
	end

	print(`[client] {passed} passed, {failed} failed`)
end

return true
