local types = require("./types")
local jecs = require("./dependencies/jecs")
local messages = require("./messages")

type World = types.World
type Entity<T = nil> = types.Entity<T>
type ErrorGuard = types.ErrorGuard
type SyncKind = types.SyncKind

local function describe(world: World, entity: Entity): string
	local name = world:get(entity, jecs.Name)
	return if name then `"{name}"` else tostring(entity)
end

local function targets_of(world: World, entity: Entity, relation: Entity<any>): { Entity }
	local targets: { Entity } = {}
	local index = 0
	while true do
		local target = world:target(entity, relation, index)
		if target == nil then
			return targets
		end

		table.insert(targets, target)
		index += 1
	end
end

local function sync<T...>(what: SyncKind, subject: string, fn: (...any) -> T..., ...: any): T...
	local thread = coroutine.create(fn)
	local result = table.pack(coroutine.resume(thread, ...))
	if coroutine.status(thread) == "suspended" then
		coroutine.close(thread)
		error(messages.errors.yielded(what, subject), 0)
	end

	if not result[1] then
		error(result[2], 0)
	end

	return table.unpack(result, 2, result.n)
end

local function create_guid(): string
	local guid = game:GetService("HttpService"):GenerateGUID(false)
	return (string.gsub(guid, "-", ""))
end

local function own<T>(original: T, current: T): T
	if current == original then
		return table.clone(original :: any) :: any
	end

	return current
end

local function create_guard(): ErrorGuard
	local failed: any = nil
	local function run(fn: () -> ())
		local ok, err = pcall(fn)
		if not ok and failed == nil then
			failed = err
		end
	end

	local function rethrow()
		if failed ~= nil then
			error(failed, 0)
		end
	end

	local function get_error(): any
		return failed
	end

	return { run = run, rethrow = rethrow, get_error = get_error }
end

local function run_all<T>(items: { T }, fn: (T) -> ())
	local first_error: any = nil
	for _, item in items do
		local ok, err = pcall(fn, item)
		if not ok and first_error == nil then
			first_error = err
		end
	end

	if first_error ~= nil then
		error(first_error, 0)
	end
end

local function join_all<T>(items: { T }, fn: (T) -> ())
	local remaining = #items
	local first_error: any = nil
	for _, item in items do
		task.spawn(function()
			local ok, err = pcall(fn, item)
			if not ok and first_error == nil then
				first_error = err
			end
			remaining -= 1
		end)
	end

	while remaining > 0 do
		task.wait()
	end

	if first_error ~= nil then
		error(first_error, 0)
	end
end

local function cached<K, V>(cache: { [K]: { [string]: V } }, owner: K, name: string, create: () -> V): V
	local by_name = cache[owner]
	if not by_name then
		by_name = {}
		cache[owner] = by_name
	end

	local value = by_name[name]
	if value == nil then
		value = create()
		by_name[name] = value
	end

	return value
end

return table.freeze({
	describe = describe,
	targets_of = targets_of,
	create_guard = create_guard,
	sync = sync,
	own = own,
	create_guid = create_guid,
	run_all = run_all,
	join_all = join_all,
	cached = cached,
})
