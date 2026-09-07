local types = require("./types")
local children = require("./children")
local codec = require("./codec")
local ids = require("./ids")
local jecs = require("./dependencies/jecs")
local logging = require("./logging")
local messages = require("./messages")
local ops = require("./ops")
local relations = require("./relations")
local schema = require("./schema")
local state = require("./state")
local util = require("./util")

type World = types.World
type Entity<T = nil> = types.Entity<T>
type ChildKind = types.ChildKind
type ChildRecord = types.ChildRecord
type ComponentEntry = types.ComponentEntry
type Context = types.Context
type Data = types.Data
type Decoded = types.Decoded
type EntityState = types.EntityState
type RelationEntry = types.RelationEntry
type SchemaEntry = types.SchemaEntry
type Snapshot = types.Snapshot
type State = types.State
type SyncKind = types.SyncKind
type TagEntry = types.TagEntry

local rejected: Decoded = table.freeze({ kind = "rejected" })

local function apply_tag(world: World, entity: Entity, entry: TagEntry, value: any, stamped: boolean)
	if value == true then
		if not world:has(entity, entry.id) then
			world:add(entity, entry.id)
		end
	elseif value == false or stamped then
		if world:has(entity, entry.id) then
			world:remove(entity, entry.id)
		end
	end
end

local function decode(world: World, entity: Entity, entry: ComponentEntry, value: any): Decoded
	local ok, result = pcall(codec.runtime_form, entry, value)
	if not ok then
		logging.warn(messages.warnings.deserialize_failed(entry.key, util.describe(world, entity), result))
		return rejected
	end
	local checked = codec.check_guard(entry, result)
	if checked.kind == "rejected" then
		logging.warn(messages.warnings.stored_rejected(entry.key, util.describe(world, entity), checked.reason))
		return rejected
	end
	return { kind = "ok", value = result }
end

local function apply_component(
	world: World,
	entity: Entity,
	entry: ComponentEntry,
	entity_state: EntityState,
	value: any,
	stamped: boolean
)
	local key = entry.key
	local supplied = entity_state.supplied
	if value == nil then
		if stamped and world:has(entity, entry.id) then
			world:remove(entity, entry.id)
		end
		supplied[key] = nil
		return
	end
	if supplied[key] == value then
		return
	end
	supplied[key] = value

	local current = world:get(entity, entry.id)
	if current == value then
		return
	end
	local decoded = decode(world, entity, entry, value)
	if decoded.kind == "rejected" or ops.deep_equal(current, decoded.value) then
		return
	end
	world:set(entity, entry.id, decoded.value)
end

local function apply_relation(
	context: Context,
	entity: Entity,
	entry: RelationEntry,
	entity_state: EntityState,
	value: any,
	stamped: boolean
)
	local key = entry.key
	local supplied = entity_state.supplied
	local named, warned = context.schema.named, context.world_state.warned
	if value == nil then
		if stamped then
			relations.apply(context.world, entry, entity, named, {}, warned)
		end
		supplied[key] = nil
		return
	end
	if type(value) ~= "table" then
		if supplied[key] ~= value then
			supplied[key] = value
			logging.warn(
				messages.warnings.stored_rejected(
					key,
					util.describe(context.world, entity),
					messages.reasons.pair_table
				)
			)
		end
		return
	end
	supplied[key] = nil
	relations.apply(context.world, entry, entity, named, value, warned)
end

local function apply(
	context: Context,
	entity: Entity,
	entries: { SchemaEntry },
	entity_state: EntityState,
	known: State,
	strict: boolean
)
	local world, world_state = context.world, context.world_state
	util.run_all(entries, function(entry)
		if entity_state.lazy[entry.key] then
			return
		end
		local value = known.truth[entry.key]
		local stamped = strict or known.stamps[entry.key] ~= nil
		state.with_applying(world_state, entity, entry.id, function()
			if entry.kind == "tag" then
				apply_tag(world, entity, entry, value, stamped)
			elseif entry.kind == "relation" then
				apply_relation(context, entity, entry, entity_state, value, stamped)
			else
				apply_component(world, entity, entry, entity_state, value, stamped)
			end
		end)
	end)
