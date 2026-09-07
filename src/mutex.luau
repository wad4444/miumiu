local types = require("./types")
local symbol = require("./symbol")

type MutexInternal = types.MutexInternal

local mutex_symbol = symbol.create_symbol("Mutex")

local function lock(self: MutexInternal)
	local values = self.internal_values
	if values.closed then
		error(values.closed, 0)
	end
	if not values.locked then
		values.locked = true
		return
	end

	table.insert(self.internal_waiters, coroutine.running())
	local granted, reason = coroutine.yield()
	if not granted then
		error(reason, 0)
	end
end

local function next_waiter(self: MutexInternal): thread?
	while true do
		local waiter = table.remove(self.internal_waiters, 1)
		if waiter == nil or coroutine.status(waiter) == "suspended" then
			return waiter
		end
	end
end

local function unlock(self: MutexInternal)
	local waiter = next_waiter(self)
	if waiter == nil then
		self.internal_values.locked = false
		return
	end
	task.spawn(waiter, true)
end

local function close(self: MutexInternal, reason: string)
	self.internal_values.closed = reason
	local waiters = table.clone(self.internal_waiters)
	table.clear(self.internal_waiters)
	for _, waiter in waiters do
		if coroutine.status(waiter) == "suspended" then
			task.spawn(waiter, false, reason)
		end
	end
end

local function with(self: MutexInternal, fn: () -> ())
	lock(self)
	local ok, err = pcall(fn)
	unlock(self)
	if not ok then
		error(err, 0)
	end
end

local function is_mutex(value: unknown): boolean
	return symbol.is_marked(value, mutex_symbol)
end

local template = {
	symbol = mutex_symbol,
	internal_values = {
		locked = false,
		closed = nil :: string?,
	},
	internal_waiters = {},
	lock = lock,
	unlock = unlock,
	close = close,
	with = with,
}

local meta = {
	__tostring = function(self: MutexInternal)
		return `Mutex({if self.internal_values.locked then "locked" else "free"})`
	end,
}

local function create_mutex(): MutexInternal
	local mutex = table.clone(template)
	mutex.internal_values = table.clone(template.internal_values)
	mutex.internal_waiters = {}
	setmetatable(mutex, meta)
	return mutex :: MutexInternal
end

return table.freeze({
	create_mutex = create_mutex,
	is_mutex = is_mutex,
})
