local types = require("./types")
local children = require("./children")
local codec = require("./codec")
local ids = require("./ids")
local jecs = require("./dependencies/jecs")
local logging = require("./logging")
local messages = require("./messages")
local ops = require("./ops")
local rankings = require("./rankings")
local recorder = require("./recorder")
local relations = require("./relations")
local state = require("./state")
local util = require("./util")

type World = types.World
type Entity<T = nil> = types.Entity<T>
type ChildKind = types.ChildKind
type Data = types.Data
type Fields = types.Fields
type Migrate = types.Migrate
type Migration = types.Migration
type MigrationContext = types.MigrationContext
type MigrationScratch = types.MigrationScratch
type RelationWrite = types.RelationWrite
type Schema = types.Schema
type SchemaEntry = types.SchemaEntry
type SyncKind = types.SyncKind
type Warned = types.Warned

local function mirror_component(scratch: World, id: Entity<any>)
	if not scratch:has(id, jecs.Component) then
		scratch:add(id, jecs.Component)
	end
end

local function mirror_ids(scratch: World, schema: Schema)
	for _, entry in schema.entries do
		if not scratch:contains(entry.id) then
			scratch:entity(entry.id)
		end
		if entry.kind == "component" or (entry.kind == "relation" and not entry.tagged) then
			mirror_component(scratch, entry.id)
		end
	end
	for name, target in schema.named do
		if not scratch:contains(target) then
			scratch:entity(target)
		end
		scratch:set(target, jecs.Name, name)
	end
	for _, kind in schema.kinds do
		for _, id in { kind.tag, kind.via } do
			if not scratch:contains(id) then
				scratch:entity(id)
			end
		end
		if not scratch:has(kind.via, jecs.Exclusive) then
			scratch:add(kind.via, jecs.Exclusive)
		end
		if kind.mode == "attached" then
			mirror_component(scratch, kind.id)
		end
	end
	mirror_component(scratch, ids.child_id)
end

local function touch(scratch: MigrationScratch, entity: Entity)
	if not scratch.recording then
		return
	end
	local index = scratch.children
	local current = entity
	for _ = 1, 32 do
		local held = index.by_entity[current]
		if not held then
			return
		end
		if held.parent == scratch.entity then
			scratch.touched[`{held.kind.key}/{held.id}`] = { key = held.kind.key, id = held.id }
			return
		end
		current = held.parent
	end
end

local function index_relation(scratch: MigrationScratch, write: RelationWrite)
	local world, index = scratch.world, scratch.children
	if write.change == "removed" then
		touch(scratch, write.entity)
		children.forget(index, write.entity)
		if write.deleted then
			children.forget_parent(index, write.entity)
		end
		return
	end
	local id = children.resolve_id(world, write.entity, write.child) or children.mint_id(world, write.entity)
	children.record(index, write.entity, write.child, write.parent, id)
	touch(scratch, write.entity)
end

local function create_scratch(schema: Schema, root: Fields, warned: Warned): MigrationScratch
	local world = jecs.world()
	mirror_ids(world, schema)
	local held: { [SchemaEntry]: boolean } = {}
	for _, entry in root.entries do
		held[entry] = true
	end
	local scratch: MigrationScratch
	scratch = {
		world = world,
		entity = world:entity(),
		children = { by_entity = {}, by_parent = {} },
		named = table.clone(schema.named),
		warned = warned,
		recording = false,
		ops = {},
		touched = {},
		sink = function(write)
			if write.kind == "mark" then
				return
			end
			if write.kind == "relation" then
				index_relation(scratch, write)
				return
			end
			if not scratch.recording then
				return
			end
			if write.entity ~= scratch.entity then
				touch(scratch, write.entity)
				return
			end
			if held[write.entry] or schema.by_key[write.entry.key] == nil then
				table.insert(scratch.ops, codec.op_for(write.entry, write.change, write.value))
			end
		end,
	}
	recorder.install(world, schema, scratch.named, scratch.sink)
	return scratch
end

local function set_stored(
	scratch: MigrationScratch,
	entity: Entity,
	entries: { SchemaEntry },
	key: string,
	data: Data,
	with_initials: boolean
)
	local world = scratch.world
	for _, entry in entries do
		local value = data[entry.key]
		if entry.kind == "tag" then
			if value == true or (value == nil and with_initials and entry.initial.kind == "value") then
				world:add(entity, entry.id)
			end
			continue
		end
		if entry.kind == "relation" then
			if type(value) == "table" then
				relations.apply(world, entry, entity, scratch.named, value, scratch.warned)
			end
			continue
		end
		if value == nil then
			local initial = entry.initial
			if with_initials and initial.kind == "value" then
				world:set(entity, entry.id, ops.deep_copy(initial.value))
			end
			continue
		end
		local ok, runtime = pcall(codec.runtime_form, entry, value)
		if ok then
			world:set(entity, entry.id, runtime)
		else
			logging.warn(messages.warnings.migration_deserialize_failed(entry.key, key, runtime))
		end
	end
