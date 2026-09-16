local types = require("./types")
local callbacks = require("./callbacks")
local contexts = require("./contexts")
local datastore = require("./datastore")
local hooks = require("./hooks")
local link = require("./link")
local listeners = require("./listeners")
local logging = require("./logging")
local messages = require("./messages")
local state = require("./state")
local util = require("./util")

type World = types.World
type Entity<T = nil> = types.Entity<T>
type Callback = types.Callback
type Context = types.Context
type Event = types.Event
type Session = types.Session
type SessionInternal = types.SessionInternal
type Symbol = types.Symbol
type UnloadAttempt = types.UnloadAttempt
type WorldPhase = types.WorldPhase

local close_budget = 25
local close_backoff_cap = 8

local function dispatch(context: Context, event: Event)
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
			dispatch(context, table.remove(events, 1) :: Event)
		end
	until #world_state.cleanups == 0
end

local function step(world: World)
	local world_state = state.get(world)
	if world_state.phase.kind ~= "idle" then
		return
	end
	local context = contexts.create_context(world)
	listeners.install(context)
	world_state.phase = { kind = "stepping" }
	local ok, err = pcall(drain, context)
	if (world_state.phase :: WorldPhase).kind == "stepping" then
		world_state.phase = { kind = "idle" }
	end
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

local function hook(world: World, hook_symbol: Symbol, callback: Callback): () -> ()
	if hook_symbol ~= (hooks.refused :: any) then
		error(messages.errors.hook_unknown(tostring(hook_symbol), "hooks.refused"), 0)
	end
	return callbacks.connect(state.get(world).hooks, hook_symbol, callback)
end

local function close(world: World, budget: number?)
	local world_state = state.get(world)
	world_state.phase = { kind = "closed" }
	if not listeners.is_installed(world_state) then
		return
	end

	local context = contexts.create_context(world)
	local guard = util.create_guard()
	local events = world_state.events
	world_state.events = {}
	for _, event in events do
		if event.kind == "loaded" then
			guard.run(function()
				link.on_loaded(context, event.link, event.session)
			end)
		else
			table.insert(world_state.events, event)
		end
	end
	for root in world_state.pending_drops do
		link.resolve_drops(context, root)
	end
	local detached = link.detach_all(context)
	link.run_cleanups(context)
	listeners.uninstall(world_state)
	world_state.links = {}
	world_state.entities = {}
	world_state.link_states = {}
	world_state.events = {}
	world_state.pending_drops = {}
	world_state.pending_puts = {}
	world_state.pending_root_puts = {}

	local deadline = os.time() + (budget or close_budget)
	util.join_all(detached.sessions, function(loaded)
		unload_until(loaded, deadline)
	end)
	if detached.err ~= nil then
		error(detached.err, 0)
	end
	guard.rethrow()
end

return table.freeze({
	step = step,
	get_session = get_session,
	wipe = wipe,
	close = close,
	hook = hook,
})
