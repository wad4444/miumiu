local types = require("./types")
local capture = require("./capture")
local children = require("./children")
local collection = require("./collection")
local hooks = require("./hooks")
local ids = require("./ids")
local jecs = require("./dependencies/jecs")
local logging = require("./logging")
local messages = require("./messages")
local migrations = require("./migrations")
local reconcile = require("./reconcile")
local session = require("./session")
local state = require("./state")
local util = require("./util")

type World = types.World
type Entity<T = nil> = types.Entity<T>
type Cleanup = types.Cleanup
type CollectionState = types.CollectionState
type Context = types.Context
type Detached = types.Detached
type DropReason = types.DropReason
type LinkPhase = types.LinkPhase
type LinkState = types.LinkState
type LinkStatus = types.LinkStatus
type Session = types.Session
type SessionInternal = types.SessionInternal
type WorldState = types.WorldState

local function toggle(world: World, entity: Entity, id: Entity, on: boolean)
	if on then
		world:add(entity, id)
	else
		world:remove(entity, id)
	end
end

local function mark(context: Context, entity: Entity, collection_entity: Entity, status: LinkStatus, err: string?)
	local world = context.world
	if not world:contains(entity) then
		return
	end
	toggle(world, entity, jecs.pair(ids.data_loading, collection_entity), status == "loading")
	toggle(world, entity, jecs.pair(ids.data_loaded, collection_entity), status == "loaded")
	if err then
		world:set(entity, jecs.pair(ids.data_error, collection_entity), err)
	else
		world:remove(entity, jecs.pair(ids.data_error, collection_entity))
	end
end

local function is_current(context: Context, link_state: LinkState): boolean
	return state.link_states_of(context.world_state, link_state.collection)[link_state.key] == link_state
end

local function get_session(world_state: WorldState, collection_entity: Entity, key: string): Session?
	return state.open_session(state.link_states_of(world_state, collection_entity)[key])
end

local function is_shallow(context: Context, entity: Entity, collection_entity: Entity): boolean
	return context.world:has(entity, jecs.pair(ids.data_shallow, collection_entity))
end

local function entities_of(link_state: LinkState): { Entity }
	local entities: { Entity } = {}
	for entity in link_state.entities do
		table.insert(entities, entity)
	end
	return entities
end

local function convert_pending_puts(context: Context, root: Entity)
	local world_state = context.world_state
	for entity in world_state.pending_puts do
		local ancestry = children.ancestry(world_state, entity)
		if ancestry and ancestry.root == root then
			world_state.pending_puts[entity] = nil
			capture.emit_child(context, ancestry, function(found)
				return capture.child_put(context, found)
			end, function() end)
		end
	end
end

local function is_receiving(context: Context, link_state: LinkState): boolean
	local receiving = false
	for entity in link_state.entities do
		if not is_shallow(context, entity, link_state.collection) then
			receiving = true
		end
	end
	return receiving
end

local function supply_all(context: Context, link_state: LinkState, loaded: SessionInternal)
	local known = loaded:get_state()
	util.run_all(entities_of(link_state), function(entity)
		local collection_entity = link_state.collection
		local shallow = is_shallow(context, entity, collection_entity)
		reconcile.reconcile(context, entity, known, collection_entity, shallow)
		convert_pending_puts(context, entity)
	end)
end

local function resupply(context: Context, loaded: SessionInternal)
	for _, by_key in context.world_state.link_states do
		for _, link_state in by_key do
			local open = state.open_session(link_state)
			if open == loaded then
				supply_all(context, link_state, loaded)
			end
		end
	end
end

local function forget_orphan(world_state: WorldState, loaded: SessionInternal)
	local disconnect = world_state.orphans[loaded]
	if disconnect then
		world_state.orphans[loaded] = nil
		disconnect()
	end
end

local function adopt_orphan(world_state: WorldState, loaded: SessionInternal)
	world_state.orphans[loaded] = loaded:hook(hooks.closed, function()
		forget_orphan(world_state, loaded)
	end)
end

local function unload_quietly(context: Context, loaded: SessionInternal)
	adopt_orphan(context.world_state, loaded)
	task.spawn(function()
		local ok, err = pcall(loaded.unload, loaded)
		if ok then
			return
		end
		if loaded:is_open() then
			logging.warn(messages.warnings.unload_failed(loaded:get_key(), err))
		else
			logging.warn(messages.warnings.unlink_refused(loaded:get_key(), tostring(err)))
		end
	end)
end

local function watch_closed(context: Context, link_state: LinkState, loaded: SessionInternal): () -> ()
	local events = context.world_state.events
	return loaded:hook(hooks.closed, function()
		table.insert(events, { kind = "closed", link = link_state, session = loaded })
	end)
