local types = require("./types")
local datastore = require("./datastore")
local foreign = require("./foreign")
local ids = require("./ids")
local logging = require("./logging")
local messages = require("./messages")
local state = require("./state")
local util = require("./util")

type World = types.World
type Entity<T = nil> = types.Entity<T>
type CollectionConfig = types.CollectionConfig
type CollectionState = types.CollectionState
type ForeignSource = types.ForeignSource
type ResolvedCollectionConfig = types.ResolvedCollectionConfig

local defaults = {
	pull_interval = 15,
	idle_interval = 60,
	retry_attempts = 5,
	retry_base = 1,
	commit_store = "miumiu_commits",
	commit_timeout = 300,
}

local write_cooldown = 6

local function validate_foreign(described: string, name: string, source: ForeignSource)
	if not foreign.is_supported(source.type) then
		error(messages.errors.unknown_foreign(described, tostring(source.type)), 0)
	end
	if type(source.name) ~= "string" or #source.name == 0 then
		error(messages.errors.foreign_unnamed(described), 0)
	end
	if source.name == name then
		error(messages.errors.foreign_name_clash(described, name), 0)
	end
	if type(source.source) ~= "table" or type(source.source.createCollection) ~= "function" then
		error(messages.errors.foreign_no_source(described, source.type), 0)
	end
	if type(source.options) ~= "table" then
		error(messages.errors.foreign_no_options(described, source.type), 0)
	end
end

local function validate_number(described: string, field: string, value: number, minimum: number, exclusive: boolean)
	if type(value) ~= "number" or value ~= value or value < minimum or (exclusive and value == minimum) then
		error(messages.errors.bad_config(described, field, minimum, exclusive), 0)
	end
end

local function validate_config(described: string, config: ResolvedCollectionConfig, given: CollectionConfig)
	validate_number(described, "pull_interval", config.pull_interval, 0, true)
	validate_number(described, "idle_interval", config.idle_interval, config.pull_interval, false)
	validate_number(described, "retry_attempts", config.retry_attempts, 1, false)
	validate_number(described, "retry_base", config.retry_base, 0, false)
	validate_number(described, "commit_timeout", config.commit_timeout, 0, true)
	if type(config.commit_store) ~= "string" or #config.commit_store == 0 then
		error(messages.errors.bad_commit_store(described), 0)
	end
	if config.user_ids ~= nil and type(config.user_ids) ~= "function" then
		error(messages.errors.bad_user_ids(described), 0)
	end
	if given.data_store_service == nil and config.pull_interval < write_cooldown then
		logging.warn(messages.warnings.fast_pull(described, config.pull_interval, write_cooldown))
	end
end

local function resolve_config(world: World, collection: Entity): ResolvedCollectionConfig
	local described = util.describe(world, collection)
	if not world:has(collection, ids.collection) then
		error(messages.errors.not_a_collection(described), 0)
	end

	local name = world:get(collection, ids.collection)
	if type(name) ~= "string" or #name == 0 then
		error(messages.errors.collection_unnamed(described), 0)
	end
	local given: CollectionConfig = world:get(collection, ids.config) or {}

	local source: ForeignSource? = world:get(collection, ids.from_foreign)
	if source then
		validate_foreign(described, name, source)
	end

	local pull_interval = given.pull_interval or defaults.pull_interval
	local config: ResolvedCollectionConfig = {
		name = name,
		data_store_service = given.data_store_service or datastore.default_service(),
		pull_interval = pull_interval,
		idle_interval = given.idle_interval or math.max(defaults.idle_interval, pull_interval),
		retry_attempts = given.retry_attempts or defaults.retry_attempts,
		retry_base = given.retry_base or defaults.retry_base,
		commit_store = given.commit_store or defaults.commit_store,
		commit_timeout = given.commit_timeout or defaults.commit_timeout,
		migrations = world:get(collection, ids.migrations) or {},
		foreign = source,
		user_ids = given.user_ids,
	}
	validate_config(described, config, given)
	return config
end

local function get(world: World, collection: Entity): CollectionState
	local world_state = state.get(world)
	local existing = world_state.collections[collection]
	if existing then
		return existing
	end

	local config = resolve_config(world, collection)
	local created: CollectionState = {
		config = config,
		store = datastore.open(config.data_store_service, config.name),
	}
	world_state.collections[collection] = created
	return created
end

return table.freeze({
	resolve_config = resolve_config,
	get = get,
})
