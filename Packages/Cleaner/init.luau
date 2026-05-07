local Cleaner = {}
Cleaner.__index = Cleaner

export type Cleanable =
	Instance
	| RBXScriptConnection
	| thread
	| () -> ()
	| { Destroy: (any) -> ()? }
	| { destroy: (any) -> ()? }
	| { Disconnect: (any) -> ()? }
	| { Cancel: (any) -> ()? }

local MARKER = {} :: any

local function processObject(object: any)
	if typeof(object) == "RBXScriptConnection" then
		object:Disconnect()
	elseif typeof(object) == "function" then
		object()
	elseif typeof(object) == "Instance" then
		object:Destroy()
	elseif typeof(object) == "thread" then
		task.cancel(object)
	elseif typeof(object) == "table" then
		local kind = object[MARKER]
		if kind == "method" then
			local target = object.target
			;(target :: any)[object.method](target, table.unpack(object.args, 1, object.n))
		elseif kind == "keyed" then
			processObject(object.object)
		elseif type(object.Destroy) == "function" then
			object:Destroy()
		elseif type(object.destroy) == "function" then
			object:destroy()
		elseif type(object.Disconnect) == "function" then
			object:Disconnect()
		elseif type(object.Cancel) == "function" then
			object:Cancel()
		else
			warn("[Cleaner] table has no recognized cleanup method (Destroy/destroy/Disconnect/Cancel)")
		end
	end
end

local function safeProcess(object: any)
	local ok, err = xpcall(processObject, debug.traceback, object)
	if not ok then
		warn("[Cleaner] cleanup error:", err)
	end
end

local function entryMatches(entry: any, object: any): boolean
	if entry == object then
		return true
	end
	if typeof(entry) == "table" then
		local kind = entry[MARKER]
		if kind == "method" and entry.target == object then
			return true
		elseif kind == "keyed" and entry.object == object then
			return true
		end
	end
	return false
end

function Cleaner.new(...)
	local self = setmetatable({
		_bucket = {},
	}, Cleaner)
	if select("#", ...) > 0 then
		self:Add(...)
	end
	return self
end

function Cleaner:Add<T>(object: T, ...: any): T
	if self._destroyed then
		error("Cannot add to a destroyed Cleaner", 2)
	end
	table.insert(self._bucket, object)
	for i = 1, select("#", ...) do
		table.insert(self._bucket, (select(i, ...)))
	end
	return object
end

function Cleaner:AddMethod<T>(object: T, method: string, ...: any): T
	if self._destroyed then
		error("Cannot add to a destroyed Cleaner", 2)
	end
	local args = table.pack(...)
	table.insert(self._bucket, {
		[MARKER] = "method",
		target = object,
		method = method,
		args = args,
		n = args.n,
	})
	return object
end

function Cleaner:AddKeyed<T>(key: any, object: T): T
	if self._destroyed then
		error("Cannot add to a destroyed Cleaner", 2)
	end
	for i, entry in self._bucket do
		if typeof(entry) == "table" and entry[MARKER] == "keyed" and entry.key == key then
			table.remove(self._bucket, i)
			safeProcess(entry)
			break
		end
	end
	table.insert(self._bucket, {
		[MARKER] = "keyed",
		key = key,
		object = object,
	})
	return object
end

function Cleaner:Extend()
	return self:Add(Cleaner.new())
end

function Cleaner:LinkToInstance(instance: Instance): RBXScriptConnection
	return self:Add(instance.Destroying:Connect(function()
		self:Destroy()
	end))
end

function Cleaner:Clean(async: boolean?)
	local bucket = self._bucket
	self._bucket = {}

	if async then
		for i = #bucket, 1, -1 do
			task.spawn(safeProcess, bucket[i])
		end
	else
		for i = #bucket, 1, -1 do
			safeProcess(bucket[i])
		end
	end
end

function Cleaner:CleanObject(object, async: boolean?)
	local found
	for i, entry in self._bucket do
		if entryMatches(entry, object) then
			found = i
			break
		end
	end
	if not found then
		return
	end
	local entry = self._bucket[found]
	table.remove(self._bucket, found)
	if async then
		task.spawn(safeProcess, entry)
	else
		safeProcess(entry)
	end
end

function Cleaner:CleanKey(key: any, async: boolean?)
	for i, entry in self._bucket do
		if typeof(entry) == "table" and entry[MARKER] == "keyed" and entry.key == key then
			table.remove(self._bucket, i)
			if async then
				task.spawn(safeProcess, entry)
			else
				safeProcess(entry)
			end
			return
		end
	end
end

function Cleaner:RemoveObject(object)
	for i, entry in self._bucket do
		if entryMatches(entry, object) then
			table.remove(self._bucket, i)
			return
		end
	end
end

function Cleaner:RemoveKey(key: any)
	for i, entry in self._bucket do
		if typeof(entry) == "table" and entry[MARKER] == "keyed" and entry.key == key then
			table.remove(self._bucket, i)
			return
		end
	end
end

function Cleaner:IsDestroyed(): boolean
	return self._destroyed == true
end

function Cleaner:Destroy(async: boolean?)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self:Clean(async)
end

export type Cleaner = typeof(Cleaner.new())

return Cleaner
