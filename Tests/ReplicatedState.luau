local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ReplicatedState = require(ReplicatedStorage.Packages.ReplicatedState)
local Remote = require(ReplicatedStorage.Packages.Remote)
local State = require(ReplicatedStorage.Packages.State)
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
	-- Argument validation
	do
		local s = State.new()
		local ok = pcall(function()
			ReplicatedState.publish(s, 123 :: any)
		end)
		check("publish rejects non-string name", not ok)
		local ok2 = pcall(function()
			ReplicatedState.publish(s, "")
		end)
		check("publish rejects empty name", not ok2)
		local ok3 = pcall(function()
			ReplicatedState.publish({} :: any, "__test_bad_state")
		end)
		check("publish rejects non-State value", not ok3)
		local ok4 = pcall(function()
			ReplicatedState.publish(s, "__test_bad_options", { canSubscribe = 42 } :: any)
		end)
		check("publish rejects non-function canSubscribe", not ok4)
	end

	-- Double publish errors
	do
		local s = State.new({ x = 1 })
		local handle = ReplicatedState.publish(s, "__test_double")
		local ok = pcall(function()
			ReplicatedState.publish(State.new(), "__test_double")
		end)
		check("publish errors when name is already published", not ok)
		handle:Destroy()
	end

	-- Anonymous publish: name defaults to state.ID
	do
		local s = State.new({ marker = "anon" })
		local handle = ReplicatedState.publish(s)
		local root = ReplicatedStorage:FindFirstChild("_Remotes")
		local folder = root and root:FindFirstChild("ReplicatedState:" .. s.ID)
		check("publish without a name uses state.ID for the wire", folder ~= nil)
		handle:Destroy()
		check("anonymous publish:Destroy tears down the folder", folder ~= nil and folder.Parent == nil)
	end

	-- handle:Destroy clears registry and tears down the remote
	do
		local s = State.new()
		local handle = ReplicatedState.publish(s, "__test_destroy_publish")
		local root = ReplicatedStorage:FindFirstChild("_Remotes")
		local folder = root and root:FindFirstChild("ReplicatedState:__test_destroy_publish")
		check("publish provisions a Remote folder", folder ~= nil)
		handle:Destroy()
		check("publish:Destroy removes the underlying Remote folder", folder ~= nil and folder.Parent == nil)
		-- After Destroy, the name is reusable.
		local handle2 = ReplicatedState.publish(s, "__test_destroy_publish")
		check("publish name is reusable after Destroy", handle2 ~= nil)
		handle2:Destroy()
	end

	-- ReplicatedState.subscribe errors on the server
	do
		local ok = pcall(function()
			ReplicatedState.subscribe("__should_error")
		end)
		check("ReplicatedState.subscribe errors on the server", not ok)
	end

	-- Round-trip setup for client tests
	local rtState = State.new({ counter = 0, label = "initial", nested = { value = "n0" } })
	local rtHandle = ReplicatedState.publish(rtState, "__rt_state")

	-- Anonymous round-trip: publish with no name (uses state.ID), broker the ID via a named state
	local rtAnonState = State.new({ value = "anonymous-default" })
	ReplicatedState.publish(rtAnonState)
	ReplicatedState.publish(State.new({ anonId = rtAnonState.ID }), "__rt_anon_broker")

	local rtMutate = Remote.new("__rt_state_mutate")
	rtMutate:Connect(function()
		rtState:Set("counter", 100)
		rtState:Set("nested/value", "mutated")
	end)

	-- Always-deny gate
	local denyState = State.new({ secret = "hidden" })
	ReplicatedState.publish(denyState, "__rt_deny_state", {
		canSubscribe = function()
			return false
		end,
	})

	-- Per-player gate that allows everyone (smoke test)
	ReplicatedState.publish(State.new({ ok = true }), "__rt_allow_state", {
		canSubscribe = function(player)
			return player ~= nil
		end,
	})

	-- Separate state for Observe + delta test
	local observeState = State.new({ score = 0 })
	ReplicatedState.publish(observeState, "__rt_observe_state")
	local rtObserveTrigger = Remote.new("__rt_observe_trigger")
	rtObserveTrigger:Connect(function()
		observeState:Set("score", 7)
		task.wait(0.1)
		observeState:Set("score", 9)
	end)

	-- Keep handles reachable for the lifetime of the test session.
	local _ = rtHandle

	print(`[server] {passed} passed, {failed} failed`)
end

