local HttpService = game:GetService("HttpService")
local State = {}
State.__index = State

local function newTrieNode()
    return {
        subtree = {},
        selfObservers = {},
        childrenObservers = {},
        descendantsObservers = {},
    }
end

local Observer = {}
Observer.__index = Observer

function Observer:Destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    local bucket = self._bucket
    for i, o in bucket do
        if o == self then
            table.remove(bucket, i)
            break
        end
    end
end

function State.new(data)
    local self = setmetatable({
        Data = data or {},
        ID = HttpService:GenerateGUID(false),
        _root = newTrieNode(),
    }, State)

    return self
end

function State:Get(key)
    local parts = string.split(key, "/")
    local node = self.Data
    for _, part in parts do
        if type(node) ~= "table" then
            return nil
        end
        node = node[part]
        if node == nil then
            return nil
        end
    end
    return node
end

function State:Set(key, value)
    local parts = string.split(key, "/")
    local node = self.Data
    for i = 1, #parts - 1 do
        local part = parts[i]
        local next = node[part]
        if type(next) ~= "table" then
            next = {}
            node[part] = next
        end
        node = next
    end
    node[parts[#parts]] = value
    self:_notify(key)
    return value
end

local function fireBucket(self, bucket, changedKey)
    for _, observer in bucket do
        if not observer._destroyed then
            task.spawn(observer._callback, self:Get(observer._key), changedKey)
        end
    end
end

local function fireSubtreeSelf(self, node, changedKey)
    fireBucket(self, node.selfObservers, changedKey)
    for _, child in node.subtree do
        fireSubtreeSelf(self, child, changedKey)
    end
end

function State:_notify(changedKey)
    local parts = string.split(changedKey, "/")
    local depth = #parts
    local node = self._root
    for i = 0, depth do
        fireBucket(self, node.selfObservers, changedKey)
        if i < depth then
            fireBucket(self, node.descendantsObservers, changedKey)
            if i == depth - 1 then
                fireBucket(self, node.childrenObservers, changedKey)
            end
            local nextNode = node.subtree[parts[i + 1]]
            if not nextNode then
                return
            end
            node = nextNode
        end
    end
    for _, child in node.subtree do
        fireSubtreeSelf(self, child, changedKey)
    end
end

function State:Observe(key, callback, scope)
    local parts = string.split(key, "/")
    local node = self._root
    for _, part in parts do
        local nextNode = node.subtree[part]
        if not nextNode then
            nextNode = newTrieNode()
            node.subtree[part] = nextNode
        end
        node = nextNode
    end
    local bucket
    if scope == "children" then
        bucket = node.childrenObservers
    elseif scope == "descendants" then
        bucket = node.descendantsObservers
    else
        bucket = node.selfObservers
    end
    local observer = setmetatable({
        _state = self,
        _key = key,
        _callback = callback,
        _scope = scope,
        _bucket = bucket,
        _destroyed = false,
    }, Observer)
    table.insert(bucket, observer)
    task.spawn(callback, self:Get(key), key)
    return observer
end

function State:Increment(key, value)
    local current = self:Get(key) or 0
    return self:Set(key, current + (value or 1))
end

return State