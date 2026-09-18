local types = require("./types")
local relations = require("./relations")

type World = types.World
type Entity<T = nil> = types.Entity<T>
type Context = types.Context
type Data = types.Data
type EntityState = types.EntityState
type LinkState = types.LinkState
type Removal = types.Removal
type SchemaEntry = types.SchemaEntry
type SessionInternal = types.SessionInternal
type WorldState = types.WorldState

local states = setmetatable({} :: { [World]: WorldState }, { __mode = "k" })

local function get(world: World): WorldState
	local existing = states[world]
	if existing then
		return existing
	end

	local created: WorldState = {
		collections = {},
		schema = nil,
		disconnects = {},
		phase = { kind = "idle" },
		applying = nil,
		capture = nil,
		entities = {},
		children = { by_entity = {}, by_parent = {} },
		deleting = {},
		cleanups = {},
		pending_drops = {},
		pending_puts = {},
		pending_root_puts = {},
		dropped_entities = {},
		captures = {},
		hooks = {},
		warned = {},
		links = {},
		link_states = {},
		orphans = {},
		events = {},
		ordered = {},
	}
	states[world] = created
	return created
end

local function with_applying(world_state: WorldState, entity: Entity, id: Entity<any>?, fn: () -> ())
	local previous = world_state.applying
	world_state.applying = if id == nil
		then { kind = "entity", entity = entity }
		else { kind = "field", entity = entity, id = id }
	local ok, err = pcall(fn)
	world_state.applying = previous
	if not ok then
		error(err, 0)
	end
end

local function removing_of(world_state: WorldState, entity: Entity): { [string]: Removal }?
	local existing = world_state.entities[entity]
	return if existing then existing.removing else nil
end

local function forget_removing(world_state: WorldState, entity: Entity, key: string)
	local removing = removing_of(world_state, entity)
	if removing then
		removing[key] = nil
	end
end

local function mark_removing_field(world_state: WorldState, entity: Entity, key: string)
	local removing = removing_of(world_state, entity)
	if removing then
		removing[key] = { kind = "field" }
	end
end

local function removing_targets(world_state: WorldState, entity: Entity, key: string): { [Entity]: boolean }
	local removing = removing_of(world_state, entity)
	if removing == nil then
		return {}
	end

	local existing = removing[key]
	if existing and existing.kind == "targets" then
		return existing.targets
	end

	local targets: { [Entity]: boolean } = {}
	removing[key] = { kind = "targets", targets = targets }
	return targets
end

local function is_applying(world_state: WorldState, entity: Entity, id: Entity<any>): boolean
	local applying = world_state.applying
	if applying == nil or applying.entity ~= entity then
		return false
	end

	return applying.kind == "entity" or applying.id == id
end

local function entity_state(world_state: WorldState, entity: Entity): EntityState
	local existing = world_state.entities[entity]
	if existing then
		return existing
	end

	local created: EntityState =
		{ shadow = {}, supplied = {}, lazy = {}, baseline = {}, removing = {}, dropped = false }
	world_state.entities[entity] = created
	return created
end

local function read_values(context: Context, entity: Entity, entries: { SchemaEntry }): Data
	local world = context.world
	local values: Data = {}
	for _, entry in entries do
		if entry.kind == "tag" then
			values[entry.key] = world:has(entity, entry.id)
		elseif entry.kind == "relation" then
			values[entry.key] =
				relations.pack(world, entry, entity, nil, context.schema.named, context.world_state.warned)
		else
			values[entry.key] = world:get(entity, entry.id)
		end
	end

	return values
end

local function linked_key(world_state: WorldState, entity: Entity, collection: Entity): string?
	local links = world_state.links[entity]
	return if links then links[collection] else nil
end

local function link_states_of(world_state: WorldState, collection: Entity): { [string]: LinkState }
	local by_key = world_state.link_states[collection]
	if not by_key then
		by_key = {}
		world_state.link_states[collection] = by_key
	end

	return by_key
end

local function open_session(link_state: LinkState?): SessionInternal?
	if link_state == nil or link_state.phase.kind ~= "loaded" or not link_state.phase.session:is_open() then
		return nil
	end

	return link_state.phase.session
end

return table.freeze({
	get = get,
	with_applying = with_applying,
	is_applying = is_applying,
	forget_removing = forget_removing,
	mark_removing_field = mark_removing_field,
	removing_targets = removing_targets,
	entity_state = entity_state,
	read_values = read_values,
	linked_key = linked_key,
	link_states_of = link_states_of,
	open_session = open_session,
})
