export type RBXScriptConnection = {
	Disconnect: typeof(
		--[[
			Disconnects the connection from the event.
		]]
		function(self: RBXScriptConnection)end
	),
	Connected: boolean,
}

-- Function types are made using typeof() to preserve doc comments
export type RBXScriptSignal<T...> = {
	Destroy: typeof(
		--[[
		Destroys this event object.
		]]
		function(self: RBXScriptSignal<T...>): () end
	),
	Connect: typeof(
		--[[
		Connects the given function to the event and returns an <code>RBXScriptConnection</code> that represents it.
		
		<strong>func</strong>: The function to connect to the event.
		]]
		function(self: RBXScriptSignal<T...>, func: (T...) -> ()): RBXScriptConnection end
	),
	Once: typeof(
		--[[
		Connects the given function to the event (for a single invocation) and returns an <code>RBXScriptConnection</code> that represents it.
		
		<strong>func</strong>: The function to connect to the event.
		]]
		function(self: RBXScriptSignal<T...>, func: (T...) -> ()): RBXScriptConnection end
	),
	Fire: typeof(
		--[[
		Upon firing, all <code>RBXScriptConnections</code> connected to this event will be called.
		
		<strong>T...</strong>: The arguments to pass to connected functions.
		]]
		function(self: RBXScriptSignal<T...>, ...:T...): () end
	),
	DisconnectAll: typeof(
		--[[
		Disconnects all <code>RBXScriptConnections</code> currently connected to the event.
		]]
		function(self: RBXScriptSignal<T...>): () end
	),
	Wait: typeof(
		--[[
		Yields the current thread until the signal fires
		and returns the arguments provided by the signal.
		]]
		function(self: RBXScriptSignal<T...>): T... end
	),
	
	Connections: {RBXScriptConnection}
}

return nil
