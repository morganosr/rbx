local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(ReplicatedStorage.Packages.DataService)

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

-- Get a real Player to drive the per-player flow with. In Play Solo there
-- should already be one or one will join shortly.
print("[DataService tests] Waiting for a player…")
local player = Players:GetPlayers()[1]
if not player then
	player = Players.PlayerAdded:Wait()
end
print(`[DataService tests] Using player: {player.Name} (UserId {player.UserId})`)

local testKey = "Player_" .. player.UserId

-- Make sure we start each test from a clean slate.
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

-- Start is idempotent — calling twice doesn't error.
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

-- Datastore key follows the Player_{UserId} convention. Verify by checking
-- the value lands at the expected key after a save.
do
	reset()
	DataService:Start({ coins = 0 }, TEST_DATASTORE)
	local sd = DataService:Get(player)
	sd:Set("checkValue", "expectedAtKey")
	sd:ForceSave()
	-- Stop to release the lock before reading the raw store
	reset()
	local ok, raw = pcall(function()
		return testStore:GetAsync(testKey)
	end)
	check("Saved under Player_{UserId} key", ok and typeof(raw) == "table")
	-- Inner shape is wrapped (Version=1, Data, Session) — peek at Data.
	check("Saved value is wrapped with our format", ok and raw and raw.Version == 1)
	check(
		"Saved Data contains the field we set",
		ok and raw and raw.Data and raw.Data.checkValue == "expectedAtKey"
	)
end

-- Round-trip across Stop/Start: data set in one session is visible in the next.
do
	reset()
	DataService:Start({ coins = 0 }, TEST_DATASTORE)
	local sd1 = DataService:Get(player)
	sd1:Set("coins", 555)
	sd1:ForceSave()

	reset() -- destroys SaveData (atomic finalize releases lock)

	DataService:Start({ coins = 0 }, TEST_DATASTORE)
	local sd2 = DataService:Get(player)
	check("Round-trip: data persisted across Stop/Start", sd2 and sd2:Get("coins") == 555)
end

-- Stop tears down: subsequent Get returns nil.
do
	reset()
	DataService:Start({ coins = 0 }, TEST_DATASTORE)
	DataService:Get(player) -- ensure loaded
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
	-- After load completes, GetIfLoaded returns the same SaveData as Get.
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
	DataService:Get(player) -- wait for load

	local all = DataService:GetAll()
	check("GetAll returns one entry for the loaded player", #all == 1)
	check("GetAll entry is the same SaveData as Get", all[1] == DataService:GetIfLoaded(player))
end

do
	reset()
	DataService:Start({ coins = 0 }, TEST_DATASTORE)
	DataService:Get(player)
	-- The returned list is a snapshot: Stopping mid-iteration must not break it.
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
	-- Mutations to a SaveData from GetAll's list should affect the real data.
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
	-- Each call returns a fresh list.
	local a = DataService:GetAll()
	local b = DataService:GetAll()
	check("GetAll returns a fresh list each call", a ~= b)
end

-- Cleanup
print("[DataService tests] Cleaning up…")
DataService:Stop()
task.wait(0.3)
pcall(function()
	testStore:RemoveAsync(testKey)
end)

print(`\n--- {passed} passed, {failed} failed ---`)

return true