if RunService:IsClient() then
	-- Argument validation
	do
		local ok = pcall(function()
			ReplicatedState.subscribe(123 :: any)
		end)
		check("subscribe rejects non-string name", not ok)
		local ok2 = pcall(function()
			ReplicatedState.subscribe("")
		end)
		check("subscribe rejects empty name", not ok2)
	end

	-- publish errors on client
	do
		local ok = pcall(function()
			ReplicatedState.publish(State.new(), "__should_error")
		end)
		check("ReplicatedState.publish errors on the client", not ok)
	end

	-- Subscribe yields and returns a populated mirror
	do
		local mirror = ReplicatedState.subscribe("__rt_state")
		check("subscribe returns a non-nil mirror", mirror ~= nil)
		check("mirror has snapshot top-level key", mirror:Get("counter") == 0)
		check("mirror has snapshot string key", mirror:Get("label") == "initial")
		check("mirror has snapshot nested key", mirror:Get("nested/value") == "n0")
	end

	-- subscribe is cached
	do
		local m1 = ReplicatedState.subscribe("__rt_state")
		local m2 = ReplicatedState.subscribe("__rt_state")
		check("subscribe returns the same mirror for the same name", m1 == m2)
	end

	-- mirror writes are read-only
	do
		local mirror = ReplicatedState.subscribe("__rt_state")
		local ok, err = pcall(function()
			mirror:Set("foo", "bar")
		end)
		check("mirror:Set errors", not ok)
		check(
			"mirror:Set error mentions read-only",
			not ok and typeof(err) == "string" and string.find(err, "read%-only") ~= nil,
			`err={tostring(err)}`
		)
		local ok2 = pcall(function()
			mirror:Increment("counter")
		end)
		check("mirror:Increment errors", not ok2)
	end

	-- Delta replication: server mutates → client mirror updates and Changed fires
	do
		local mirror = ReplicatedState.subscribe("__rt_state")
		local got = {}
		local conn = mirror.Changed:Connect(function(k, v)
			table.insert(got, { k = k, v = v })
		end)

		RemoteClient.get("__rt_state_mutate"):Fire()

		waitFor(function()
			return #got >= 2
		end)
		check("Mirror Changed fired for at least 2 deltas", #got >= 2, `got count={#got}`)
		check("Mirror reflects 'counter' delta", mirror:Get("counter") == 100)
		check("Mirror reflects 'nested/value' delta", mirror:Get("nested/value") == "mutated")
		conn:Disconnect()
	end

	-- mirror:Observe fires for deltas after subscribe
	do
		local mirror = ReplicatedState.subscribe("__rt_observe_state")
		local fires = {}
		mirror:Observe("score", function(v)
			table.insert(fires, v)
		end)
		check("Observe fires once initially with snapshot value (0)", #fires == 1 and fires[1] == 0)

		RemoteClient.get("__rt_observe_trigger"):Fire()
		waitFor(function()
			return #fires >= 3
		end)
		check("Observe fires for delta sequence (initial, 7, 9)", #fires == 3, `fires={table.concat(fires, ",")}`)
		check("Observe sees the latest mutation", mirror:Get("score") == 9)
	end

	-- Allow-everyone gate works (smoke)
	do
		local mirror = ReplicatedState.subscribe("__rt_allow_state")
		check("Allow-everyone gate yields the mirror", mirror ~= nil and mirror:Get("ok") == true)
	end

	-- Always-deny gate raises an error
	do
		local ok, err = pcall(function()
			ReplicatedState.subscribe("__rt_deny_state")
		end)
		check("subscribe to always-deny gate errors", not ok)
		check(
			"deny error message mentions 'denied'",
			not ok and typeof(err) == "string" and string.find(err, "denied") ~= nil,
			`err={tostring(err)}`
		)
	end

	-- Unsubscribe clears cache; next subscribe gets a fresh mirror
	do
		local m1 = ReplicatedState.subscribe("__rt_allow_state")
		m1:Unsubscribe()
		local m2 = ReplicatedState.subscribe("__rt_allow_state")
		check("After Unsubscribe, subscribe returns a fresh mirror", m1 ~= m2)
		check("Fresh mirror has the snapshot data", m2:Get("ok") == true)
	end

	-- Anonymous publish round-trip: subscribe by state.ID communicated via a broker
	do
		local broker = ReplicatedState.subscribe("__rt_anon_broker")
		local anonId = broker:Get("anonId")
		check("Broker exposes the anonymous state's ID", typeof(anonId) == "string" and #anonId > 0)
		if typeof(anonId) == "string" then
			local mirror = ReplicatedState.subscribe(anonId)
			check("Subscribe by state.ID returns the right mirror", mirror:Get("value") == "anonymous-default")
		end
	end

	print(`[client] {passed} passed, {failed} failed`)
end

return true
