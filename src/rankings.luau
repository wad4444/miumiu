local types = require("./types")
local codec = require("./codec")
local datastore = require("./datastore")
local ids = require("./ids")
local jecs = require("./dependencies/jecs")
local logging = require("./logging")
local messages = require("./messages")
local ops = require("./ops")
local util = require("./util")

type World = types.World
type Entity<T = nil> = types.Entity<T>
type Data = types.Data
type DataStoreService = types.DataStoreService
type Op = types.Op
type OrderedDataStore = types.OrderedDataStore
type OrderedEntry = types.OrderedEntry
type OrderedRecord = types.OrderedRecord
type OrderedStore = types.OrderedStore
type Owed = types.Owed
type Period = types.Period
type PeriodFunction = types.PeriodFunction
type Placing = types.Placing
type Push = types.Push
type ResolvedCollectionConfig = types.ResolvedCollectionConfig
type Rolled = types.Rolled
type SchemaEntry = types.SchemaEntry
type State = types.State
type SyncKind = types.SyncKind
type TopCache = types.TopCache

local record_key = "miumiu.ordered"
local reserved_prefix = "miumiu."
local name_limit = 40
local page_limit = 100
local defaults = { period_threshold = 10, poll_interval = 60 }

local stores = setmetatable({} :: { [DataStoreService]: { [string]: OrderedDataStore } }, { __mode = "k" })
local tops = setmetatable({} :: { [DataStoreService]: { [string]: TopCache } }, { __mode = "k" })

