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
type Change = types.Change
type ChildKind = types.ChildKind
type Named = types.Named
type RecorderSink = types.RecorderSink
type RelationEntry = types.RelationEntry
type Schema = types.Schema
type SchemaEntry = types.SchemaEntry

local function forget_entity(world: World, entity: Entity)
	state.get(world).entities[entity] = nil
end

local function forget_removing(world: World, entity: Entity, key: string)
	state.forget_removing(state.get(world), entity, key)
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
		forget_removing(world, entity, entry.key)
		emit(entity, nil, false)
	end
	return {
		world:added(entry.id, settled),
		world:changed(entry.id, settled),
		world:removed(entry.id, function(entity, id, deleted)
			if deleted then
				forget_entity(world, entity)
				emit(entity, nil, true)
				return
			end
			local targets = state.removing_targets(state.get(world), entity, entry.key)
			targets[jecs.pair_second(world, id)] = true
			relations.prune(world, entry, entity, targets)
			emit(entity, targets, false)
		end),
	}
end

local function watch_names(world: World, named: Named): { () -> () }
	local warned = state.get(world).warned
	local names: { [Entity]: string } = {}
	local carriers: { [string]: { [Entity]: boolean } } = {}
	local function learn(entity: Entity, name: string)
		names[entity] = name
		local holders = carriers[name]
		if holders == nil then
			holders = {}
			carriers[name] = holders
		end
		holders[entity] = true
		local other = named[name]
		if other == nil then
			named[name] = entity
		elseif other ~= entity then
			logging.warn_once(
				warned,
				`name_shared:{name}`,
				messages.warnings.name_shared(name, util.describe(world, other), tostring(entity))
			)
		end
	end
	local function forget(entity: Entity)
		local old = names[entity]
		if old == nil then
			return
		end
		names[entity] = nil
		local holders = carriers[old]
		holders[entity] = nil
		if named[old] == entity then
			named[old] = next(holders) :: any
		end
	end
	local function remember(entity: Entity, _, name: string)
		forget(entity)
		learn(entity, name)
	end
	for entity in world:each(jecs.Name) do
		learn(entity, world:get(entity, jecs.Name))
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
	local function emit(change: Change): (Entity, any, any) -> ()
		return function(entity, _, value)
			forget_removing(world, entity, entry.key)
			sink({
				kind = "component",
				entity = entity,
				entry = entry,
				change = change,
				value = value,
				deleted = false,
			})
		end
	end
	return {
		world:added(entry.id, emit("added")),
		world:changed(entry.id, emit("changed")),
		world:removed(entry.id, function(entity, _, deleted)
			if deleted then
				forget_entity(world, entity)
			else
				state.mark_removing_field(state.get(world), entity, entry.key)
			end
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

local function emit_kind(world: World, kind: ChildKind, entity: Entity, change: "added" | "removed", sink: RecorderSink)
	local parent = world:target(entity, kind.via, 0)
	if parent then
		sink({
			kind = "relation",
			entity = entity,
			child = kind,
			parent = parent,
			trigger = kind.tag,
			change = change,
			deleted = false,
		})
		return
	end
	sink({ kind = "mark", entity = entity, child = kind, change = change })
end

local function watch_kind(world: World, kind: ChildKind, sink: RecorderSink): { () -> () }
	return {
		world:added(kind.tag, function(entity)
			emit_kind(world, kind, entity, "added", sink)
		end),
		world:removed(kind.tag, function(entity, _, deleted)
			if not deleted then
				emit_kind(world, kind, entity, "removed", sink)
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