end

local function apply_initials(context: Context, entity: Entity, collection: Entity)
	local world, world_state = context.world, context.world_state
	for _, entry in schema.root_of(context.schema, collection).entries do
		if not entry.has_initial or world:has(entity, entry.id) then
			continue
		end
		state.with_applying(world_state, entity, entry.id, function()
			if entry.kind == "tag" then
				world:add(entity, entry.id)
			else
				world:set(entity, entry.id, ops.deep_copy(entry.initial))
			end
		end)
	end
end

local function with_initials(entries: { SchemaEntry }, data: Data): Data
	local filled = table.clone(data)
	for _, entry in entries do
		if filled[entry.key] ~= nil or not entry.has_initial then
			continue
		end
		if entry.kind == "tag" then
			filled[entry.key] = true
		else
			filled[entry.key] = codec.stored_form(entry, ops.deep_copy(entry.initial))
		end
	end
	return filled
end

local function restore_fields(context: Context, entity: Entity, entries: { SchemaEntry }, data: Data)
	local entity_state = state.entity_state(context.world_state, entity)
	apply(context, entity, entries, entity_state, { truth = data, stamps = {} }, true)
end

local function record_baseline(context: Context, entity: Entity, kind: ChildKind)
	state.entity_state(context.world_state, entity).baseline = children.pack_fields(
		context.world,
		context.world_state.entities,
		entity,
		kind.entries,
		context.schema.named,
		context.world_state.warned
	)
end

local function refresh_shadows(context: Context, entity: Entity, kind: ChildKind)
	state.entity_state(context.world_state, entity).shadow = state.read_values(context, entity, kind.entries)
	local index = context.world_state.children
	local kinds: { ChildKind } = kind.kinds
	for _, nested in kinds do
		for _, child in children.children_of(index, entity, nested.key) do
			refresh_shadows(context, child, nested)
		end
	end
end

local function record_subtree(context: Context, entity: Entity, kind: ChildKind)
	local index = context.world_state.children
	local kinds: { ChildKind } = kind.kinds
	for _, nested in kinds do
		for _, child in children.children_of(index, entity, nested.key) do
			if nested.mode == "attached" then
				record_baseline(context, child, nested)
			end
			record_subtree(context, child, nested)
		end
	end
end

local function record_baselines(context: Context, entity: Entity, kind: ChildKind)
	record_baseline(context, entity, kind)
	record_subtree(context, entity, kind)
end

local function with_baseline(baseline: Data, data: Data): Data
	local filled = table.clone(baseline)
	for key, value in data do
		filled[key] = value
	end
	return filled
end

local function apply_child(context: Context, child: Entity, kind: ChildKind, data: Data)
	local entity_state = state.entity_state(context.world_state, child)
	local truth = if kind.mode == "attached"
		then with_baseline(entity_state.baseline, data)
		else with_initials(kind.entries, data)
	local ok, err = pcall(apply, context, child, kind.entries, entity_state, { truth = truth, stamps = {} }, true)
	entity_state.shadow = state.read_values(context, child, kind.entries)
	entity_state.tree = data
	if not ok then
		error(err, 0)
	end
end

local function spawn_child(context: Context, parent: Entity, kind: ChildKind, id: string): Entity
	local world, world_state = context.world, context.world_state
	local child = world:entity()
	state.with_applying(world_state, child, nil, function()
		world:add(child, kind.tag)
		world:set(child, ids.child_id, id)
		world:add(child, jecs.pair(kind.via, parent))
	end)
	children.record(world_state.children, child, kind, parent, id)
	return child
end

local function remove_child(context: Context, child: Entity)
	local world_state = context.world_state
	state.with_applying(world_state, child, nil, function()
		children.delete_tree(context.world, world_state.children, child, world_state.deleting)
	end)
	world_state.entities[child] = nil
end