end

local function load(
	context: Context,
	collection_state: CollectionState,
	collection_entity: Entity,
	key: string,
	link: () -> LinkState
): thread
	local root = context.schema.roots[collection_entity]
	local migrate = migrations.create_migrate(
		context.schema,
		root,
		collection_state.config.migrations,
		key,
		context.world_state.warned
	)
	return task.defer(function()
		local ok, result = pcall(session.load_session, collection_state, key, migrate, function()
			return is_receiving(context, link())
		end)
		if ok then
			table.insert(context.world_state.events, { kind = "loaded", link = link(), session = result })
		else
			table.insert(context.world_state.events, { kind = "load_failed", link = link(), err = tostring(result) })
		end
	end)
end

local function forget_link(context: Context, entity: Entity, collection_entity: Entity)
	local world_state = context.world_state
	local links = world_state.links[entity]
	links[collection_entity] = nil
	if next(links) == nil then
		world_state.links[entity] = nil
		world_state.entities[entity] = nil
	end
end

local function create_link(
	context: Context,
	collection_state: CollectionState,
	collection_entity: Entity,
	key: string
): LinkState
	local created: LinkState
	created = {
		collection = collection_entity,
		key = key,
		entities = {},
		phase = {
			kind = "loading",
			thread = load(context, collection_state, collection_entity, key, function()
				return created
			end),
		},
	}
	state.link_states_of(context.world_state, collection_entity)[key] = created
	return created
end

local function write_fields(context: Context, entity: Entity, collection_entity: Entity)
	local root = context.schema.roots[collection_entity]
	local guard = util.create_guard()
	guard.run(function()
		reconcile.snapshot_fields(context, entity, root.snapshots)
	end)
	guard.run(function()
		capture.flush_lazy(context, entity, root.entries)
	end)
	guard.rethrow()
end

local function snapshot_all(context: Context, link_state: LinkState)
	local guard = util.create_guard()
	for entity in link_state.entities do
		guard.run(function()
			write_fields(context, entity, link_state.collection)
		end)
	end
	guard.rethrow()
end

local function wipe_key(context: Context, collection_entity: Entity, key: string)
	local link_state = state.link_states_of(context.world_state, collection_entity)[key]
	if link_state and link_state.phase.kind == "unloading" then
		local leaving = link_state.phase.session
		local ok, err = pcall(leaving.wipe, leaving)
		if ok then
			return
		end
		if leaving:is_open() then
			error(err, 0)
		end
	end
	local loaded = state.open_session(link_state)
	if link_state == nil or loaded == nil then
		session.wipe_key(collection.get(context.world, collection_entity), key)
		return
	end
	loaded:wipe()
	util.run_all(entities_of(link_state), function(entity)
		reconcile.wipe_entity(context, entity, collection_entity)
	end)
end

local function loaded_phase(context: Context, link_state: LinkState, loaded: SessionInternal): LinkPhase
	local events = context.world_state.events
	local disconnect_pulled = loaded:hook(hooks.pulled, function()
		table.insert(events, { kind = "pulled", link = link_state })
	end)
	loaded:prepare_with(function()
		snapshot_all(context, link_state)
	end)
	local disconnect_closed = watch_closed(context, link_state, loaded)
	return {
		kind = "loaded",
		session = loaded,
		disconnect = function()
			disconnect_pulled()
			loaded:prepare_with(nil)
			disconnect_closed()
		end,
	}
end

local function register_link(context: Context, entity: Entity, collection_entity: Entity, key: string): LinkState?
	local world_state = context.world_state
	local links = world_state.links[entity]
	if not links then
		links = {}
		world_state.links[entity] = links
	end
	links[collection_entity] = key

	local by_key = state.link_states_of(world_state, collection_entity)
	local link_state = by_key[key]
	if link_state then
		local phase = link_state.phase
		if phase.kind ~= "unloading" or phase.session:is_open() then
			return link_state
		end
		phase.disconnect()
		by_key[key] = nil
	end
	local ok, collection_state = pcall(collection.get, context.world, collection_entity)
	if not ok then
		forget_link(context, entity, collection_entity)
		mark(context, entity, collection_entity, "none", tostring(collection_state))
		return nil
	end
	return create_link(context, collection_state, collection_entity, key)
end

local function overlapping_link(context: Context, entity: Entity, collection_entity: Entity): Entity?
	local links = context.world_state.links[entity]
	local root = context.schema.roots[collection_entity]
	if not links or not root then
		return nil
	end
	local kinds = root.kinds
	for other in links do
		if not context.world:has(entity, jecs.pair(ids.data_link, other)) then
			continue
		end
		for _, kind in context.schema.roots[other].kinds do
			if table.find(kinds, kind) then
				return other
			end
		end
	end
	return nil
