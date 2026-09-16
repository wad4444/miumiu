local types = require("./types")
local claims = require("./claims")
local ids = require("./ids")
local jecs = require("./dependencies/jecs")
local state = require("./state")
local util = require("./util")

type Entity<T = nil> = types.Entity<T>
type Context = types.Context
type WorldState = types.WorldState

local function enqueue_existing(context: Context)
	local world, world_state = context.world, context.world_state
	for entity in world:each(jecs.pair(ids.data_link, jecs.Wildcard)) do
		for _, collection in util.targets_of(world, entity, ids.data_link) do
			local key = world:get(entity, jecs.pair(ids.data_link, collection))
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
		world:added(ids.data_link, function(entity, id, key)
			table.insert(world_state.events, {
				kind = "link",
				entity = entity,
				collection = jecs.pair_second(world, id),
				key = key,
			})
		end)
	)
	table.insert(
		disconnects,
		world:changed(ids.data_link, function(entity, id, key)
			local collection = jecs.pair_second(world, id)
			if queued_key(world_state, entity, collection) == key then
				return
			end
			table.insert(world_state.events, { kind = "unlink", entity = entity, collection = collection })
			table.insert(world_state.events, { kind = "link", entity = entity, collection = collection, key = key })
		end)
	)
	table.insert(
		disconnects,
		world:removed(ids.data_link, function(entity, id, deleted)
			if deleted then
				world_state.deleting[entity] = true
			else
				world_state.unlinking[entity] = true
			end
			table.insert(world_state.events, {
				kind = "unlink",
				entity = entity,
				collection = jecs.pair_second(world, id),
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
