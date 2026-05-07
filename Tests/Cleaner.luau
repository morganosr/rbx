local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Cleaner = require(ReplicatedStorage.Packages.Cleaner)

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

-- Function cleanups
do
	local c = Cleaner.new()
	local fired = false
	c:Add(function()
		fired = true
	end)
	c:Clean()
	check("Function cleanup runs the function", fired)
end

-- Add returns the first argument (preserving its type)
do
	local c = Cleaner.new()
	local fn = function() end
	check("Add returns first arg", c:Add(fn) == fn)
end

-- Variadic Add
do
	local c = Cleaner.new()
	local count = 0
	c:Add(function()
		count += 1
	end, function()
		count += 1
	end, function()
		count += 1
	end)
	c:Clean()
	check("Variadic Add cleans every passed item", count == 3)
end

-- new(...) accepts initial items
do
	local count = 0
	local c = Cleaner.new(function()
		count += 1
	end, function()
		count += 1
	end)
	c:Clean()
	check("Cleaner.new(...) cleans initial items", count == 2)
end

-- LIFO ordering: last added is cleaned first
do
	local c = Cleaner.new()
	local order = {}
	c:Add(function()
		table.insert(order, "first")
	end)
	c:Add(function()
		table.insert(order, "second")
	end)
	c:Add(function()
		table.insert(order, "third")
	end)
	c:Clean()
	check("LIFO: third runs first", order[1] == "third")
	check("LIFO: first runs last", order[3] == "first")
end

-- RBXScriptConnection cleanup
do
	local c = Cleaner.new()
	local sig = Instance.new("BindableEvent")
	local fired = 0
	c:Add(sig.Event:Connect(function()
		fired += 1
	end))
	c:Clean()
	sig:Fire()
	task.wait() -- let the deferred fire pass through (it shouldn't fire — connection's gone)
	check("Connection cleanup disconnects", fired == 0)
	sig:Destroy()
end

-- Instance cleanup
do
	local c = Cleaner.new()
	local part = Instance.new("Part")
	part.Parent = workspace
	c:Add(part)
	c:Clean()
	check("Instance cleanup destroys", part.Parent == nil)
end

-- Thread cleanup
do
	local c = Cleaner.new()
	local thread = task.spawn(function()
		while true do
			task.wait(1)
		end
	end)
	c:Add(thread)
	c:Clean()
	check("Thread cleanup cancels", coroutine.status(thread) == "dead")
end

-- Table dispatch: Destroy / destroy / Disconnect / Cancel
do
	local c = Cleaner.new()
	local destroyed = false
	c:Add({
		Destroy = function()
			destroyed = true
		end,
	})
	c:Clean()
	check("Table with :Destroy()", destroyed)
end

do
	local c = Cleaner.new()
	local destroyed = false
	c:Add({
		destroy = function()
			destroyed = true
		end,
	})
	c:Clean()
	check("Table with lowercase :destroy()", destroyed)
end

do
	local c = Cleaner.new()
	local disconnected = false
	c:Add({
		Disconnect = function()
			disconnected = true
		end,
	})
	c:Clean()
	check("Table with :Disconnect()", disconnected)
end

do
	local c = Cleaner.new()
	local cancelled = false
	c:Add({
		Cancel = function()
			cancelled = true
		end,
	})
	c:Clean()
	check("Table with :Cancel()", cancelled)
end

