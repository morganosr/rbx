local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DataService = require(ReplicatedStorage.Packages.DataService)
local Remote = require(ReplicatedStorage.Packages.Remote)
local RemoteClient = Remote.RemoteClient

local READY_REMOTE_NAME = "__rt_dataservice_ready"
local MUTATE_REMOTE_NAME = "__rt_dataservice_mutate"

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
	local DataStoreService = game:GetService("DataStoreService")
	local TEST_DATASTORE = "PlayerDataTest"
	local testStore = DataStoreService:GetDataStore(TEST_DATASTORE)

	-- DataStore sanity: surface API access disabled clearly.
	do
		local ok, err = pcall(function()
			testStore:GetAsync("__ping__")
		end)
		if not ok then
			warn(`[DataService tests] DataStore unavailable: {err}`)
			warn("[DataService tests] Enable Game Settings → Security → API Services.")
			return false
		end
	end

	-- Get a real Player to drive the per-player flow with.
	print("[DataService tests] Waiting for a player…")
	local player = Players:GetPlayers()[1]
	if not player then
		player = Players.PlayerAdded:Wait()
	end
	print(`[DataService tests] Using player: {player.Name} (UserId {player.UserId})`)

	local testKey = "Player_" .. player.UserId

	-- Start clean: wipe any stale state persisted by prior test sessions. Without
	-- this, the "Template defaults applied" tests fail because applyTemplate
	-- only fills in nil keys — leftover values from the previous run's final
	-- Start (e.g. name="rt_default") would still be there and shadow the
	-- template defaults under test.
	print("[DataService tests] Wiping stale test state…")
	pcall(function()
		testStore:RemoveAsync(testKey)
	end)
	task.wait(0.3)

	local function reset()
		DataService:Stop()
		task.wait(0.3) -- buffer for atomic finalize / lock release
	end

	-- Get before Start returns nil and warns.
	do
		reset()
		local sd = DataService:Get(player)
		check("Get before Start returns nil", sd == nil)
	end

	-- Start is idempotent.
	do
		reset()
		local ok = pcall(function()
			DataService:Start({ coins = 0 }, TEST_DATASTORE)
			DataService:Start({ coins = 0 }, TEST_DATASTORE)
		end)
		check("Start is idempotent", ok)
	end

	-- After Start, Get yields until the SaveData is loaded.
	do
		reset()
		DataService:Start({ coins = 100, name = "Default" }, TEST_DATASTORE)
		local sd = DataService:Get(player)
		check("Get returns SaveData after Start", sd ~= nil)
		check("SaveData is loaded by the time Get returns", sd and sd:IsLoaded())
		check("SaveData holds the lock", sd and sd:HasLock())
	end

	-- Template defaults applied.
	do
		reset()
		DataService:Start({ coins = 100, name = "Default" }, TEST_DATASTORE)
		local sd = DataService:Get(player)
		check("Template defaults applied: coins", sd and sd:Get("coins") == 100)
		check("Template defaults applied: name", sd and sd:Get("name") == "Default")
	end

	-- UserId is auto-tagged for GDPR compliance.
	do
		reset()
		DataService:Start({ coins = 0 }, TEST_DATASTORE)
		local sd = DataService:Get(player)
		local ids = sd and sd:GetUserIds() or {}
		check("Player's UserId tagged on the SaveData", #ids == 1 and ids[1] == player.UserId)
	end

	-- Datastore key follows the Player_{UserId} convention.
	do
		reset()
		DataService:Start({ coins = 0 }, TEST_DATASTORE)
		local sd = DataService:Get(player)
		sd:Set("checkValue", "expectedAtKey")
		sd:ForceSave()
		reset()
		local ok, raw = pcall(function()
			return testStore:GetAsync(testKey)
		end)
		check("Saved under Player_{UserId} key", ok and typeof(raw) == "table")
		check("Saved value is wrapped with our format", ok and raw and raw.Version == 1)
		check(
			"Saved Data contains the field we set",
			ok and raw and raw.Data and raw.Data.checkValue == "expectedAtKey"
		)
	end

	-- Round-trip across Stop/Start.
	do
		reset()
		DataService:Start({ coins = 0 }, TEST_DATASTORE)
		local sd1 = DataService:Get(player)
		sd1:Set("coins", 555)
		sd1:ForceSave()

		reset()

		DataService:Start({ coins = 0 }, TEST_DATASTORE)
		local sd2 = DataService:Get(player)
		check("Round-trip: data persisted across Stop/Start", sd2 and sd2:Get("coins") == 555)
	end

	-- Stop tears down: subsequent Get returns nil.
	do
		reset()
		DataService:Start({ coins = 0 }, TEST_DATASTORE)
		DataService:Get(player)
		DataService:Stop()
		local sd = DataService:Get(player)
		check("Get after Stop returns nil", sd == nil)
	end

	-- GetIfLoaded
	do
		reset()
		check("GetIfLoaded before Start returns nil", DataService:GetIfLoaded(player) == nil)
	end

	do
		reset()
		DataService:Start({ coins = 0 }, TEST_DATASTORE)
		local fromGet = DataService:Get(player)
		local fromPeek = DataService:GetIfLoaded(player)
		check("GetIfLoaded returns SaveData once loaded", fromPeek ~= nil)
		check("GetIfLoaded returns the same instance as Get", fromPeek == fromGet)
	end

	do
		reset()
		DataService:Start({ coins = 0 }, TEST_DATASTORE)
		DataService:Get(player)
		DataService:Stop()
		check("GetIfLoaded after Stop returns nil", DataService:GetIfLoaded(player) == nil)
	end

	-- GetAll
	do
		reset()
		check("GetAll before Start returns empty list", #DataService:GetAll() == 0)
	end

	do
		reset()
		DataService:Start({ coins = 0 }, TEST_DATASTORE)
		DataService:Get(player)

		local all = DataService:GetAll()
		check("GetAll returns one entry for the loaded player", #all == 1)
		check("GetAll entry is the same SaveData as Get", all[1] == DataService:GetIfLoaded(player))
	end

	do
		reset()
		DataService:Start({ coins = 0 }, TEST_DATASTORE)
		DataService:Get(player)
		local seen = 0
		for _, _ in DataService:GetAll() do
			seen += 1
			DataService:Stop()
		end
		check("GetAll list survives mutation during iteration", seen == 1)
	end

	do
		reset()
		DataService:Start({ coins = 5 }, TEST_DATASTORE)
		DataService:Get(player)
		for _, sd in DataService:GetAll() do
			sd:Set("coins", 999)
		end
		check(
			"Mutations through GetAll affect live data",
			DataService:GetIfLoaded(player):Get("coins") == 999
		)
	end

	do
		reset()
		DataService:Start({ coins = 0 }, TEST_DATASTORE)
		DataService:Get(player)
		local a = DataService:GetAll()
		local b = DataService:GetAll()
		check("GetAll returns a fresh list each call", a ~= b)
	end

	-- Replication wiring: after Load, the player's State is published via ReplicatedState.
	do
		reset()
		DataService:Start({ coins = 100 }, TEST_DATASTORE)
		DataService:Get(player) -- yields until load + publish complete

		local root = ReplicatedStorage:FindFirstChild("_Remotes")
		local publishFolder = root and root:FindFirstChild("ReplicatedState:PlayerData:" .. player.UserId)
		check("After Load, player's State is published", publishFolder ~= nil)

		DataService:Stop()
		task.wait(0.3)
		check(
			"After Stop, the player's publish folder is torn down",
			publishFolder ~= nil and publishFolder.Parent == nil
		)
	end

	-- Final setup: leave running for client tests.
	-- Wipe the test key so the client sees clean template defaults rather than
	-- whatever the prior tests last persisted.
	reset()
	pcall(function()
		testStore:RemoveAsync(testKey)
	end)
	task.wait(0.3)

	DataService:Start({ coins = 100, name = "rt_default" }, TEST_DATASTORE)
	DataService:Get(player) -- ensure load + publish complete before signaling

	-- Trigger Remote: client uses this to ask the server to mutate its data.
	local mutateRemote = Remote.new(MUTATE_REMOTE_NAME)
	mutateRemote:Connect(function(p: Player, key: string, value: any)
		local sd = DataService:Get(p)
		if sd then
			sd:Set(key, value)
		end
	end)

	-- Ready marker created LAST so client can wait on it before subscribing.
	-- Until this Remote exists, the client knows the server might still be
	-- cycling through its server-only tests (which create and destroy publishes).
	local _ready = Remote.new(READY_REMOTE_NAME)
	local _ = _ready

	print(`[server] {passed} passed, {failed} failed`)
end

if RunService:IsClient() then
	-- Wait for server to finish its server-only tests and reach the stable
	-- "ready for client" state. Without this gate, the client could subscribe
	-- to a transient publish that gets torn down by the next server reset().
	print("[client] waiting for server ready signal…")
	RemoteClient.get(READY_REMOTE_NAME)
	print("[client] server ready, running DataClient tests")

	-- DataClient.get yields until snapshot arrives, returns a ReplicatedState Mirror.
	local data = DataService.DataClient.get()
	check("DataClient.get returns a mirror", data ~= nil)
	check("Mirror exposes template default: coins=100", data:Get("coins") == 100)
	check("Mirror exposes template default: name='rt_default'", data:Get("name") == "rt_default")

	-- Cached: same mirror twice.
	do
		local data2 = DataService.DataClient.get()
		check("DataClient.get is cached (same mirror twice)", data == data2)
	end

	-- Mirror is read-only on the client.
	do
		local ok = pcall(function()
			data:Set("client_attempted_write", "nope")
		end)
		check("Mirror :Set errors on the client", not ok)
		local ok2 = pcall(function()
			data:Increment("coins", 1)
		end)
		check("Mirror :Increment errors on the client", not ok2)
	end

	-- Round-trip: server sd:Set replicates to the client mirror.
	do
		local trigger = RemoteClient.get(MUTATE_REMOTE_NAME)
		local got
		data.Changed:Connect(function(k, v)
			if k == "rt_marker" then
				got = v
			end
		end)
		trigger:Fire("rt_marker", "client_can_see_this")
		waitFor(function()
			return got == "client_can_see_this"
		end)
		check(
			"Server-side sd:Set replicates to client mirror via Changed",
			got == "client_can_see_this",
			`got={tostring(got)}`
		)
		check(
			"Mirror :Get reflects the server-side mutation",
			data:Get("rt_marker") == "client_can_see_this"
		)
	end

	-- :Observe fires for replicated deltas (deltas go through State.Set on the mirror).
	do
		local trigger = RemoteClient.get(MUTATE_REMOTE_NAME)
		-- Use a counter; the initial fire passes nil (key doesn't exist yet) and
		-- table.insert(t, nil) is a no-op, so length-based checks would lie.
		local fireCount = 0
		local lastValue
		data:Observe("observed_field", function(v)
			fireCount += 1
			lastValue = v
		end)
		check("Observe fires once initially", fireCount == 1)
		trigger:Fire("observed_field", 42)
		waitFor(function()
			return fireCount >= 2
		end)
		check("Observe fires on replicated delta", fireCount == 2 and lastValue == 42, `fireCount={fireCount},last={tostring(lastValue)}`)
	end

	print(`[client] {passed} passed, {failed} failed`)
end

return true
