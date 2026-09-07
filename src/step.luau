local types = require("./types")
local contexts = require("./contexts")
local datastore = require("./datastore")
local link = require("./link")
local listeners = require("./listeners")
local logging = require("./logging")
local messages = require("./messages")
local state = require("./state")
local util = require("./util")

type World = types.World
type Entity<T = nil> = types.Entity<T>
type Context = types.Context
type Event = types.Event
type Session = types.Session
type SessionInternal = types.SessionInternal
type UnloadAttempt = types.UnloadAttempt

local close_budget = 25
local close_backoff_cap = 8

local function handle(context: Context, event: Event)
	if event.kind == "link" then
		link.on_link(context, event.entity, event.collection, event.key)
	elseif event.kind == "unlink" then
		link.on_unlink(context, event.entity, event.collection)
	elseif event.kind == "loaded" then
		link.on_loaded(context, event.link, event.session)
	elseif event.kind == "load_failed" then
		link.on_load_failed(context, event.link, event.err)
	elseif event.kind == "closed" then
		link.on_closed(context, event.link, event.session)
	elseif event.kind == "pulled" then
		link.on_pulled(context, event.link)
	end
end

local function drain(context: Context)
	local world_state = context.world_state
	repeat
		link.run_cleanups(context)
		local events = world_state.events
		while #events > 0 do
			handle(context, table.remove(events, 1) :: Event)
		end
	until #world_state.cleanups == 0
end

local function step(world: World)
	local world_state = state.get(world)
	if world_state.closed or world_state.stepping then
		return
	end
	local context = contexts.create_context(world)
	listeners.install(context)
	world_state.stepping = true
	local ok, err = pcall(drain, context)
	world_state.stepping = false
	if not ok then
		error(err, 0)
	end
end

local function get_session(world: World, collection: Entity, key: string): Session?
	return link.get_session(state.get(world), collection, key)
end

local function wipe(world: World, collection: Entity, key: string)
	link.wipe_key(contexts.create_context(world), collection, key)
end

local function unload_once(loaded: SessionInternal, deadline: number): UnloadAttempt
	local done, ok, err = false, false, nil
	task.spawn(function()
		ok, err = pcall(loaded.unload, loaded, datastore.single_attempt)
		done = true
	end)
	while not done and os.time() < deadline do
		task.wait()
	end
	if not done then
		return { kind = "failed", reason = messages.errors.close_timed_out(loaded:get_key()) }
	end
	if ok then
		return { kind = "done" }
	end
	return { kind = "failed", reason = tostring(err) }
end

local function unload_until(loaded: SessionInternal, deadline: number)
	local attempt = 0
	while loaded:is_open() do
		local result = unload_once(loaded, deadline)
		if not loaded:is_open() then
			if result.kind == "failed" and loaded:is_dirty() then
				logging.warn(messages.warnings.close_dropped(loaded:get_key(), result.reason))
			end
			return
		end
		if result.kind == "done" then
			continue
		end
		local remaining = deadline - os.time()
		if remaining <= 0 then
			local message = messages.closures.abandoned(loaded:get_key(), result.reason)
			logging.warn(message)
			loaded:discard(message)
			return
		end
		task.wait(math.min(loaded:get_config().retry_base * 2 ^ attempt, close_backoff_cap, remaining))
		attempt += 1
	end
end

local function close(world: World, budget: number?)
	local world_state = state.get(world)
	world_state.closed = true
	if not listeners.is_installed(world_state) then
		return
	end

	local detached = link.detach_all(contexts.create_context(world))
	listeners.uninstall(world_state)
	world_state.links = {}
	world_state.entities = {}
	world_state.link_states = {}
	world_state.events = {}

	local deadline = os.time() + (budget or close_budget)
	util.join_all(detached.sessions, function(loaded)
		unload_until(loaded, deadline)
	end)
	if detached.err ~= nil then
		error(detached.err, 0)
	end
end

return table.freeze({
	step = step,
	get_session = get_session,
	wipe = wipe,
	close = close,
})
