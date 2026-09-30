local types = require("./types")
local claims = require("./claims")
local ids = require("./ids")
local pepecs = require("./dependencies/pepecs")
local state = require("./state")
local util = require("./util")

type Entity<T = nil> = types.Entity<T>
type Context = types.Context
type WorldState = types.WorldState

local any_link = pepecs.pair(ids.data_link, pepecs.Wildcard)
local any_loaded = pepecs.pair(ids.data_loaded, pepecs.Wildcard)

local function enqueue_existing(context: Context)
	local world, world_state = context.world, context.world_state
	for entity in world.each(any_link) do
		for _, collection in util.targets_of(world, entity, ids.data_link) do
			local key = world.get(entity, pepecs.pair(ids.data_link, collection))
			table.insert(world_state.events, { kind = "link", entity = entity, collection = collection, key = key })
		end
	end
end

local function is_installed(world_state: WorldState): boolean
	return #world_state.disconnects > 0
end

local function queued_key(world_state: WorldState, entity: Entity, collection: Entity): string?
	local events = world_state.events
	for index = #events, 1, -1 do
		local event = events[index]
		if event.kind == "link" and event.entity == entity and event.collection == collection then
			return event.key
		end
	end

	return state.linked_key(world_state, entity, collection)
end

local function install(context: Context)
	local world, world_state = context.world, context.world_state
	if is_installed(world_state) then
		return
	end

	local disconnects = claims.install(context)
	table.insert(
		disconnects,
		world.added(any_link, function(entity, id, key)
			table.insert(world_state.events, {
				kind = "link",
				entity = entity,
				collection = world.pair_second(id),
				key = key,
			})
		end)
	)
	table.insert(
		disconnects,
		world.changed(any_link, function(entity, id, key)
			local collection = world.pair_second(id)
			if queued_key(world_state, entity, collection) == key then
				return
			end
			table.insert(world_state.events, { kind = "unlink", entity = entity, collection = collection })
			table.insert(world_state.events, { kind = "link", entity = entity, collection = collection, key = key })
		end)
	)
	table.insert(
		disconnects,
		world.removed(any_loaded, function(entity)
			if world.deleting(entity) then
				world_state.deleting[entity] = true
			end
		end)
	)
	table.insert(
		disconnects,
		world.removed(any_link, function(entity, id)
			if world.deleting(entity) then
				world_state.deleting[entity] = true
			end
			table.insert(world_state.events, {
				kind = "unlink",
				entity = entity,
				collection = world.pair_second(id),
			})
		end)
	)
	world_state.disconnects = disconnects

	enqueue_existing(context)
end

local function uninstall(world_state: WorldState)
	for _, disconnect in world_state.disconnects do
		disconnect()
	end
	world_state.disconnects = {}
end

return table.freeze({
	is_installed = is_installed,
	install = install,
	uninstall = uninstall,
})
