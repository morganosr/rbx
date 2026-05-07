local ReplicatedStorage = game:GetService("ReplicatedStorage")
local State = require(ReplicatedStorage.Packages.State)

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

-- Get / Set basics
do
    local s = State.new()
    check("Get on empty returns nil", s:Get("missing") == nil)
    s:Set("a", 1)
    check("Set/Get top-level", s:Get("a") == 1)
    s:Set("a/b/c", 42)
    check("Nested Set/Get", s:Get("a/b/c") == 42)
    check("Intermediate is a table", typeof(s:Get("a/b")) == "table")
    check("Get missing nested returns nil", s:Get("x/y/z") == nil)
    check("Set returns value", s:Set("k", "v") == "v")
end

-- Constructor with initial data
do
    local s = State.new({ Coins = 10, Inventory = { Sword = true } })
    check("Initial data top-level", s:Get("Coins") == 10)
    check("Initial data nested", s:Get("Inventory/Sword") == true)
end

-- Increment
do
    local s = State.new()
    s:Increment("counter")
    check("Increment from nil = 1", s:Get("counter") == 1)
    s:Increment("counter", 5)
    check("Increment by 5 = 6", s:Get("counter") == 6)
    check("Increment returns new value", s:Increment("counter", 4) == 10)
    s:Increment("nested/score", 7)
    check("Increment creates nested path", s:Get("nested/score") == 7)
end

-- Observe: initial fire
do
    local s = State.new({ hp = 100 })
    local fires = {}
    s:Observe("hp", function(v, k)
        table.insert(fires, { v = v, k = k })
    end)
    check("Observer fires once on creation", #fires == 1)
    check("Initial fire passes current value", fires[1].v == 100)
    check("Initial fire passes observed key", fires[1].k == "hp")
end

-- Observe: default scope (exact + ancestor + descendant changes)
do
    local s = State.new()
    s:Set("player/stats/hp", 100)
    local fires = {}
    s:Observe("player/stats/hp", function(_, k)
        table.insert(fires, k)
    end)
    s:Set("player/stats/hp", 50)
    s:Set("player", { stats = { hp = 25 } })
    s:Set("player/stats", { hp = 10 })
    s:Set("unrelated", true)
    check("Default scope fires on initial + exact + 2 ancestors", #fires == 4)
    check("Default scope ignores unrelated paths", fires[#fires] == "player/stats")
end

-- Observe: descendants scope
do
    local s = State.new()
    local fires = {}
    s:Observe("inv", function(_, k)
        table.insert(fires, k)
    end, "descendants")
    s:Set("inv/coins", 5)
    s:Set("inv/items/sword", 1)
    s:Set("inv", { coins = 9 })
    s:Set("other/thing", true)
    check("descendants scope: initial + 2 descendants", #fires == 3)
    check("descendants scope ignores exact match", fires[#fires] == "inv/items/sword")
end

-- Observe: children scope
do
    local s = State.new()
    local fires = {}
    s:Observe("inv", function(_, k)
        table.insert(fires, k)
    end, "children")
    s:Set("inv/coins", 5)
    s:Set("inv/items/sword", 1)
    s:Set("inv", { coins = 0 })
    check("children scope: initial + 1 direct child", #fires == 2)
    check("children scope captures direct child key", fires[2] == "inv/coins")
end

-- Observer:Destroy
do
    local s = State.new({ x = 0 })
    local count = 0
    local obs = s:Observe("x", function()
        count += 1
    end)
    obs:Destroy()
    s:Set("x", 99)
    check("Destroy prevents further fires", count == 1)
    obs:Destroy()
    check("Destroy is idempotent", count == 1)
end

-- Multiple observers on same key
do
    local s = State.new()
    local a, b = 0, 0
    s:Observe("k", function()
        a += 1
    end)
    s:Observe("k", function()
        b += 1
    end)
    s:Set("k", 1)
    check("Multiple observers on same key both fire", a == 2 and b == 2)
end

-- Subtree fan-out: replacing a parent fires deep default-scope observers
do
    local s = State.new()
    local fires = 0
    s:Observe("a/b/c/d", function()
        fires += 1
    end)
    s:Set("a", { b = { c = { d = 99 } } })
    check("Wholesale parent set fires deep observer", fires == 2)
end

-- Increment goes through Set, so it fires observers
do
    local s = State.new({ score = 0 })
    local last
    s:Observe("score", function(v)
        last = v
    end)
    s:Increment("score", 3)
    check("Increment notifies observers", last == 3)
end

print(`\n--- {passed} passed, {failed} failed ---`)
