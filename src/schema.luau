local types = require("./types")
local ids = require("./ids")
local jecs = require("./dependencies/jecs")
local logging = require("./logging")
local messages = require("./messages")
local state = require("./state")
local util = require("./util")

type World = types.World
type Entity<T = nil> = types.Entity<T>
type ChildKind = types.ChildKind
type ComponentEntry = types.ComponentEntry
type Fields = types.Fields
type Named = types.Named
type Schema = types.Schema
type SchemaEntry = types.SchemaEntry
type Holders = types.Holders

local frozen_ids = {
	ids.collection,
	ids.config,
	ids.saveable,
	ids.field_of,
	ids.guard,
	ids.serdes,
	ids.snapshot,
	ids.lazy,
	ids.pairs,
	ids.child,
	ids.migrations,
	ids.from_foreign,
}

local function resolve_key(world: World, id: Entity): string
	local key = world:get(id, ids.saveable)
	if type(key) ~= "string" or #key == 0 then
		error(messages.errors.saveable_unnamed(util.describe(world, id)), 0)
	end
	if string.find(key, "/", 1, true) then
		error(messages.errors.saveable_key_invalid(util.describe(world, id), key), 0)
	end
	return key
end

local function resolve_holders(world: World, id: Entity): Holders
	local holders: Holders = {}
	for _, target in util.targets_of(world, id, ids.field_of) do
		holders[target] = true
	end
	return holders
end

local function resolve_targets(world: World, id: Entity): { [Entity]: boolean }?
	local config: any = world:get(id, ids.pairs)
	if config == nil then
		return nil
	end
	if type(config) ~= "table" or (config.targets ~= nil and type(config.targets) ~= "table") then
		error(messages.errors.pairs_targets_invalid(util.describe(world, id)), 0)
	end
	if config.targets == nil then
		return nil
	end
	local targets: { [Entity]: boolean } = {}
	for _, target in config.targets do
		if type(target) ~= "number" then
			error(messages.errors.pairs_targets_invalid(util.describe(world, id)), 0)
		end
		targets[(target :: any) :: Entity] = true
	end
	return targets
end

local function create_relation(world: World, id: Entity, key: string, holders: Holders): SchemaEntry
	for meta, what in
		{ [ids.guard] = "a guard", [ids.serdes] = "serdes", [ids.snapshot] = "a snapshot", [ids.lazy] = "lazy" }
	do
		if world:has(id, meta) then
			error(messages.errors.pairs_meta(util.describe(world, id), what), 0)
		end
	end
	return {
		kind = "relation",
		id = id,
		key = key,
		has_initial = false,
		tagged = jecs.is_tag(world, id),
		targets = resolve_targets(world, id),
		holders = holders,
	}
end

local function create_entry(world: World, id: Entity, key: string): SchemaEntry
	local has_initial = world:has(id, id)
	local holders = resolve_holders(world, id)
	if world:has(id, ids.pairs) then
		return create_relation(world, id, key, holders)
	end
	if jecs.is_tag(world, id) then
		if world:has(id, ids.snapshot) then
			error(messages.errors.snapshot_on_tag(util.describe(world, id)), 0)
		end
		if world:has(id, ids.lazy) then
			error(messages.errors.lazy_on_tag(util.describe(world, id)), 0)
		end
		return { kind = "tag", id = id, key = key, has_initial = has_initial, holders = holders }
	end
	return {
		kind = "component",
		id = id,
		key = key,
		has_initial = has_initial,
		initial = world:get(id, id),
		guard = world:get(id, ids.guard),
		serdes = world:get(id, ids.serdes),
		snapshot = world:get(id, ids.snapshot),
		lazy = world:has(id, ids.lazy),
		holders = holders,
	}
end

local function warn_unguarded(entries: { SchemaEntry })
	local keys: { string } = {}
	for _, entry in entries do
		if entry.kind == "component" and entry.guard == nil then
			table.insert(keys, entry.key)
		end
	end
	if #keys > 0 then
		logging.warn(messages.warnings.unguarded(keys))
	end
end

local function snapshots_of(entries: { SchemaEntry }): { ComponentEntry }
	local snapshots: { ComponentEntry } = {}
	for _, entry in entries do
		if entry.kind == "component" and entry.snapshot then
			table.insert(snapshots, entry)
		end
	end
	return snapshots
end

local function kinds_of(kinds: { ChildKind }, target: Entity): { ChildKind }
	local held: { ChildKind } = {}
	for _, kind in kinds do
		if kind.holders[target] then
			table.insert(held, kind)
		end
	end
	return held
end

local function entries_of(entries: { SchemaEntry }, target: Entity): { SchemaEntry }
	local held: { SchemaEntry } = {}
	for _, entry in entries do
		if entry.holders[target] then
			table.insert(held, entry)
		end
	end
	return held
end

local function fields_of(entries: { SchemaEntry }, kinds: { ChildKind }, target: Entity): Fields
	local held = entries_of(entries, target)
	return { entries = held, snapshots = snapshots_of(held), kinds = kinds_of(kinds, target) }
end

