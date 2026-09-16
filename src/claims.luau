local types = require("./types")
local capture = require("./capture")
local children = require("./children")
local ids = require("./ids")
local jecs = require("./dependencies/jecs")
local logging = require("./logging")
local messages = require("./messages")
local ops = require("./ops")
local reconcile = require("./reconcile")
local recorder = require("./recorder")
local state = require("./state")
local util = require("./util")

type Entity<T = nil> = types.Entity<T>
type Ancestry = types.Ancestry
type ChildKind = types.ChildKind
type Context = types.Context
type ExistingChild = types.ExistingChild
type MarkWrite = types.MarkWrite
type PendingDrop = types.PendingDrop
type RelationWrite = types.RelationWrite
type Undo = types.Undo
type WorldState = types.WorldState
type Write = types.Write

local function held_kind_of(context: Context, entity: Entity): ChildKind?
	local held = children.child_of(context.world_state.children, entity)
	if held then
		return held.kind
	end
	return children.kind_of(context.world, context.schema.kinds, entity)
end

local function is_held_by(context: Context, kind: ChildKind, parent: Entity): boolean
	local links = context.world_state.links[parent]
	if links then
		for collection in links do
			if kind.holders[collection] then
				return true
			end
		end
		return false
	end
	local parent_kind = held_kind_of(context, parent)
	if parent_kind then
		return kind.holders[parent_kind.tag] == true
	end
	return true
end

local function warn_unheld(context: Context, write: RelationWrite)
	local world = context.world
	local parent_kind = held_kind_of(context, write.parent)
	local holder = if parent_kind and not context.world_state.links[write.parent] then parent_kind.tag else write.parent
	logging.warn_once(
		context.world_state.warned,
		`{write.child.tag}/{holder}`,
		messages.warnings.child_unheld(
			util.describe(world, write.entity),
			children.describe_kind(world, write.child),
			util.describe(world, holder)
		)
	)
end

local function assign_id(context: Context, write: RelationWrite): string
	local world = context.world
	local existing = children.resolve_id(world, write.entity, write.child)
	if existing then
		return existing
	end
	if write.child.mode == "attached" then
		children.reject_unnamed(world, write.entity, write.child)
	end
	return children.mint_id(world, write.entity)
end

local function is_shallow_root(context: Context, root: Entity, kind: ChildKind): boolean
	for collection in context.world_state.links[root] do
		if kind.holders[collection] and context.world:has(root, jecs.pair(ids.data_shallow, collection)) then
			return true
		end
	end
	return false
end

