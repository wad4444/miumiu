local types = require("./types")
type MutexInternal = types.MutexInternal
type MutexPhase = types.MutexPhase

local function lock(self: MutexInternal)
	local values = self.internal_values
	local phase = values.phase
	if phase.kind == "closed" then
		error(phase.reason, 0)
	end
	if phase.kind == "free" then
		values.phase = { kind = "locked" }
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
		if self.internal_values.phase.kind == "locked" then
			self.internal_values.phase = { kind = "free" }
		end
		return
	end
	task.spawn(waiter, true)
end

local function close(self: MutexInternal, reason: string)
	self.internal_values.phase = { kind = "closed", reason = reason }
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

local function is_locked(self: MutexInternal): boolean
	return self.internal_values.phase.kind == "locked"
end

local template = {
	internal_values = {
		phase = { kind = "free" } :: MutexPhase,
	},
	internal_waiters = {},
	lock = lock,
	unlock = unlock,
	close = close,
	with = with,
	is_locked = is_locked,
}

local meta = {
	__tostring = function(self: MutexInternal)
		return `Mutex({self.internal_values.phase.kind})`
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
})
