local types = require("./types")
local children = require("./children")
local jecs = require("./dependencies/jecs")
local logging = require("./logging")
local messages = require("./messages")
local relations = require("./relations")
local state = require("./state")
local util = require("./util")

type World = types.World
type Entity<T = nil> = types.Entity<T>
type ChildKind = types.ChildKind
type EntityState = types.EntityState
type Named = types.Named
type RelationEntry = types.RelationEntry
type Removal = types.Removal
type RecorderSink = types.RecorderSink
type Schema = types.Schema
type SchemaEntry = types.SchemaEntry

local function removing_of(world: World, entity: Entity): { [string]: Removal }
	return state.entity_state(state.get(world), entity).removing
end

local function removed_targets(world: World, entity: Entity, key: string): { [Entity]: boolean }
	local removing = removing_of(world, entity)
	local existing = removing[key]
	if existing and existing.kind == "targets" then
		return existing.targets
	end
	local targets: { [Entity]: boolean } = {}
	removing[key] = { kind = "targets", targets = targets }
	return targets
end

local function watch_pairs(world: World, entry: RelationEntry, named: Named, sink: RecorderSink): { () -> () }
	local warned = state.get(world).warned
	local function emit(entity: Entity, except: { [Entity]: boolean }?, deleted: boolean)
		local value = if deleted then nil else relations.pack(world, entry, entity, except, named, warned)
		sink({
			kind = "component",
			entity = entity,
			entry = entry,
			change = if value == nil then "removed" else "changed",
			value = value,
			deleted = deleted,
		})
	end
	local function settled(entity: Entity)
		removing_of(world, entity)[entry.key] = nil
		emit(entity, nil, false)
	end
	return {
		world:added(entry.id, settled),
		world:changed(entry.id, settled),
		world:removed(entry.id, function(entity, id, deleted)
			local targets = removed_targets(world, entity, entry.key)
			targets[jecs.pair_second(world, id)] = true
			relations.prune(world, entry, entity, targets)
			emit(entity, targets, deleted == true)
		end),
	}
end

local function watch_names(world: World, named: Named): { () -> () }
	local warned = state.get(world).warned
	local names: { [Entity]: string } = {}
	for name, entity in named do
		names[entity] = name
	end
	local function forget(entity: Entity)
		local old = names[entity]
		if old ~= nil and named[old] == entity then
			named[old] = nil
		end
		names[entity] = nil
	end
	local function remember(entity: Entity, _, name: string)
		forget(entity)
		local other = named[name]
		if other ~= nil and other ~= entity then
			logging.warn_once(
				warned,
				`name_shared:{name}`,
				messages.warnings.name_shared(name, util.describe(world, other), tostring(entity))
			)
		end
		named[name] = entity
		names[entity] = name
	end
	return {
		world:added(jecs.Name, remember),
		world:changed(jecs.Name, remember),
		world:removed(jecs.Name, function(entity)
			forget(entity)
		end),
	}
end

local function watch(world: World, entry: SchemaEntry, named: Named, sink: RecorderSink): { () -> () }
	if entry.kind == "relation" then
		return watch_pairs(world, entry, named, sink)
	end
	return {
		world:added(entry.id, function(entity, _, value)
			removing_of(world, entity)[entry.key] = nil
			sink({
				kind = "component",
				entity = entity,
				entry = entry,
				change = "added",
				value = value,
				deleted = false,
			})
		end),
		world:changed(entry.id, function(entity, _, value)
			removing_of(world, entity)[entry.key] = nil
			sink({
				kind = "component",
				entity = entity,
				entry = entry,
				change = "changed",
				value = value,
				deleted = false,
			})
		end),
		world:removed(entry.id, function(entity, _, deleted)
			removing_of(world, entity)[entry.key] = { kind = "field" }
			sink({
				kind = "component",
				entity = entity,
				entry = entry,
				change = "removed",
				value = nil,
				deleted = deleted == true,
			})
		end),
	}
end

local function watch_relation(world: World, relation: Entity, kinds: { ChildKind }, sink: RecorderSink): { () -> () }
	return {
		world:added(relation, function(entity, id)
			local kind = children.kind_of(world, kinds, entity)
			if kind then
				sink({
					kind = "relation",
					entity = entity,
					child = kind,
					parent = jecs.pair_second(world, id),
					trigger = id,
					change = "added",
					deleted = false,
				})
			end
		end),
		world:removed(relation, function(entity, id, deleted)
			local kind = children.kind_of(world, kinds, entity)
			if kind then
				sink({
					kind = "relation",
					entity = entity,
					child = kind,
					parent = jecs.pair_second(world, id),
					trigger = id,
					change = "removed",
					deleted = deleted == true,
				})
			end
		end),
	}
end

local function watch_kind(world: World, kind: ChildKind, sink: RecorderSink): { () -> () }
	return {
		world:added(kind.tag, function(entity)
			local parent = world:target(entity, kind.via, 0)
			if parent then
				sink({
					kind = "relation",
					entity = entity,
					child = kind,
					parent = parent,
					trigger = kind.tag,
					change = "added",
					deleted = false,
				})
			end
		end),
		world:removed(kind.tag, function(entity, _, deleted)
			local parent = if deleted then nil else world:target(entity, kind.via, 0)
			if parent then
				sink({
					kind = "relation",
					entity = entity,
					child = kind,
					parent = parent,
					trigger = kind.tag,
					change = "removed",
					deleted = false,
				})
			end
		end),
	}
end

local function install(world: World, schema: Schema, named: Named, sink: RecorderSink): { () -> () }
	local disconnects: { () -> () } = {}
	for _, entry in schema.entries do
		for _, disconnect in watch(world, entry, named, sink) do
			table.insert(disconnects, disconnect)
		end
	end
	for relation, kinds in schema.kinds_by_relation do
		for _, disconnect in watch_relation(world, relation, kinds, sink) do
			table.insert(disconnects, disconnect)
		end
	end
	for _, kind in schema.kinds do
		for _, disconnect in watch_kind(world, kind, sink) do
			table.insert(disconnects, disconnect)
		end
	end
	for _, disconnect in watch_names(world, named) do
		table.insert(disconnects, disconnect)
	end
	return disconnects
end

return table.freeze({
	watch = watch,
	install = install,
})
