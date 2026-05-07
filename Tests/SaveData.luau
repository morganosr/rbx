local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SaveData = require(ReplicatedStorage.Packages.SaveData)

local DATASTORE_NAME = "SaveDataTest"
local testStore = DataStoreService:GetDataStore(DATASTORE_NAME)

-- Up-front sanity: surface API access disabled clearly.
do
	local ok, err = pcall(function()
		testStore:GetAsync("__ping__")
	end)
	if not ok then
		warn(`[SaveData tests] DataStore unavailable: {err}`)
		warn("[SaveData tests] Enable Game Settings → Security → API Services.")
		return false
	end
end

local createdKeys: { string } = {}
local function uniqueKey(): string
	local k = "test-" .. HttpService:GenerateGUID(false)
	table.insert(createdKeys, k)
	return k
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

-- Construction / local-only behavior (no Load required)
do
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey())
	check("new(): State exists", sd.State ~= nil)
	check("new(): not loaded", not sd:IsLoaded())
	check("new(): no lock yet", not sd:HasLock())
	check("new(): not dirty", not sd:IsDirty())
	sd:Destroy()
end

do
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey(), { coins = 100, name = "Player" })
	check("Template populates top-level coins", sd:Get("coins") == 100)
	check("Template populates top-level name", sd:Get("name") == "Player")
	sd:Destroy()
end

-- Template is deep-cloned: post-construction mutation doesn't bleed into State.
do
	local template = { coins = 100, nested = { x = 1 } }
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey(), template)
	template.coins = 999
	template.nested.x = 999
	check("Template top-level deep-cloned", sd:Get("coins") == 100)
	check("Template nested deep-cloned", sd:Get("nested/x") == 1)
	sd:Destroy()
end

-- Set/Get via SaveData proxy.
do
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey())
	sd:Set("foo", 42)
	check("Proxy Set/Get round-trip", sd:Get("foo") == 42)
	sd:Destroy()
end

-- Dirty tracking covers both the proxy AND direct .State access.
do
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey())
	sd:Set("x", 1)
	check("Proxy Set marks dirty", sd:IsDirty())
	sd:Destroy()
end

do
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey())
	sd.State:Set("x", 1)
	check("Direct .State:Set marks dirty (monkeypatch works)", sd:IsDirty())
	sd:Destroy()
end

do
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey())
	sd:Increment("x", 5)
	check("Increment updates value", sd:Get("x") == 5)
	check("Increment marks dirty", sd:IsDirty())
	sd:Destroy()
end

-- Save/Load gating.
do
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey())
	local ok = sd:Save()
	check("Save fails before Load", not ok)
	sd:Destroy()
end

do
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey())
	local ok = sd:ForceSave(0)
	check("ForceSave fails before Load", not ok)
	sd:Destroy()
end

-- Load / lock acquisition on a fresh key.
do
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey(), { coins = 10 })
	local ok = sd:Load()
	check("Load on fresh key succeeds", ok)
	check("Load sets IsLoaded", sd:IsLoaded())
	check("Load acquires lock", sd:HasLock())
	check("Load preserves template defaults", sd:Get("coins") == 10)
	sd:Destroy()
end

-- Save clears dirty flag.
do
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey(), { coins = 0 })
	sd:Load()
	sd:Set("coins", 50)
	check("Set after Load marks dirty", sd:IsDirty())
	local ok = sd:Save()
	check("Save after Load succeeds", ok)
	check("Save clears dirty flag", not sd:IsDirty())
	sd:Destroy()
end

-- Save → Load round-trip preserves data, including nested values.
do
	local key = uniqueKey()
	local sd1 = SaveData.new(DATASTORE_NAME, key, { coins = 0 })
	sd1:Load()
	sd1:Set("coins", 999)
	sd1:Set("nested", { name = "sword", color = "red" })
	sd1:Save()
	sd1:Destroy()
	task.wait(0.3)

	local sd2 = SaveData.new(DATASTORE_NAME, key, { coins = 0 })
	sd2:Load()
	check("Round-trip: top-level value", sd2:Get("coins") == 999)
	check("Round-trip: nested string", sd2:Get("nested/name") == "sword")
	check("Round-trip: second nested string", sd2:Get("nested/color") == "red")
	sd2:Destroy()
end