local function supply_claimed(context: Context, entity: Entity, kind: ChildKind)
	local ancestry = children.ancestry(context.world_state, entity)
	if not ancestry then
		return
	end
	local sessions = capture.ancestry_sessions(context, ancestry)
	if #sessions == 0 or is_shallow_root(context, ancestry.root, ancestry.kind) then
		return
	end
	local split = capture.split_path(ancestry)
	local stored = ops.resolve(sessions[1]:get_truth(), split.key, split.path, #split.path)
	if type(stored) ~= "table" then
		return
	end
	reconcile.supply_child(context, entity, kind, stored, false)
end

local function pair_undo(write: RelationWrite, present: boolean, stored_id: any): Undo
	return {
		kind = "pair",
		entity = write.entity,
		id = write.trigger,
		present = present,
		child = write.child,
		parent = write.parent,
		stored_id = stored_id,
	}
end

local function is_legacy_group(context: Context, ancestry: Ancestry): boolean
	local sessions = capture.ancestry_sessions(context, ancestry)
	if #sessions == 0 then
		return false
	end
	local split = capture.split_path(ancestry)
	local group = ops.resolve(sessions[1]:get_truth(), split.key, split.path, #split.path - 1)
	return type(group) == "table" and group[1] ~= nil
end

local function stored_id_of(context: Context, entity: Entity, kind: ChildKind): any
	if kind.mode == "owned" then
		return context.world:get(entity, ids.child_id)
	end
	return context.world:get(entity, kind.id)
end

local function mark_dropped(context: Context, entity: Entity)
	local world_state = context.world_state
	state.entity_state(world_state, entity).dropped = true
	table.insert(world_state.dropped_entities, entity)
end

local function attach(context: Context, write: RelationWrite, was_dropped: boolean)
	if not was_dropped then
		reconcile.record_baselines(context, write.entity, write.child)
	end
	reconcile.refresh_shadows(context, write.entity, write.child)
	supply_claimed(context, write.entity, write.child)
end

local function is_unlinking_root(context: Context, root: Entity): boolean
	local unlinking = false
	local links: { [Entity]: string } = context.world_state.links[root] or {}
	for collection in links do
		if context.world:has(root, jecs.pair(ids.data_link, collection)) then
			return false
		end
		unlinking = true
	end
	return unlinking
end

local function is_loading_root(context: Context, root: Entity): boolean
	local world_state = context.world_state
	local links: { [Entity]: string } = world_state.links[root] or {}
	for collection, key in links do
		local link_state = state.link_states_of(world_state, collection)[key]
		if link_state and link_state.phase.kind == "loading" then
			return true
		end
	end
	return false
end

local function defer_drop(world_state: WorldState, root: Entity, drop: PendingDrop)
	local pending = world_state.pending_drops[root]
	if pending == nil then
		pending = {}
		world_state.pending_drops[root] = pending
	end
	table.insert(pending, drop)
end

local function cancel_drop(world_state: WorldState, root: Entity, entity: Entity)
	local pending = world_state.pending_drops[root]
	if pending == nil then
		return
	end
	for index = #pending, 1, -1 do
		if pending[index].entity == entity then
			table.remove(pending, index)
		end
	end
end

local function on_detached(context: Context, write: RelationWrite)
	local world_state = context.world_state
	local index = world_state.children
	local pair = jecs.pair(write.child.via, write.parent)
	local previous = children.child_of(index, write.entity)
	if previous and (previous.kind ~= write.child or previous.parent ~= write.parent) then
		return
	end
	local ancestry = if previous then children.ancestry(world_state, write.entity) else nil
	local applying = state.is_applying(world_state, write.entity, pair)
	if write.child.mode == "attached" and previous and not write.deleted and not applying then
		capture.flush_lazy(context, write.entity, write.child.entries)
	end
	children.forget(index, write.entity)
	world_state.pending_puts[write.entity] = nil
	if write.deleted then
		world_state.deleting[write.entity] = true
		world_state.entities[write.entity] = nil
		children.forget_parent(index, write.entity)
	end
	if applying then
		return
	end
	local leaving = world_state.deleting[write.parent]
	if write.child.mode == "attached" then
		local held = (previous ~= nil and leaving)
			or (ancestry ~= nil and #capture.ancestry_sessions(context, ancestry) > 0)
		if not write.deleted and held then
			table.insert(world_state.cleanups, { kind = "reset", entity = write.entity, child = write.child })
		end
		if not write.deleted then
			mark_dropped(context, write.entity)
			local active = world_state.capture
			if active and previous then
				table.insert(active.undo, pair_undo(write, true, stored_id_of(context, write.entity, write.child)))
			end
		end
		return
	end
	if leaving then
		if previous and not write.deleted then
			table.insert(world_state.cleanups, { kind = "delete", entity = write.entity })
		end
		return
	end
	if not write.deleted then
		mark_dropped(context, write.entity)
	end
	if ancestry and is_unlinking_root(context, ancestry.root) then
		defer_drop(world_state, ancestry.root, {
			entity = write.entity,
			ancestry = ancestry,
			kept = previous ~= nil and not write.deleted,
		})
		local active = world_state.capture
		if active then
			table.insert(active.undo, pair_undo(write, true, stored_id_of(context, write.entity, write.child)))
		end
		return
	end
	local stored_id = stored_id_of(context, write.entity, write.child)
	capture.emit_child(context, ancestry, capture.child_drop, function(active)
		table.insert(active.undo, pair_undo(write, true, stored_id))
	end)
end

local function validate_kind(context: Context, write: RelationWrite)
	local world, world_state = context.world, context.world_state
	for _, other in context.schema.kinds_by_relation[write.child.via] do
		if other ~= write.child and world:has(write.entity, other.tag) then
			capture.undo_trigger(context, write)
			error(
				messages.errors.child_kinds_ambiguous(
					util.describe(world, write.entity),
					children.describe_kind(world, write.child),
					children.describe_kind(world, other)
				),
				0
			)
		end
	end
	local held = children.child_of(world_state.children, write.entity)
	if held then
		capture.undo_trigger(context, write)
		error(
			messages.errors.child_double_parent(
				util.describe(world, write.entity),
				children.describe_kind(world, write.child),
				children.describe_kind(world, held.kind)
			),
			0
		)
	end
end

local function on_attached(context: Context, write: RelationWrite)
	local world_state = context.world_state
	local index = world_state.children
	local pair = jecs.pair(write.child.via, write.parent)
	local applying = state.is_applying(world_state, write.entity, pair)

	validate_kind(context, write)
	if not is_held_by(context, write.child, write.parent) then
		warn_unheld(context, write)
		return
	end
	local named, id = pcall(assign_id, context, write)
	if not named then
		capture.undo_trigger(context, write)
		error(id, 0)
	end
	local taken = children.children_of(index, write.parent, write.child.key)[id]
	if taken ~= nil and taken ~= write.entity then
		capture.undo_trigger(context, write)
		error(
			messages.errors.child_id_taken(
				util.describe(context.world, write.entity),
				children.describe_kind(context.world, write.child),
				id,
				util.describe(context.world, taken)
			),
			0
		)
	end
	children.record(index, write.entity, write.child, write.parent, id)
	local ancestry = children.ancestry(world_state, write.entity)
	if ancestry then
		cancel_drop(world_state, ancestry.root, write.entity)
	end
	local existing = world_state.entities[write.entity]
	local was_dropped = existing ~= nil and existing.dropped
	if existing then
		existing.dropped = false
	end
	if applying then
		return
	end
	if ancestry and is_legacy_group(context, ancestry) then
		children.forget(index, write.entity)
		capture.undo_trigger(context, write)
		error(
			messages.errors.child_group_legacy(
				util.describe(context.world, write.entity),
				children.describe_kind(context.world, write.child),
				write.child.key
			),
			0
		)
	end
	if world_state.capture and (ancestry == nil or #capture.ancestry_sessions(context, ancestry) == 0) then
		capture.reject_unloaded(context, write)
	end
	if write.child.mode == "attached" then
		attach(context, write, was_dropped)
		local active = world_state.capture
		if active then
			table.insert(active.undo, pair_undo(write, false, stored_id_of(context, write.entity, write.child)))
		end
		return
	end
	reconcile.refresh_shadows(context, write.entity, write.child)
	if ancestry and is_loading_root(context, ancestry.root) then
		world_state.pending_puts[write.entity] = true
	end
	local stored_id = stored_id_of(context, write.entity, write.child)
	capture.emit_child(context, ancestry, function(found)
		return capture.child_put(context, found)
	end, function(active)
		table.insert(active.undo, pair_undo(write, false, stored_id))
	end)
end

local function on_marked(context: Context, write: MarkWrite)
	local world_state = context.world_state
	local active = world_state.capture
	if active == nil or state.is_applying(world_state, write.entity, write.child.tag) then
		return
	end
	table.insert(active.undo, {
		kind = "mark",
		entity = write.entity,
		id = write.child.tag,
		present = write.change == "removed",
	})
end

local function journal(context: Context, write: Write)
	if write.kind == "component" then
		capture.journal_component(context, write, false)
	elseif write.kind == "mark" then
		on_marked(context, write)
	elseif write.change == "removed" then
		on_detached(context, write)
	else
		on_attached(context, write)
	end
end

local function collect_existing(context: Context): { ExistingChild }
	local world = context.world
	local found: { ExistingChild } = {}
	for _, kind in context.schema.kinds do
		for entity in world:each(kind.tag) do
			local parent = world:target(entity, kind.via, 0)
			if parent then
				table.insert(found, { kind = kind, entity = entity, parent = parent })
			end
		end
	end
	return found
end

local function index_existing(context: Context)
	local world, world_state = context.world, context.world_state
	for _, existing in collect_existing(context) do
		local kind, entity = existing.kind, existing.entity
		if not is_held_by(context, kind, existing.parent) then
			continue
		end
		local prior = children.child_of(world_state.children, entity)
		if prior then
			logging.warn(
				messages.warnings.child_ambiguous_existing(
					util.describe(world, entity),
					children.describe_kind(world, prior.kind),
					children.describe_kind(world, kind)
				)
			)
			continue
		end
		local resolved, id = pcall(children.resolve_id, world, entity, kind)
		if not resolved then
			logging.warn(messages.warnings.child_indexing_failed(util.describe(world, entity), id))
			continue
		end
		if id == nil and kind.mode == "owned" then
			id = children.mint_id(world, entity)
		end
		if id == nil then
			logging.warn(
				messages.warnings.child_unnamed_existing(
					util.describe(world, entity),
					children.describe_kind(world, kind)
				)
			)
			continue
		end
		local taken = children.children_of(world_state.children, existing.parent, kind.key)[id]
		if taken ~= nil then
			logging.warn(
				messages.warnings.child_id_taken_existing(
					util.describe(world, entity),
					children.describe_kind(world, kind),
					id,
					util.describe(world, taken)
				)
			)
			continue
		end
		children.record(world_state.children, entity, kind, existing.parent, id)
		if kind.mode == "attached" then
			reconcile.record_baseline(context, entity, kind)
		else
			reconcile.refresh_shadows(context, entity, kind)
		end
	end
end

local function install(context: Context): { () -> () }
	local world_state = context.world_state
	index_existing(context)
	return recorder.install(context.world, context.schema, context.schema.named, function(write)
		if
			write.kind == "component"
			and (write.deleted or state.is_applying(world_state, write.entity, write.entry.id))
		then
			return
		end
		journal(context, write)
	end)
end

return table.freeze({
	install = install,
	supply_claimed = supply_claimed,
})
