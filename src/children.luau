local types = require("./types")
local codec = require("./codec")
local ids = require("./ids")
local logging = require("./logging")
local messages = require("./messages")
local relations = require("./relations")
local util = require("./util")

type World = types.World
type Entity<T = nil> = types.Entity<T>
type Except = types.Except
type Ancestry = types.Ancestry
type ChildIndex = types.ChildIndex
type ChildKind = types.ChildKind
type ChildRecord = types.ChildRecord
type Data = types.Data
type Named = types.Named
type SchemaEntry = types.SchemaEntry
type Warned = types.Warned
type WorldState = types.WorldState

local function child_of(index: ChildIndex, entity: Entity): ChildRecord?
	return index.by_entity[entity]
end

local function children_of(index: ChildIndex, parent: Entity, key: string): { [string]: Entity }
	local by_key = index.by_parent[parent]
	local list = if by_key then by_key[key] else nil
	return list or {}
end

local function record(index: ChildIndex, entity: Entity, kind: ChildKind, parent: Entity, id: string)
	index.by_entity[entity] = { kind = kind, parent = parent, id = id }
	local by_key = index.by_parent[parent]
	if not by_key then
		by_key = {}
		index.by_parent[parent] = by_key
	end
	local list = by_key[kind.key]
	if not list then
		list = {}
		by_key[kind.key] = list
	end
	list[id] = entity
end

local function forget(index: ChildIndex, entity: Entity): ChildRecord?
	local existing = index.by_entity[entity]
	if not existing then
		return nil
	end
	index.by_entity[entity] = nil
	local by_key = index.by_parent[existing.parent]
	local list = if by_key then by_key[existing.kind.key] else nil
	if list then
		list[existing.id] = nil
	end
	return existing
end

local function forget_parent(index: ChildIndex, parent: Entity)
	index.by_parent[parent] = nil
end

local function describe_kind(world: World, kind: ChildKind): string
	return util.describe(world, kind.tag)
end

local function resolve_id(world: World, kind: ChildKind, entity: Entity): string?
	if kind.mode ~= "attached" then
		return world:get(entity, ids.child_id)
	end
	local value = world:get(entity, kind.id)
	if value == nil then
		return nil
	end
	if type(value) ~= "string" and type(value) ~= "number" then
		error(
			messages.errors.child_id_invalid(util.describe(world, entity), describe_kind(world, kind), typeof(value)),
			0
		)
	end
	local id = tostring(value)
	if string.find(id, "/", 1, true) then
		error(messages.errors.child_id_slash(util.describe(world, entity), describe_kind(world, kind), id), 0)
	end
	return id
end

local function mint_id(world: World, entity: Entity): string
	local id = util.create_guid()
	world:set(entity, ids.child_id, id)
	return id
end

local function ancestry(world_state: WorldState, entity: Entity): Ancestry?
	local index = world_state.children
	local segments: { string } = {}
	local current = entity
	local top: ChildRecord? = nil
	for _ = 1, 32 do
		if world_state.links[current] and top then
			local path = table.create(#segments)
			for position = #segments, 1, -1 do
				table.insert(path, segments[position])
			end
			return { root = current, path = path, kind = top.kind }
		end
		local link = index.by_entity[current]
		if not link then
			return nil
		end
		table.insert(segments, link.id)
		table.insert(segments, link.kind.key)
		top = link
		current = link.parent
	end
	return nil
end

local function lookup_entity(index: ChildIndex, root: Entity, path: { string }): Entity
	local current = root
	for position = 1, #path, 2 do
		local list = children_of(index, current, path[position])
		current = list[path[position + 1]]
	end
	return current
end

local function excludes(except: Except?, entity: Entity, entry: SchemaEntry): Except?
	if except and except.entity == entity and except.entry == entry then
		return except
	end
	return nil
end

local function pack_fields(
	world: World,
	entity: Entity,
	entries: { SchemaEntry },
	named: Named,
	warned: Warned,
	except: Except?
): Data
	local packed: Data = {}
	for _, entry in entries do
		local hit = excludes(except, entity, entry)
		if entry.kind == "tag" then
			if world:has(entity, entry.id) and not (hit and hit.removed) then
				packed[entry.key] = true
			elseif entry.has_initial then
				packed[entry.key] = false
			end
		elseif entry.kind == "relation" then
			packed[entry.key] = relations.pack(world, entry, entity, if hit then hit.target else nil, named, warned)
		else
			local value = if hit and hit.removed then nil else world:get(entity, entry.id)
			if value ~= nil then
				packed[entry.key] = codec.stored_form(entry, value)
			end
		end
	end
	return packed
end

local function pack(
	world: World,
	index: ChildIndex,
	entity: Entity,
	kind: ChildKind,
	named: Named,
	warned: Warned,
	except: Except?
): Data
	local packed = pack_fields(world, entity, kind.entries, named, warned, except)
	local nested_kinds: { ChildKind } = kind.kinds
	for _, nested in nested_kinds do
		local list = children_of(index, entity, nested.key)
		if next(list) ~= nil then
			local group: Data = {}
			for id, child in list do
				group[id] = pack(world, index, child, nested, named, warned, except)
			end
			packed[nested.key] = group
		end
	end
	return packed
end

local function kind_of(world: World, kinds: { ChildKind }, entity: Entity): ChildKind?
	for _, kind in kinds do
		if world:has(entity, kind.tag) then
			return kind
		end
	end
	return nil
end

local function reject_unnamed(world: World, kind: ChildKind, entity: Entity)
	error(messages.errors.child_unnamed(util.describe(world, entity), describe_kind(world, kind)), 0)
end

local function delete_tree(world: World, index: ChildIndex, entity: Entity, deleting: { [Entity]: boolean })
	local by_key = index.by_parent[entity]
	if by_key then
		for _, list in by_key do
			for _, child in list do
				local held = index.by_entity[child]
				if held and held.kind.mode == "owned" then
					delete_tree(world, index, child, deleting)
				end
			end
		end
	end
	forget(index, entity)
	forget_parent(index, entity)
	if world:contains(entity) then
		deleting[entity] = true
		world:delete(entity)
	end
end

local function stored_children(data: Data, kind: ChildKind, warned: Warned): { [string]: Data }
	local group = data[kind.key]
	if type(group) ~= "table" then
		return {}
	end
	local named: { [string]: Data } = {}
	local skipped = false
	for id, child in group do
		if type(id) == "string" then
			named[id] = child
		else
			skipped = true
		end
	end
	if skipped then
		logging.warn_once(warned, `child_group_array:{kind.key}`, messages.warnings.child_group_array(kind.key))
	end
	return named
end

return table.freeze({
	child_of = child_of,
	children_of = children_of,
	record = record,
	forget = forget,
	forget_parent = forget_parent,
	resolve_id = resolve_id,
	mint_id = mint_id,
	reject_unnamed = reject_unnamed,
	ancestry = ancestry,
	lookup_entity = lookup_entity,
	pack = pack,
	pack_fields = pack_fields,
	kind_of = kind_of,
	delete_tree = delete_tree,
	stored_children = stored_children,
})
