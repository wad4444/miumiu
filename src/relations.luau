local types = require("./types")
local jecs = require("./dependencies/jecs")
local logging = require("./logging")
local messages = require("./messages")
local ops = require("./ops")
local util = require("./util")

type World = types.World
type Entity<T = nil> = types.Entity<T>
type Data = types.Data
type Named = types.Named
type RelationEntry = types.RelationEntry
type Warned = types.Warned

local function is_target(entry: RelationEntry, target: Entity): boolean
	local targets = entry.targets
	return targets == nil or targets[target] == true
end

local function pack(
	world: World,
	entry: RelationEntry,
	entity: Entity,
	except: { [Entity]: boolean }?,
	named: Named,
	warned: Warned
): Data?
	local packed: Data = {}
	local any = false
	for _, target in util.targets_of(world, entity, entry.id) do
		if (except and except[target]) or not is_target(entry, target) then
			continue
		end
		local name = world:get(target, jecs.Name)
		if type(name) ~= "string" then
			logging.warn_once(
				warned,
				`pair_unnamed:{entry.key}/{target}`,
				messages.warnings.pair_target_unnamed(entry.key, util.describe(world, entity), tostring(target))
			)
			continue
		end
		local owner = named[name]
		if owner == nil then
			named[name] = target
		elseif owner ~= target then
			logging.warn_once(
				warned,
				`name_shared:{name}`,
				messages.warnings.name_shared(name, util.describe(world, owner), tostring(target))
			)
			continue
		end
		local pair_value = if entry.tagged then true else world:get(entity, jecs.pair(entry.id, target))
		if pair_value == nil then
			continue
		end
		packed[name] = pair_value
		any = true
	end
	return if any then packed else nil
end

local function prune(world: World, entry: RelationEntry, entity: Entity, targets: { [Entity]: boolean })
	for target in targets do
		if not world:has(entity, jecs.pair(entry.id, target)) then
			targets[target] = nil
		end
	end
end

local function apply(world: World, entry: RelationEntry, entity: Entity, named: Named, value: Data, warned: Warned)
	for name, pair_value in value do
		local target = named[name]
		if target == nil then
			logging.warn_once(
				warned,
				`pair_unknown:{entry.key}/{name}`,
				messages.warnings.pair_target_unknown(entry.key, name, util.describe(world, entity))
			)
			continue
		end
		if not is_target(entry, target) then
			continue
		end
		local pair = jecs.pair(entry.id, target)
		if entry.tagged then
			if not world:has(entity, pair) then
				world:add(entity, pair)
			end
		elseif not ops.deep_equal(world:get(entity, pair), pair_value) then
			world:set(entity, pair, pair_value)
		end
	end
	for _, target in util.targets_of(world, entity, entry.id) do
		local name = world:get(target, jecs.Name)
		if not is_target(entry, target) or type(name) ~= "string" or named[name] ~= target or value[name] ~= nil then
			continue
		end
		local pair = jecs.pair(entry.id, target)
		if entry.tagged or world:get(entity, pair) ~= nil then
			world:remove(entity, pair)
		end
	end
end

return table.freeze({
	pack = pack,
	prune = prune,
	apply = apply,
})