-- Adding new template fields fills them in on subsequent loads without
-- overwriting existing data.
do
	local key = uniqueKey()
	local sd1 = SaveData.new(DATASTORE_NAME, key, { coins = 0 })
	sd1:Load()
	sd1:Set("coins", 100)
	sd1:Save()
	sd1:Destroy()
	task.wait(0.3)

	local sd2 = SaveData.new(DATASTORE_NAME, key, { coins = 0, gems = 50 })
	sd2:Load()
	check("Template merge: existing field preserved", sd2:Get("coins") == 100)
	check("Template merge: new field filled", sd2:Get("gems") == 50)
	sd2:Destroy()
end

-- Lock release (via Destroy's atomic finalize) lets a new instance load fast.
do
	local key = uniqueKey()
	local sd1 = SaveData.new(DATASTORE_NAME, key)
	sd1:Load()
	sd1:Destroy()
	task.wait(0.3)

	local sd2 = SaveData.new(DATASTORE_NAME, key)
	local startedAt = os.clock()
	local ok = sd2:Load()
	local elapsed = os.clock() - startedAt
	check("Released lock: new instance Load succeeds", ok)
	check("Released lock: Load is fast (no contention wait)", elapsed < 5, `elapsed {elapsed}s`)
	sd2:Destroy()
end

-- ForceSave: yields, returns true on success, durable across reloads.
do
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey(), { coins = 0 })
	sd:Load()
	sd:Set("coins", 1)
	local ok = sd:ForceSave()
	check("ForceSave returns true on success", ok)
	check("ForceSave clears dirty flag", not sd:IsDirty())
	sd:Destroy()
end

do
	local key = uniqueKey()
	local sd1 = SaveData.new(DATASTORE_NAME, key, { trades = 0 })
	sd1:Load()
	sd1:Set("trades", 7)
	sd1:ForceSave()
	sd1:Destroy()
	task.wait(0.3)

	local sd2 = SaveData.new(DATASTORE_NAME, key, { trades = 0 })
	sd2:Load()
	check("ForceSave is durable across reload", sd2:Get("trades") == 7)
	sd2:Destroy()
end

-- Auto-save flushes dirty data within the configured interval.
do
	local key = uniqueKey()
	local sd = SaveData.new(DATASTORE_NAME, key, { coins = 0 })
	sd:StopAutoSave()
	sd:StartAutoSave(2)
	sd:Load()
	sd:Set("coins", 777)

	local waited = 0
	while sd:IsDirty() and waited < 10 do
		task.wait(0.5)
		waited += 0.5
	end
	check("Auto-save clears dirty within interval", not sd:IsDirty(), `waited {waited}s`)
	sd:Destroy()
	task.wait(0.3)

	local sd2 = SaveData.new(DATASTORE_NAME, key, { coins = 0 })
	sd2:Load()
	check("Auto-save persisted data", sd2:Get("coins") == 777)
	sd2:Destroy()
end

-- UserId tagging.
do
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey())
	sd:AddUserId(123)
	sd:AddUserId(456)
	sd:AddUserId(123) -- duplicate: should not insert
	local ids = sd:GetUserIds()
	check("AddUserId: stores IDs", #ids == 2)
	check("AddUserId: dedupes", ids[1] == 123 and ids[2] == 456)
	sd:Destroy()
end

do
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey(), nil, { 100, 200 })
	local ids = sd:GetUserIds()
	check("Constructor userIds populates list", #ids == 2 and ids[1] == 100)
	sd:Destroy()
end

do
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey())
	sd:AddUserId(42)
	local ids = sd:GetUserIds()
	table.insert(ids, 999)
	check("GetUserIds returns a defensive copy", #sd:GetUserIds() == 1)
	sd:Destroy()
end

-- Lifecycle.
do
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey())
	sd:Load()
	check("HasLock true while alive", sd:HasLock())
	sd:Destroy()
	check("HasLock false after Destroy", not sd:HasLock())
end

do
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey())
	sd:Load()
	sd:Destroy()
	local ok = sd:Save()
	check("Save fails after Destroy", not ok)
end

do
	local sd = SaveData.new(DATASTORE_NAME, uniqueKey())
	sd:Load()
	sd:Destroy()
	sd:Destroy()
	check("Destroy is idempotent", not sd:HasLock())
end

-- Cleanup test keys so we don't pile up garbage in the datastore.
print(`\nCleaning up {#createdKeys} test keys…`)
for _, k in createdKeys do
	pcall(function()
		testStore:RemoveAsync(k)
	end)
end

print(`\n--- {passed} passed, {failed} failed ---`)

return true