end

local function readopt(context: Context, link_state: LinkState, loaded: SessionInternal, disconnect: () -> ())
	disconnect()
	loaded:reopen()
	forget_orphan(context.world_state, loaded)
	link_state.phase = loaded_phase(context, link_state, loaded)
end

local function on_link(context: Context, entity: Entity, collection_entity: Entity, key: string)
	local world = context.world
	if not world:contains(entity) then
		return
	end
	if type(key) ~= "string" or #key == 0 then
		local err =
			messages.errors.link_key_invalid(util.describe(world, entity), util.describe(world, collection_entity))
		mark(context, entity, collection_entity, "none", err)
		return
	end

	local overlapping = overlapping_link(context, entity, collection_entity)
	if overlapping then
		local err = messages.errors.link_kinds_overlap(
			util.describe(world, entity),
			util.describe(world, collection_entity),
			util.describe(world, overlapping)
		)
		mark(context, entity, collection_entity, "none", err)
		return
	end

	local link_state = register_link(context, entity, collection_entity, key)
	if not link_state then
		return
	end
	link_state.entities[entity] = true

	local phase = link_state.phase
	if phase.kind == "unloading" then
		readopt(context, link_state, phase.session, phase.disconnect)
		phase = link_state.phase
	end
	local ok, err = pcall(function()
		reconcile.apply_initials(context, entity, collection_entity)
		if phase.kind == "loaded" then
			local shallow = is_shallow(context, entity, collection_entity)
			reconcile.reconcile(context, entity, phase.session:get_state(), collection_entity, shallow)
		end
	end)
	mark(context, entity, collection_entity, if phase.kind == "loaded" then "loaded" else "loading")
	if not ok then
		error(err, 0)
	end
end

local function has_stashed_puts(context: Context, link_state: LinkState): boolean
	local by_key = context.world_state.pending_root_puts[link_state.collection]
	return by_key ~= nil and by_key[link_state.key] ~= nil
end

local function detach(context: Context, link_state: LinkState): SessionInternal?
	local phase = link_state.phase
	if phase.kind == "loading" then
		if coroutine.status(phase.thread) ~= "dead" and not has_stashed_puts(context, link_state) then
			task.cancel(phase.thread)
		end
		return nil
	end
	if phase.kind == "unloading" then
		return nil
	end
	phase.disconnect()
	return phase.session
end

local function resolve_drops(context: Context, root: Entity)
	local world_state = context.world_state
	local drops = world_state.pending_drops[root]
	if drops == nil then
		return
	end
	world_state.pending_drops[root] = nil
	local alive = context.world:contains(root)
	for _, drop in drops do
		if alive then
			capture.emit_child(context, drop.ancestry, capture.child_drop, function() end)
		elseif drop.kept then
			table.insert(world_state.cleanups, { kind = "delete", entity = drop.entity })
		end
	end
end

local function on_unlink(context: Context, entity: Entity, collection_entity: Entity)
	resolve_drops(context, entity)
	local by_key = state.link_states_of(context.world_state, collection_entity)
	local key = state.linked_key(context.world_state, entity, collection_entity)
	local link_state = if key then by_key[key] else nil
	local guard = util.create_guard()
	if link_state and state.open_session(link_state) then
		guard.run(function()
			write_fields(context, entity, collection_entity)
		end)
	end
	guard.run(function()
		mark(context, entity, collection_entity, "none")
	end)
	if key and link_state then
		forget_link(context, entity, collection_entity)
		local held = children.child_of(context.world_state.children, entity)
		if context.world_state.links[entity] == nil and held then
			capture.emit_child(context, children.ancestry(context.world_state, entity), function(found)
				return capture.child_put(context, found)
			end, function() end)
			reconcile.refresh_shadows(context, entity, held.kind)
		end
		if not context.world:contains(entity) then
			children.forget_parent(context.world_state.children, entity)
		end
		link_state.entities[entity] = nil
		if link_state.phase.kind == "loaded" then
			guard.run(function()
				reconcile.release_children(context, entity, context.schema.roots[collection_entity].kinds)
			end)
		end
		if next(link_state.entities) == nil then
			local loaded = detach(context, link_state)
			if loaded and loaded:is_open() then
				link_state.phase =
					{ kind = "unloading", session = loaded, disconnect = watch_closed(context, link_state, loaded) }
				unload_quietly(context, loaded)
			else
				by_key[key] = nil
			end
		end
	end
	guard.rethrow()
end

