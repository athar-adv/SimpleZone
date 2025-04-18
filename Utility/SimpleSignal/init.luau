--!optimize 2
--!native
--!nonstrict

-- SIMPLESIGNAL UTILITY MODULE
-- GoodSignal but simple(r) :)
-- Author: athar_adv

--[[
	This module is distributed under a modified MIT license
	
	Copyright (c) 2025 SimpleSignal

	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, merge, publish, distribute, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.
]]

local Types = require(script.Types)

export type RBXScriptConnection = Types.RBXScriptConnection
export type RBXScriptSignal<T...=()> = Types.RBXScriptSignal<T...>

local threadPool = {}
local freeThreads = 0
local totalConnectionCount = 0

local SUSPENDED = "suspended"
local ThreadCleanInterval = 1

local function threadHandler(idx, fn, ...)
	local last = threadPool[freeThreads]
	threadPool[idx], threadPool[freeThreads] = last, nil

	freeThreads -= 1
	fn(...)
end

local function threadWorker(i)
	local running = coroutine.running()
	
	while true do
		threadHandler(i, coroutine.yield())
		freeThreads += 1
		i = freeThreads
		
		table.insert(threadPool, running)
	end
end

local function preallocateThreads(n: number)
	local original = freeThreads
	freeThreads += n
	for i = 1, n do
		local t = task.spawn(threadWorker, original + i)

		table.insert(threadPool, t)
	end
end

local function deallocateThreads(n: number)
	freeThreads -= n

	local i, l = n, #threadPool
	
	while i > 0 and i <= l do
		l = #threadPool
		if l == 0 then break end
		
		local curr = threadPool[i]
		if coroutine.status(curr) ~= SUSPENDED then continue end
		
		coroutine.close(curr)
		local last = threadPool[l]
		
		threadPool[i], threadPool[l] = last, nil
		i -= 1
	end
end

local function connection_disconnect(self: RBXScriptConnection)
	if not self.Connected then return end
	self.Connected = false

	local connections = self._connections
	local l = #connections
	if l == 1 then
		connections[l] = nil
		return
	end

	local pos = self._pos
	local last = connections[l]
	last._pos = pos

	connections[pos], connections[l] = last, nil
	totalConnectionCount -= 1
end

local function signal_destroy<T...>(self: RBXScriptSignal<T...>): ()
	deallocateThreads(self._allocatedThreads)
	self:DisconnectAll()
	
	table.clear(self)
end

local function signal_connect<T...>(self: RBXScriptSignal<T...>, fn: (T...) -> ()): RBXScriptConnection
	assert(type(fn) == "function", `Function expected, got {fn}`)

	local connections = self.Connections
	local index = #connections + 1
	local connection = {
		_fn = fn,
		_pos = index,
		_connections = connections,

		Connected = true,
		
		Disconnect = connection_disconnect
	}
	
	table.insert(connections, connection)
	totalConnectionCount += 1

	return connection
end

local function signal_once<T...>(self: RBXScriptSignal<T...>, fn: (T...) -> ()): RBXScriptConnection
	assert(type(fn) == "function", `Function expected, got {fn}`)

	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()

		fn(...)
	end)

	return connection
end

local function signal_disconnectAll<T...>(self: RBXScriptSignal<T...>): ()
	local connections = self.Connections
	local l = #connections
	
	for _, connection in connections do
		connection.Connected = false
	end
	table.clear(connections)
	totalConnectionCount -= l
end

local function signal_fire<T...>(self: RBXScriptSignal<T...>, ...: T...): ()
	local connections = self.Connections
	local l = #connections
	if l == 0 then return end
	
	if freeThreads < l then
		local diff = l - freeThreads
		preallocateThreads(diff)
		self._allocatedThreads += diff
	end
	
	for i = l, 1, -1 do
		local connection = connections[i]
		local last = threadPool[freeThreads]
		coroutine.resume(last, connection._fn, ...)
	end
end

local function signal_wait<T...>(self: RBXScriptSignal<T...>): T...
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
	return {
		Connections = {},
		_allocatedThreads = 0,
		
		Connect = signal_connect,
		Once = signal_once,
		Wait = signal_wait,
		
		Fire = signal_fire,
		DisconnectAll = signal_disconnectAll,
		Destroy = signal_destroy,
	}
end

local function setCleaningInterval(n: number)
	ThreadCleanInterval = n
end

-- GC loop to clean up the allocated threads based on total connection count
task.spawn(function()
	while true do
		task.wait(ThreadCleanInterval)
		local l = #threadPool
		if l <= totalConnectionCount then continue end
		
		local diff = l - totalConnectionCount
		
		deallocateThreads(diff)
	end
end)

return {
	new = signal_new,
	setCleaningInterval = setCleaningInterval
}