local function is_reserved(key: string): boolean
	return string.sub(key, 1, #reserved_prefix) == reserved_prefix
end

local function default_map(stored: any): number?
	if type(stored) ~= "number" then
		return nil
	end
	return math.floor(stored)
end

local function fixed_period(length: number, epoch: number): PeriodFunction
	return function(now: number): Period
		local index = math.floor((now - epoch) / length)
		local start = epoch + index * length
		return { index = index, start = start, finish = start + length }
	end
end

local function resolve_period(described: string, config: any): PeriodFunction?
	if config == nil then
		return nil
	end
	if type(config) == "function" then
		return config
	end
	if type(config) == "number" then
		config = { length = config }
	end
	local valid = type(config) == "table"
		and type(config.length) == "number"
		and config.length > 0
		and config.length < math.huge
		and (config.epoch == nil or type(config.epoch) == "number")
	if not valid then
		error(messages.errors.ordered_config_invalid(described, messages.reasons.ordered_period), 0)
	end
	return fixed_period(config.length, config.epoch or 0)
end

local function validate_number(described: string, value: any, reason: string, minimum: number, integer: boolean)
	if type(value) ~= "number" or value ~= value or value < minimum or (integer and value % 1 ~= 0) then
		error(messages.errors.ordered_config_invalid(described, reason), 0)
	end
end

local function score_of(store: OrderedStore, stored: any): number?
	local ok, result = pcall(util.sync, "map" :: SyncKind, store.name, store.map, stored)
	if not ok then
		logging.warn_once(store.warned, "map_failed", messages.warnings.map_failed(store.name, result))
		return nil
	end
	if result == nil then
		return nil
	end
	if type(result) ~= "number" or result ~= result or result == math.huge or result < 0 then
		logging.warn_once(store.warned, "map_invalid", messages.warnings.map_invalid(store.name, tostring(result)))
		return nil
	end
	return math.floor(result)
end

local function create_store(
	world: World,
	entity: Entity,
	entries: { SchemaEntry },
	collections: { [Entity]: boolean }
): OrderedStore
	local described = util.describe(world, entity)
	local reasons = messages.reasons
	local config: any = world:get(entity, ids.ordered)
	if type(config) ~= "table" then
		error(messages.errors.ordered_config_invalid(described, reasons.ordered_not_table), 0)
	end
	local name = world:get(entity, jecs.Name)
	if type(name) ~= "string" or #name == 0 or #name > name_limit then
		error(messages.errors.ordered_unnamed(described, name_limit), 0)
	end
	local targets = util.targets_of(world, entity, ids.field_of)
	local collection = targets[1]
	if #targets ~= 1 or not collections[collection] then
		error(messages.errors.ordered_scope(described), 0)
	end
	local entry: SchemaEntry? = nil
	for _, candidate in entries do
		if candidate.id == config.component then
			entry = candidate
		end
	end
	if entry == nil or entry.kind ~= "component" then
		error(messages.errors.ordered_config_invalid(described, reasons.ordered_component), 0)
	end
	if not entry.holders[collection] then
		error(
			messages.errors.ordered_field(described, util.describe(world, entry.id), util.describe(world, collection)),
			0
		)
	end
	if config.map ~= nil and type(config.map) ~= "function" then
		error(messages.errors.ordered_config_invalid(described, reasons.ordered_map), 0)
	end
	local period = resolve_period(described, config.period)
	local threshold = if config.period_threshold == nil then defaults.period_threshold else config.period_threshold
	validate_number(described, threshold, reasons.ordered_threshold, 1, true)
	local poll_interval = if config.poll_interval == nil then defaults.poll_interval else config.poll_interval
	validate_number(described, poll_interval, reasons.ordered_poll, 0, false)
	if config.on_period_change ~= nil then
		if type(config.on_period_change) ~= "function" then
			error(messages.errors.ordered_config_invalid(described, reasons.ordered_callback), 0)
		end
		if period == nil then
			error(messages.errors.ordered_config_invalid(described, reasons.ordered_callback_period), 0)
		end
	end
	local initial = if entry.initial.kind == "value"
		then codec.stored_form(entry, ops.deep_copy(entry.initial.value))
		else nil
	local store: OrderedStore = {
		entity = entity,
		name = name,
		collection = collection,
		entry = entry,
		initial = initial,
		initial_score = nil,
		period = period,
		map = config.map or default_map,
		period_threshold = threshold,
		poll_interval = poll_interval,
		on_period_change = config.on_period_change,
		warned = {},
	}
	store.initial_score = if initial == nil then nil else score_of(store, initial)
	return store
end

local function period_of(store: OrderedStore, now: number): Period?
	local period = store.period
	if period == nil then
		return nil
	end
	local result: any = util.sync("period" :: SyncKind, store.name, period, now)
	local valid = type(result) == "table"
		and type(result.index) == "number"
		and result.index % 1 == 0
		and type(result.start) == "number"
		and type(result.finish) == "number"
	if not valid then
		error(messages.errors.bad_period(store.name, typeof(result)), 0)
	end
	return result
end

local function store_name(store: OrderedStore, index: number?): string
	return if index == nil then store.name else `{store.name}_{index}`
end

local function current_name(store: OrderedStore, now: number): string
	local current = period_of(store, now)
	return store_name(store, if current then current.index else nil)
end

local function records_of(truth: Data): { [string]: OrderedRecord }
	local records = truth[record_key]
	return if type(records) == "table" then records else {}
end

local function owed_of(truth: Data, name: string): Owed?
	local record = records_of(truth)[name]
	return if record then record.owed else nil
end

local function stamped_set(state: State, key: string, value: any, now: number): Op
	local at = math.max(now, (state.stamps[key] or 0) + 1)
	if value == nil then
		return { kind = "remove", key = key, at = at }
	end
	return { kind = "set", key = key, value = value, at = at }
end

local function stamped_put(state: State, path: { string }, value: any, now: number): Op
	local at = math.max(now, ops.path_floor(state.stamps, record_key, path) + 1)
	return { kind = "put", key = record_key, path = path, value = value, at = at }
end

local function roll_store(state: State, store: OrderedStore, now: number, rolled: { Op }, pushes: { Push }): State
	local key = store.entry.key
	local record: OrderedRecord = records_of(state.truth)[store.name] or {}
	local next_record: OrderedRecord = table.clone(record)
	local stored = state.truth[key]
	local value = if stored == nil then store.initial else stored
	local score = if value == nil then nil else score_of(store, value)
	local current = period_of(store, now)
	if current and record.period ~= nil and record.period < current.index then
		if score ~= record.pushed then
			table.insert(pushes, { name = store_name(store, record.period), score = score })
		end
		if store.on_period_change and record.owed == nil then
			next_record.owed = { period = record.period, value = ops.deep_copy(value) }
		end
		next_record.period = current.index
		next_record.pushed = nil
		local reset = stamped_set(state, key, ops.deep_copy(store.initial), now)
		table.insert(rolled, reset)
		state = ops.replay(state, { reset })
		score = store.initial_score
	end
	local pushed = next_record.pushed
	local unranked = pushed == nil and (score == nil or score == store.initial_score)
	if score ~= pushed and not unranked then
		next_record.pushed = score
		if current and next_record.period == nil then
			next_record.period = current.index
		end
		table.insert(pushes, { name = store_name(store, if current then current.index else nil), score = score })
	end
	if
		next_record.period == record.period
		and next_record.pushed == record.pushed
		and next_record.owed == record.owed
	then
		return state
	end
	local put = stamped_put(state, { store.name }, next_record, now)
	table.insert(rolled, put)
	return ops.replay(state, { put })
end

local function roll(state: State, ordered: { OrderedStore }, now: number): Rolled
	local rolled: { Op } = {}
	local pushes: { Push } = {}
	for _, store in ordered do
		state = roll_store(state, store, now, rolled, pushes)
	end
	return { state = state, ops = rolled, pushes = pushes }
end

local function get_store(config: ResolvedCollectionConfig, name: string): OrderedDataStore
	return util.cached(stores, config.data_store_service, name, function()
		return datastore.open_ordered(config.data_store_service, name)
	end)
end

local function push_one(config: ResolvedCollectionConfig, key: string, push: Push)
	local store = get_store(config, push.name)
	local score = push.score
	if score == nil then
		datastore.remove_ordered(store, key, config)
	else
		datastore.set_ordered(store, key, score, config)
	end
end

local function score_at(config: ResolvedCollectionConfig, name: string, key: string): number?
	return datastore.get_ordered(get_store(config, name), key, config)
end

local function unrank(config: ResolvedCollectionConfig, ordered: { OrderedStore }, key: string, now: number)
	for _, store in ordered do
		local ok, err = pcall(datastore.remove_ordered, get_store(config, current_name(store, now)), key, config)
		if not ok then
			logging.warn(messages.warnings.unrank_failed(key, store.name, err))
		end
	end
end

local function cached_top(service: DataStoreService, name: string, count: number): { OrderedEntry }?
	local by_name = tops[service]
	local cache = if by_name then by_name[name] else nil
	if cache == nil then
		return nil
	end
	if #cache.entries >= count then
		return table.move(cache.entries, 1, count, 1, {})
	end
	if cache.complete then
		return table.clone(cache.entries)
	end
	return nil
end

local function remember_top(service: DataStoreService, name: string, cache: TopCache)
	local by_name = tops[service]
	if not by_name then
		by_name = {}
		tops[service] = by_name
	end
	by_name[name] = cache
end

local function read_top(config: ResolvedCollectionConfig, name: string, count: number, ascending: boolean): TopCache
	local store = get_store(config, name)
	local pages = datastore.get_sorted(store, ascending, math.min(count, page_limit), config)
	local entries: { OrderedEntry } = {}
	while true do
		for _, entry in pages:GetCurrentPage() do
			if #entries == count then
				return { entries = entries, complete = false }
			end
			table.insert(entries, { key = entry.key, score = entry.value })
		end
		if pages.IsFinished then
			return { entries = entries, complete = true }
		end
		if #entries == count then
			return { entries = entries, complete = false }
		end
		datastore.next_page(pages, config)
	end
end

local function top(
	config: ResolvedCollectionConfig,
	store: OrderedStore,
	index: number?,
	count: number,
	ascending: boolean,
	now: number
): { OrderedEntry }
	local name = store_name(store, index)
	local current = period_of(store, now)
	local finished = not ascending and index ~= nil and current ~= nil and index < current.index
	if finished then
		local cached = cached_top(config.data_store_service, name, count)
		if cached then
			return cached
		end
	end
	local read = read_top(config, name, count, ascending)
	if finished then
		remember_top(config.data_store_service, name, read)
	end
	return table.clone(read.entries)
end

local function place_of(entries: { OrderedEntry }, key: string): number?
	for index, entry in entries do
		if entry.key == key then
			return index
		end
	end
	return nil
end

local function is_due(store: OrderedStore, owed_period: number, now: number): boolean
	local current = period_of(store, now) :: Period
	return current.index > owed_period + 1 or now >= current.start + store.poll_interval
end

local function resolve(
	config: ResolvedCollectionConfig,
	store: OrderedStore,
	key: string,
	owed: Owed,
	now: number
): Placing
	local entries = top(config, store, owed.period, store.period_threshold, false, now)
	return { store = store, value = owed.value, place = place_of(entries, key), period = owed.period }
end

return table.freeze({
	record_key = record_key,
	is_reserved = is_reserved,
	create_store = create_store,
	period_of = period_of,
	store_name = store_name,
	owed_of = owed_of,
	roll = roll,
	push_one = push_one,
	score_at = score_at,
	unrank = unrank,
	top = top,
	is_due = is_due,
	resolve = resolve,
})
