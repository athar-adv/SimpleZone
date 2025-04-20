--!optimize 2
--!native
--!strict

--[[ SimpleSignal ]]

-- Author: athar_adv

local Types = require(script.Types)

export type RBXScriptConnection	= Types.RBXScriptConnection
export type RBXScriptSignal<T...=(any)> = Types.RBXScriptSignal<T...>

local SUSPENDED = "suspended"
-- ConnectParallel will error if not called from an Actor context
local IS_PARALLEL_CONTEXT = pcall(function()
	local c = game.Destroying:ConnectParallel(function()end)
	c:Disconnect()
end)

local function call(c: RBXScriptConnection, fn, ...)
	local old = c._mainThread
	c._mainThread = nil
	fn(...)
	if c.Connected then
		c._mainThread = old
	end
end

local function callParallel(c: RBXScriptConnection, fn, ...)
	local old = c._mainThread
	c._mainThread = nil
	task.desynchronize()
	fn(...)
	task.synchronize()
	if c.Connected then
		c._mainThread = old
	end
end

local function mainThreadWorker(c: RBXScriptConnection, a, ...)
	local fn = c._fn
	local callFunction = (c._isParallel and callParallel or call) :: (...any) -> ()
	-- Initial call if arguments are provided (so coroutine.resume doesn't have to be called twice)
	if a then
		callFunction(c, fn, a, ...)
	end
	
	while c.Connected do
		callFunction(c, fn, coroutine.yield())
	end
end

local function connection_disconnect(self: RBXScriptConnection): ()
	if not self.Connected then return end
	self.Connected = false

	local t = self._mainThread
	if t then
		coroutine.close(t)
	end
	self._mainThread = nil

	local connections = self._connections
	local l = #connections
	local pos = self._pos

	if l == pos then
		connections[l] = nil
		return
	end
	local last = connections[l]
	last._pos = pos

	connections[pos], connections[l] = last, nil
end

local function signal_destroy<T...>(self: RBXScriptSignal<T...>): ()
	self:DisconnectAll()
	table.clear(self)
end

local function signal_connect<T...>(self: RBXScriptSignal<T...>, fn: (T...) -> ()): RBXScriptConnection
	assert(type(fn) == "function", `Function expected, got {fn}`)
	local connections = self.Connections
	local index = #connections + 1
	
	local connection: RBXScriptConnection = {
		_pos = index,
		_connections = connections,
		_fn = fn,
		_isParallel = false,
		
		Connected = true,
		Disconnect = connection_disconnect
	}
	-- Ensure the thread has a reference to the connection
	local t = coroutine.create(mainThreadWorker)
	coroutine.resume(t, connection)
	
	connection._mainThread = t
	table.insert(connections, connection)
	
	return connection
end
-- Essentially the same as connect, just setting the isParallel flag and asserting if inside an Actor context
local function signal_connectParallel<T...>(self: RBXScriptSignal<T...>, fn: (T...) -> ()): RBXScriptConnection
	assert(type(fn) == "function", `Function expected, got {fn}`)
	assert(IS_PARALLEL_CONTEXT, "Scripts that connect in parallel must be rooted under an Actor.")
	local connections = self.Connections
	local index = #connections + 1

	local connection: RBXScriptConnection = {
		_pos = index,
		_connections = connections,
		_fn = fn,
		_isParallel = true,

		Connected = true,
		Disconnect = connection_disconnect
	}
	local t = coroutine.create(mainThreadWorker)
	coroutine.resume(t, connection)
	
	connection._mainThread = t
	table.insert(connections, connection)
	
	return connection
end

local function signal_disconnectAll<T...>(self: RBXScriptSignal<T...>): ()
	local connections = self.Connections
	local l = #connections
	
	for _, connection in connections do
		connection.Connected = false
		local t = connection._mainThread
		if not t then continue end
		
		coroutine.close(t)
		connection._mainThread = nil
	end
	table.clear(connections)
end

local function signal_fire<T...>(self: RBXScriptSignal<T...>, ...: T...): ()
	local connections = self.Connections
	local l = #connections
	if l == 0 then return end

	for i = l, 1, -1 do
		local connection = connections[i]
		local t = connection._mainThread :: thread
		-- If the main thread is done being used, it can simply be reused (fast path)
		if t ~= nil then
			local success, err = coroutine.resume(t, ...)
			assert(success, err)
			continue
		end
		-- If the main thread is still being used (aka yielding), 
		-- create a new one and set it as the new main thread (slow path)
		local new = coroutine.create(mainThreadWorker)
		local success, err = coroutine.resume(new, connection, ...)
		assert(success, err)

		connection._mainThread = new
	end
end

local function signal_once<T...>(self: RBXScriptSignal<T...>, fn): RBXScriptConnection
	assert(type(fn) == "function", `Function expected, got {fn}`)
	
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end)

	return connection
end

local function signal_wait<T...>(self: RBXScriptSignal<T...>): T...
	local running = coroutine.running()
	
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		coroutine.resume(running, ...)
	end)

	return coroutine.yield()
end

-- Create a new <code>RBXScriptSignal</code> object.
local function signal_new<T...>(): RBXScriptSignal<T...>
	return {
		Connections = {},

		Destroy = signal_destroy,
		Connect = signal_connect,
		ConnectParallel = signal_connectParallel,
		
		Fire = signal_fire,
		Once = signal_once,
		Wait = signal_wait,
		DisconnectAll = signal_disconnectAll
	}
end

return {
	new = signal_new
}