end

local function spawn_tree(scratch: MigrationScratch, kinds: { ChildKind }, key: string, parent: Entity, data: Data)
	local world = scratch.world
	for _, kind in kinds do
		for id, child_data in children.stored_children(data, kind).named do
			if type(child_data) ~= "table" then
				continue
			end
			local child = world:entity()
			world:add(child, kind.tag)
			if kind.mode == "attached" then
				world:set(child, kind.id, id)
			else
				world:set(child, ids.child_id, id)
			end
			set_stored(scratch, child, kind.entries, key, child_data, kind.mode == "owned")
			world:add(child, jecs.pair(kind.via, parent))
			spawn_tree(scratch, kind.kinds, key, child, child_data)
		end
	end
end

local function supply(scratch: MigrationScratch, root: Fields, key: string, data: Data)
	set_stored(scratch, scratch.entity, root.entries, key, data, true)
	spawn_tree(scratch, root.kinds, key, scratch.entity, data)
end

local function create_migration_context(
	scratch: MigrationScratch,
	schema: Schema,
	key: string,
	data: Data
): MigrationContext
	local world, entity = scratch.world, scratch.entity
	local legacy_ids: { [string]: Entity<any> } = {}

	local function legacy(stored_key: string): Entity<any>
		if schema.by_key[stored_key] then
			error(messages.errors.legacy_is_saveable(key, stored_key), 0)
		end
		if rankings.is_reserved(stored_key) then
			error(messages.errors.legacy_reserved(key, stored_key), 0)
		end
		local id = legacy_ids[stored_key]
		if id then
			return id
		end
		if data[stored_key] == nil then
			error(messages.errors.legacy_missing(key, stored_key), 0)
		end
		for _, kind in schema.kinds do
			if kind.key == stored_key and next(children.stored_children(data, kind).named) ~= nil then
				error(messages.errors.legacy_is_children(key, stored_key), 0)
			end
		end
		id = world:entity()
		world:add(id, jecs.Component)
		world:set(id, jecs.Name, `miumiu.legacy.{stored_key}`)
		legacy_ids[stored_key] = id
		recorder.watch(world, {
			kind = "component",
			id = id,
			key = stored_key,
			initial = { kind = "none" },
			holders = {},
		}, scratch.named, scratch.sink)
		scratch.recording = false
		world:set(entity, id, data[stored_key])
		scratch.recording = true
		return id
	end

	return { key = key, legacy = legacy, stored = ops.deep_freeze(ops.deep_copy(data)) }
end

local function run(
	schema: Schema,
	root: Fields,
	list: { Migration },
	key: string,
	warned: Warned,
	truth: Data,
	applied: number
): Data
	local data = ops.deep_copy(truth)
	local scratch = create_scratch(schema, root, warned)
	supply(scratch, root, key, data)
	local context = create_migration_context(scratch, schema, key, data)

	scratch.recording = true
	for index = applied + 1, #list do
		local ok, err =
			pcall(util.sync, "migration" :: SyncKind, key, list[index], scratch.world, scratch.entity, context)
		if not ok then
			error(messages.errors.migration_failed(key, index, err), 0)
		end
	end
	scratch.recording = false

	for index, op in scratch.ops do
		if op.kind == "set" or op.kind == "remove" then
			op.at = index
		end
	end
	local migrated = ops.replay({ truth = data, stamps = {} }, scratch.ops).truth
	local index = scratch.children
	for _, slot in scratch.touched do
		migrated = util.own(data, migrated)
		local group = if type(migrated[slot.key]) == "table" then table.clone(migrated[slot.key]) else {}
		local child = children.children_of(index, scratch.entity, slot.key)[slot.id]
		local held = children.child_of(index, child)
		group[slot.id] = if held
			then children.pack(
				scratch.world,
				state.get(scratch.world).entities,
				index,
				child,
				held.kind,
				scratch.named,
				scratch.warned
			)
			else nil
		migrated[slot.key] = if next(group) ~= nil then group else nil
	end
	return migrated
end

local function create_migrate(schema: Schema, root: Fields, list: { Migration }, key: string, warned: Warned): Migrate
	return function(truth: Data, applied: number): Data
		return run(schema, root, list, key, warned, truth, applied)
	end
end

return table.freeze({
	create_migrate = create_migrate,
})