local function supply_children(context: Context, entity: Entity, kinds: { ChildKind }, data: Data)
	local index = context.world_state.children
	util.run_all(kinds, function(kind)
		local stored = children.stored_children(data, kind, context.world_state.warned)
		local present = table.clone(children.children_of(index, entity, kind.key))
		for id, child_data in stored do
			if type(child_data) ~= "table" then
				logging.warn(messages.warnings.child_invalid(kind.key, id, util.describe(context.world, entity)))
				continue
			end
			local child = present[id]
			present[id] = nil
			if child == nil and kind.mode == "attached" then
				continue
			end
			if child == nil then
				child = spawn_child(context, entity, kind, id)
			end
			if state.entity_state(context.world_state, child).tree == child_data then
				continue
			end
			apply_child(context, child, kind, child_data)
			supply_children(context, child, kind.kinds, child_data)
		end
		for _, child in present do
			if kind.mode == "owned" then
				remove_child(context, child)
			else
				table.clear(state.entity_state(context.world_state, child).lazy)
				apply_child(context, child, kind, {})
				supply_children(context, child, kind.kinds, {})
			end
		end
	end)
end

local function supply_child(context: Context, child: Entity, kind: ChildKind, data: Data)
	apply_child(context, child, kind, data)
	supply_children(context, child, kind.kinds, data)
end

local function reset_child(context: Context, child: Entity, kind: ChildKind)
	table.clear(state.entity_state(context.world_state, child).lazy)
	supply_child(context, child, kind, {})
end

local function release_children(context: Context, entity: Entity, kinds: { ChildKind })
	local index = context.world_state.children
	util.run_all(kinds, function(kind)
		for _, child in table.clone(children.children_of(index, entity, kind.key)) do
			if kind.mode == "owned" then
				remove_child(context, child)
			else
				reset_child(context, child, kind)
			end
		end
	end)
end

local function reconcile(context: Context, entity: Entity, known: State, collection: Entity, shallow: boolean)
	if not context.world:contains(entity) then
		return
	end
	local entity_state = state.entity_state(context.world_state, entity)
	local root = schema.root_of(context.schema, collection)
	local ok, err = pcall(apply, context, entity, root.entries, entity_state, known, false)
	entity_state.shadow = state.read_values(context, entity, context.schema.entries)
	if not ok then
		error(err, 0)
	end
	if shallow then
		return
	end
	supply_children(context, entity, root.kinds, known.truth)
end

local function wipe_entity(context: Context, entity: Entity, collection: Entity)
	local root = schema.root_of(context.schema, collection)
	local entity_state = state.entity_state(context.world_state, entity)
	table.clear(entity_state.lazy)
	release_children(context, entity, root.kinds)
	apply(context, entity, root.entries, entity_state, { truth = {}, stamps = {} }, true)
	apply_initials(context, entity, collection)
	table.clear(entity_state.supplied)
	entity_state.shadow = state.read_values(context, entity, context.schema.entries)
end

local function snapshot_fields(context: Context, entity: Entity, snapshots: { ComponentEntry })
	local world = context.world
	if not world:contains(entity) then
		return
	end
	for _, entry in snapshots do
		local snapshot = entry.snapshot :: Snapshot
		local ok, value = pcall(util.sync, "snapshot" :: SyncKind, entry.key, snapshot, world, entity)
		if not ok then
			logging.warn(messages.warnings.snapshot_failed(entry.key, util.describe(world, entity), value))
			continue
		end
		if value ~= nil and not ops.deep_equal(world:get(entity, entry.id), value) then
			world:set(entity, entry.id, value)
		end
	end
	local index = context.world_state.children
	local by_key = index.by_parent[entity]
	if not by_key then
		return
	end
	for _, list in by_key do
		for _, child in list do
			local held = children.child_of(index, child) :: ChildRecord
			snapshot_fields(context, child, held.kind.snapshots)
		end
	end
end

return table.freeze({
	apply_initials = apply_initials,
	record_baseline = record_baseline,
	record_baselines = record_baselines,
	restore_fields = restore_fields,
	refresh_shadows = refresh_shadows,
	reconcile = reconcile,
	supply_child = supply_child,
	reset_child = reset_child,
	wipe_entity = wipe_entity,
	remove_child = remove_child,
	release_children = release_children,
	snapshot_fields = snapshot_fields,
})
