--!strict
--[[
	Signal
	------
	Lightweight event object for decoupling systems inside a single context.

	Why not BindableEvent? Two reasons that matter here:
	  1. BindableEvent serialises its arguments, which deep-copies tables and
	     loses identity. Passing an aircraft state table through one would
	     allocate a copy every fire - unacceptable at 60 Hz.
	  2. BindableEvent handlers are deferred, so a fire this frame may not be
	     handled until next frame. Instrument updates need to be synchronous.

	This is the well-established "free thread" pattern: handlers run on reused
	coroutines so a yielding handler cannot block the firing code, and the
	common non-yielding case costs no thread creation at all.

	This is for INSIDE one context only. Server-to-client communication goes
	through Net.Remotes.
]]

-- =========================================================================
-- Reusable coroutine pool
-- =========================================================================

local freeThread: thread? = nil

-- Calls fn, then makes this thread available for the next handler.
-- The extra indirection exists so the thread stays alive across many calls
-- rather than being collected after one use.
local function acquireRunner(fn, ...)
	local acquired = freeThread
	freeThread = nil
	fn(...)
	-- fn returned without yielding, so this thread is reusable again.
	freeThread = acquired
end

local function runnerLoop()
	while true do
		acquireRunner(coroutine.yield())
	end
end

local function spawnHandler(fn, ...)
	if not freeThread then
		freeThread = coroutine.create(runnerLoop)
		-- Prime it up to the first yield so it is ready to receive work.
		coroutine.resume(freeThread :: thread)
	end
	local thread = freeThread :: thread
	task.spawn(thread, fn, ...)
end

-- =========================================================================
-- Connection
-- =========================================================================

local Connection = {}
Connection.__index = Connection

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

function Connection.new(signal, fn)
	return setmetatable({
		Connected = true,
		_signal = signal,
		_fn = fn,
		_next = nil,
	}, Connection)
end

--[[
	Removes this connection from its signal's linked list.

	The list is singly linked and stores the head on the signal, so removal is
	O(n) in the number of handlers. That is fine: signals here have a handful
	of listeners, and connecting/disconnecting is rare compared to firing,
	which is O(1) with no allocation.
]]
function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false

	local signal = self._signal
	if signal._head == self then
		signal._head = self._next
	else
		local prev = signal._head
		while prev and prev._next ~= self do
			prev = prev._next
		end
		if prev then
			prev._next = self._next
		end
	end

	self._signal = nil
	self._fn = nil
	self._next = nil
end

-- =========================================================================
-- Signal
-- =========================================================================

local Signal = {}
Signal.__index = Signal

export type Signal = {
	Connect: (self: Signal, fn: (...any) -> ()) -> Connection,
	Once: (self: Signal, fn: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	Wait: (self: Signal) -> ...any,
	DisconnectAll: (self: Signal) -> (),
	Destroy: (self: Signal) -> (),
}

function Signal.new(name: string?)
	return setmetatable({
		_head = nil,
		_name = name or "Signal",
	}, Signal)
end

function Signal:Connect(fn: (...any) -> ()): Connection
	local connection = Connection.new(self, fn)
	-- Prepend: O(1), and firing order is not something callers should rely on.
	connection._next = self._head
	self._head = connection
	return connection
end

-- Connect a handler that disconnects itself after the first fire.
function Signal:Once(fn: (...any) -> ()): Connection
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

--[[
	Fire every connected handler.

	_next is captured BEFORE the handler runs, so a handler that disconnects
	itself (or any other listener) during the fire cannot corrupt the walk.
]]
function Signal:Fire(...: any)
	local connection = self._head
	while connection do
		local nextConnection = connection._next
		if connection.Connected then
			spawnHandler(connection._fn, ...)
		end
		connection = nextConnection
	end
end

-- Yield the calling coroutine until the next fire, returning its arguments.
function Signal:Wait(): ...any
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:DisconnectAll()
	local connection = self._head
	while connection do
		local nextConnection = connection._next
		connection.Connected = false
		connection._signal = nil
		connection._fn = nil
		connection._next = nil
		connection = nextConnection
	end
	self._head = nil
end

function Signal:Destroy()
	self:DisconnectAll()
end

return Signal