-- Method dispatch priority: Destroy > destroy > Disconnect > Cancel
do
	local c = Cleaner.new()
	local order = {}
	c:Add({
		Destroy = function()
			table.insert(order, "Destroy")
		end,
		Disconnect = function()
			table.insert(order, "Disconnect")
		end,
	})
	c:Clean()
	check("Destroy preferred over Disconnect", order[1] == "Destroy" and #order == 1)
end

-- AddMethod
do
	local c = Cleaner.new()
	local called = false
	local args
	local obj = {
		Stop = function(self, a, b)
			called = true
			args = { a, b }
		end,
	}
	c:AddMethod(obj, "Stop", "x", "y")
	c:Clean()
	check("AddMethod calls named method", called)
	check("AddMethod passes args", args[1] == "x" and args[2] == "y")
end

do
	local c = Cleaner.new()
	local called = false
	local obj = {
		Stop = function()
			called = true
		end,
	}
	c:AddMethod(obj, "Stop")
	c:RemoveObject(obj)
	c:Clean()
	check("RemoveObject finds AddMethod entries by target", not called)
end

-- AddKeyed: same key replaces and immediately cleans the previous entry
do
	local c = Cleaner.new()
	local oldCleaned, newCleaned = false, false
	c:AddKeyed("loop", function()
		oldCleaned = true
	end)
	c:AddKeyed("loop", function()
		newCleaned = true
	end)
	check("AddKeyed: replacement cleans old", oldCleaned)
	check("AddKeyed: new entry not yet cleaned", not newCleaned)
	c:Clean()
	check("AddKeyed: new entry cleaned on Clean", newCleaned)
end

do
	local c = Cleaner.new()
	local a, b = false, false
	c:AddKeyed("a", function()
		a = true
	end)
	c:AddKeyed("b", function()
		b = true
	end)
	c:Clean()
	check("AddKeyed: independent keys both cleaned", a and b)
end

-- CleanKey / RemoveKey
do
	local c = Cleaner.new()
	local cleaned = false
	c:AddKeyed("k", function()
		cleaned = true
	end)
	c:CleanKey("k")
	check("CleanKey processes the keyed entry", cleaned)
end

do
	local c = Cleaner.new()
	local cleaned = false
	c:AddKeyed("k", function()
		cleaned = true
	end)
	c:RemoveKey("k")
	c:Clean()
	check("RemoveKey: untracks without cleaning", not cleaned)
end

-- Extend
do
	local parent = Cleaner.new()
	local child = parent:Extend()
	local childCleaned = false
	child:Add(function()
		childCleaned = true
	end)
	parent:Clean()
	check("Extend: cleaning parent cleans child", childCleaned)
	check("Extend: child is destroyed", child:IsDestroyed())
end

-- LinkToInstance
do
	local c = Cleaner.new()
	local cleaned = false
	c:Add(function()
		cleaned = true
	end)
	local inst = Instance.new("Folder")
	c:LinkToInstance(inst)
	inst:Destroy()
	task.wait() -- let Destroying signal flow through (it may be deferred)
	check("LinkToInstance: cleaner destroyed when instance dies", c:IsDestroyed())
	check("LinkToInstance: bucket cleanups ran", cleaned)
end

-- Error isolation: a thrown cleanup doesn't strand the rest
do
	local c = Cleaner.new()
	local secondRan = false
	c:Add(function()
		secondRan = true
	end)
	c:Add(function()
		error("intentional")
	end)
	c:Clean() -- LIFO: error fn runs first, second fn should still run
	check("Error in cleanup doesn't stop later ones", secondRan)
end

-- CleanObject
do
	local c = Cleaner.new()
	local targetCleaned = false
	local target = function()
		targetCleaned = true
	end
	c:Add(function() end)
	c:Add(target)
	c:Add(function() end)
	c:CleanObject(target)
	check("CleanObject processes the target", targetCleaned)
	-- Now Clean shouldn't re-process target
	targetCleaned = false
	c:Clean()
	check("CleanObject removed from bucket", not targetCleaned)
end

do
	local c = Cleaner.new()
	local cleaned = false
	c:CleanObject(function()
		cleaned = true
	end)
	check("CleanObject: no-op if not tracked", not cleaned)
end

-- RemoveObject
do
	local c = Cleaner.new()
	local cleaned = false
	local fn = function()
		cleaned = true
	end
	c:Add(fn)
	c:RemoveObject(fn)
	c:Clean()
	check("RemoveObject: doesn't process the removed object", not cleaned)
end

-- IsDestroyed / Destroy idempotence / Add-after-Destroy errors
do
	local c = Cleaner.new()
	check("IsDestroyed: false initially", not c:IsDestroyed())
	c:Destroy()
	check("IsDestroyed: true after Destroy", c:IsDestroyed())
end

do
	local c = Cleaner.new()
	c:Destroy()
	c:Destroy()
	check("Destroy is idempotent", c:IsDestroyed())
end

do
	local c = Cleaner.new()
	c:Destroy()
	local ok = pcall(function()
		c:Add(function() end)
	end)
	check("Add after Destroy errors", not ok)
end

-- Destroy actually cleans the bucket (regression: earlier version forgot to)
do
	local c = Cleaner.new()
	local cleaned = false
	c:Add(function()
		cleaned = true
	end)
	c:Destroy()
	check("Destroy cleans the bucket", cleaned)
end

-- Async Clean still runs cleanups
do
	local c = Cleaner.new()
	local count = 0
	c:Add(function()
		count += 1
	end)
	c:Add(function()
		count += 1
	end)
	c:Clean(true) -- task.spawn each
	-- Spawned non-yielding fns finish synchronously before Clean returns.
	check("Async Clean still runs all cleanups", count == 2)
end

-- Bucket swap pattern: a cleanup that adds to the cleaner doesn't get cleaned
-- in the same pass (lands in the new bucket).
do
	local c = Cleaner.new()
	local secondRan = false
	c:Add(function()
		c:Add(function()
			secondRan = true
		end)
	end)
	c:Clean()
	check("Adds during Clean land in new bucket (not re-cleaned)", not secondRan)
	c:Clean() -- now clean the new bucket
	check("Newly added entry cleaned by next Clean", secondRan)
end

print(`\n--- {passed} passed, {failed} failed ---`)

return true