local function on_loaded(context: Context, link_state: LinkState, loaded: SessionInternal)
	local stashed = context.world_state.pending_root_puts[link_state.collection]
	local ops = if stashed then stashed[link_state.key] else nil
	if ops then
		stashed[link_state.key] = nil
		loaded:journal({ id = util.create_guid(), ops = ops, kind = "single" })
	end
	if not is_current(context, link_state) or link_state.phase.kind ~= "loading" then
		unload_quietly(context, loaded)
		return
	end

	link_state.phase = loaded_phase(context, link_state, loaded)
	local ok, err = pcall(supply_all, context, link_state, loaded)
	local marked, mark_err = pcall(util.run_all, entities_of(link_state), function(entity)
		mark(context, entity, link_state.collection, "loaded")
	end)
	if not ok then
		error(err, 0)
	end
	if not marked then
		error(mark_err, 0)
	end
end

local function error_of(reason: DropReason): string?
	if reason.kind == "failed" then
		return reason.message
	end
	if reason.kind == "unloaded" then
		return nil
	end
	local closure = reason.closure
	return if closure.kind == "clean" then nil else closure.message
end

local function drop_link(context: Context, link_state: LinkState, reason: DropReason)
	state.link_states_of(context.world_state, link_state.collection)[link_state.key] = nil
	local err = error_of(reason)
	util.run_all(entities_of(link_state), function(entity)
		forget_link(context, entity, link_state.collection)
		mark(context, entity, link_state.collection, "none", err)
		if reason.kind == "closed" then
			reconcile.release_children(context, entity, context.schema.roots[link_state.collection].kinds)
		end
	end)
end

local function on_load_failed(context: Context, link_state: LinkState, err: string)
	if not is_current(context, link_state) then
		return
	end
	drop_link(context, link_state, { kind = "failed", message = err })
end

local function on_closed(context: Context, link_state: LinkState, closed: SessionInternal)
	if not is_current(context, link_state) then
		return
	end
	local phase = link_state.phase
	if phase.kind == "unloading" then
		drop_link(context, link_state, { kind = "unloaded" })
	elseif phase.kind == "loaded" then
		phase.disconnect()
		local status = closed:get_status()
		if status.kind == "closed" then
			drop_link(context, link_state, { kind = "closed", closure = status.closure })
		end
	end
end

local function run_cleanup(context: Context, cleanup: Cleanup)
	if not context.world:contains(cleanup.entity) then
		return
	end
	if children.child_of(context.world_state.children, cleanup.entity) ~= nil then
		return
	end
	if cleanup.kind == "delete" then
		reconcile.remove_child(context, cleanup.entity)
	else
		reconcile.reset_child(context, cleanup.entity, cleanup.child)
	end
end

local function run_cleanups(context: Context)
	local world_state = context.world_state
	for _, entity in world_state.dropped_entities do
		local existing = world_state.entities[entity]
		if existing then
			existing.dropped = false
		end
	end
	table.clear(world_state.dropped_entities)
	while #world_state.cleanups > 0 do
		local cleanups = world_state.cleanups
		world_state.cleanups = {}
		table.clear(world_state.deleting)
		util.run_all(cleanups, function(cleanup)
			run_cleanup(context, cleanup)
		end)
	end
	table.clear(world_state.deleting)
end

local function on_pulled(context: Context, link_state: LinkState)
	local loaded = state.open_session(link_state)
	if loaded then
		supply_all(context, link_state, loaded)
	end
end

local function detach_all(context: Context): Detached
	local world_state = context.world_state
	local sessions: { SessionInternal } = {}
	local guard = util.create_guard()
	for collection_entity, by_key in world_state.link_states do
		for _, link_state in by_key do
			if state.open_session(link_state) then
				guard.run(function()
					snapshot_all(context, link_state)
				end)
			end
			for entity in link_state.entities do
				guard.run(function()
					if link_state.phase.kind == "loaded" then
						reconcile.release_children(context, entity, context.schema.roots[collection_entity].kinds)
					end
					mark(context, entity, collection_entity, "none")
				end)
			end
			local loaded = detach(context, link_state)
			if loaded then
				table.insert(sessions, loaded)
			end
		end
	end
	for loaded in world_state.orphans do
		forget_orphan(world_state, loaded)
		table.insert(sessions, loaded)
	end
	return { sessions = sessions, err = guard.get_error() }
end

return table.freeze({
	get_session = get_session,
	on_link = on_link,
	on_unlink = on_unlink,
	on_loaded = on_loaded,
	on_load_failed = on_load_failed,
	on_closed = on_closed,
	on_pulled = on_pulled,
	resolve_drops = resolve_drops,
	run_cleanups = run_cleanups,
	resupply = resupply,
	wipe_key = wipe_key,
	detach_all = detach_all,
})