local function create_kind(world: World, tag: Entity, entries: { SchemaEntry }): ChildKind
	local described = util.describe(world, tag)
	local reasons = messages.reasons
	local config: any = world:get(tag, ids.child)
	if type(config) ~= "table" then
		error(messages.errors.child_config_invalid(described, reasons.child_not_table), 0)
	end
	if type(config.key) ~= "string" or #config.key == 0 or string.find(config.key, "/", 1, true) then
		error(messages.errors.child_config_invalid(described, reasons.child_key), 0)
	end
	if config.mode ~= "owned" and config.mode ~= "attached" then
		error(messages.errors.child_config_invalid(described, reasons.child_mode), 0)
	end
	if type(config.via) ~= "number" or not world:has(config.via, jecs.Exclusive) then
		error(messages.errors.child_config_invalid(described, reasons.child_via), 0)
	end
	if not jecs.is_tag(world, tag) then
		error(messages.errors.child_config_invalid(described, reasons.child_tag), 0)
	end
	local held = entries_of(entries, tag)
	local holders = resolve_holders(world, tag)
	if config.mode == "owned" then
		return {
			tag = tag,
			via = config.via,
			key = config.key,
			holders = holders,
			entries = held,
			snapshots = snapshots_of(held),
			kinds = {},
			mode = "owned",
		}
	end
	if config.id == nil then
		error(messages.errors.child_config_invalid(described, reasons.child_id), 0)
	end
	return {
		tag = tag,
		via = config.via,
		key = config.key,
		holders = holders,
		entries = held,
		snapshots = snapshots_of(held),
		kinds = {},
		mode = "attached",
		id = config.id,
	}
end

local function validate_targets(world: World, entries: { SchemaEntry }, kinds: { ChildKind }, collections: { Entity })
	local known: { [Entity]: boolean } = {}
	for _, collection in collections do
		known[collection] = true
	end
	for _, kind in kinds do
		known[kind.tag] = true
	end
	local function check(what: string, id: Entity, holders: Holders)
		for target in holders do
			if not known[target] then
				error(messages.errors.field_of_invalid(what, util.describe(world, id), util.describe(world, target)), 0)
			end
		end
	end
	for _, entry in entries do
		check("saveable", entry.id, entry.holders)
	end
	for _, kind in kinds do
		check("child kind", kind.tag, kind.holders)
	end
end

local function validate_scoped(world: World, entries: { SchemaEntry }, kinds: { ChildKind })
	local unscoped: { string } = {}
	for _, entry in entries do
		if next(entry.holders) == nil then
			table.insert(unscoped, `saveable {util.describe(world, entry.id)}`)
		end
	end
	for _, kind in kinds do
		if next(kind.holders) == nil then
			table.insert(unscoped, `child kind {util.describe(world, kind.tag)}`)
		end
	end
	if #unscoped > 0 then
		error(messages.errors.scope_required(unscoped), 0)
	end
end

local function create_schema(world: World): Schema
	local entries: { SchemaEntry } = {}
	local by_key: { [string]: SchemaEntry } = {}

	for id in world:each(ids.saveable) do
		local key = resolve_key(world, id)
		local existing = by_key[key]
		if existing then
			error(messages.errors.duplicate_key(util.describe(world, existing.id), util.describe(world, id), key), 0)
		end
		local entry = create_entry(world, id, key)
		table.insert(entries, entry)
		by_key[key] = entry
	end
	table.sort(entries, function(a, b)
		return a.key < b.key
	end)

	local kinds: { ChildKind } = {}
	local kinds_by_relation: { [Entity]: { ChildKind } } = {}
	local kinds_by_key: { [string]: ChildKind } = {}
	for tag in world:each(ids.child) do
		local kind = create_kind(world, tag, entries)
		local clash = by_key[kind.key]
		if clash then
			error(
				messages.errors.child_key_clash(util.describe(world, tag), kind.key, util.describe(world, clash.id)),
				0
			)
		end
		local other = kinds_by_key[kind.key]
		if other then
			error(
				messages.errors.child_key_clash(util.describe(world, tag), kind.key, util.describe(world, other.tag)),
				0
			)
		end
		kinds_by_key[kind.key] = kind
		table.insert(kinds, kind)
		local siblings = kinds_by_relation[kind.via]
		if not siblings then
			siblings = {}
			kinds_by_relation[kind.via] = siblings
		end
		table.insert(siblings, kind)
	end
	table.sort(kinds, function(a, b)
		return a.key < b.key
	end)

	for _, kind in kinds do
		kind.kinds = kinds_of(kinds, kind.tag)
	end
	local collections: { Entity } = {}
	for collection in world:each(ids.collection) do
		table.insert(collections, collection)
	end
	local named: Named = {}
	local warned = state.get(world).warned
	for entity in world:each(jecs.Name) do
		local name = world:get(entity, jecs.Name)
		local other = named[name]
		if other ~= nil then
			logging.warn_once(warned, `name_shared:{name}`, messages.warnings.name_shared(name, other, entity))
		end
		named[name] = entity
	end
	local roots: { [Entity]: Fields } = {}
	for _, collection in collections do
		roots[collection] = fields_of(entries, kinds, collection)
	end
	validate_targets(world, entries, kinds, collections)
	validate_scoped(world, entries, kinds)

	warn_unguarded(entries)
	return {
		entries = entries,
		by_key = by_key,
		kinds = kinds,
		kinds_by_relation = kinds_by_relation,
		roots = roots,
		named = named,
	}
end

local function freeze(world: World)
	local function reject(id: Entity)
		error(messages.errors.schema_frozen(util.describe(world, id)), 0)
	end
	for _, id in frozen_ids do
		world:added(id, reject)
		world:changed(id, reject)
		world:removed(id, reject)
	end
end

local function get(world: World): Schema
	local world_state = state.get(world)
	local cached = world_state.schema
	if cached then
		return cached
	end
	local built = create_schema(world)
	world_state.schema = built
	freeze(world)
	return built
end

return table.freeze({
	create_schema = create_schema,
	get = get,
})
