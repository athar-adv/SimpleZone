--!optimize 2
--!native
--!strict

-- SIMPLESIGNAL UTILITY MODULE
-- GoodSignal but simple
-- Author: athar_adv

--[[
	This module is distributed under a modified MIT license
	
	Copyright (c) 2025 athar_adv

	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, merge, publish, distribute, sublicense, and/or sell
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

export type RBXScriptConnection	= Types.RBXScriptConnection
export type RBXScriptSignal<T...=(any)> = Types.RBXScriptSignal<T...>

local SUSPENDED = "suspended"

local function call(c: RBXScriptConnection, fn, ...)
	local old = c._mainThread
	c._mainThread = nil
	fn(...)
	if c.Connected then
		c._mainThread = old
	end
end

local function mainThreadWorker(c: RBXScriptConnection)
	local fn = c._fn
	
	while true do
		call(c, fn, coroutine.yield())
		if c.Connected == false then
			-- Kill the thread
			return
		end
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
		self.Connected = false
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
	local connection = {
		_pos = index,
		_connections = connections,
		_fn = fn,

		Connected = true,

		Disconnect = connection_disconnect
	}
	-- Ensure the thread has a reference to the connection
	connection._mainThread = task.spawn(mainThreadWorker, connection)
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
		if t == nil then
			local new = task.spawn(mainThreadWorker, connection)
			connection._mainThread = new
			coroutine.resume(new, ...)
		else
			coroutine.resume(t, ...)
		end
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

		if coroutine.status(running) ~= "suspended" then
			return
		end

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
		Fire = signal_fire,
		Once = signal_once,
		Wait = signal_wait,
		DisconnectAll = signal_disconnectAll
	}
end

return {
	new = signal_new
}
