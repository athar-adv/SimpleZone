--!optimize 2

-- SIMPLESIGNAL UTILITY MODULE
-- GoodSignal but simple
-- Author: athar_adv

local Types 				= require(script.Types)

export type RBXScriptConnection 	= Types.RBXScriptConnection
export type RBXScriptSignal<T...> = Types.RBXScriptSignal<T...>

local freeRunnerThread 		= nil

local function acquireRunnerThreadAndCallEventHandler(fn, ...)
	local acquiredRunnerThread = freeRunnerThread
	freeRunnerThread = nil
	fn(...)
	freeRunnerThread = acquiredRunnerThread
end

local function runEventHandlerInFreeThread()
	while true do
		acquireRunnerThreadAndCallEventHandler(coroutine.yield())
	end
end

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	if not self.Connected then return end
	
	local connections = self._connections
	local pos = self._pos
	local l = #connections
	if l == 1 then
		connections[l] = nil
		self.Connected = false
		return
	end
	
	local val = connections[pos]
	local last = connections[l]

	connections[pos] = last
	connections[l] = nil
	last._pos = self._pos
	
	self.Connected = false
end

local Signal = {}
Signal.__index = Signal

function Signal:Destroy()
	self:DisconnectAll()
	
	setmetatable(self, nil)
	table.clear(self)
end

function Signal:Connect(fn)
	assert(type(fn) == "function", `Function expected, got {fn}`)
	
	local connections = self.Connections
	local index = #connections + 1
	local connection = setmetatable({
		_fn = fn,
		_pos = index,
		_connections = connections,

		Connected = true,
	}, Connection)
	
	table.insert(connections, connection)
	
	return connection
end

function Signal:Once(fn)
	assert(type(fn) == "function", `Function expected, got {fn}`)
	
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		
		fn(...)
	end)
	
	return connection
end

function Signal:DisconnectAll()
	for _, connection in self.Connections do
		connection.Connected = false
	end
	table.clear(self.Connections)
end

function Signal:Fire(...)
	if #self.Connections == 0 then return end
	
	for _, connection in self.Connections do
		if not freeRunnerThread then
			freeRunnerThread = task.spawn(runEventHandlerInFreeThread)
		end
		task.spawn(freeRunnerThread, connection._fn, ...)
	end
end

function Signal:Wait()
	local running = coroutine.running()
	local connection
	
	connection = self:Connect(function(...)
		connection:Disconnect()
		
		if coroutine.status(running) ~= "suspended" then
			return
		end
		
		task.spawn(running, ...)
	end)
	
	return coroutine.yield()
end

-- Create a new <code>RBXScriptSignal</code> object.
local function signal_new<T...>(): RBXScriptSignal<T...>
	return setmetatable({
		Connections = {},
	}, Signal)
end

return {
	new = signal_new
}
