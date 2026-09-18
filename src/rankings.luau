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
type Claim = types.Claim
type Period = types.Period
type PeriodFunction = types.PeriodFunction
type Periods = types.Periods
type PeriodState = types.PeriodState
type PeriodPlace = types.PeriodPlace
type Placing = types.Placing
type Push = types.Push
type ResolvedCollectionConfig = types.ResolvedCollectionConfig
type RetryConfig = types.RetryConfig
type Rolled = types.Rolled
type SchemaEntry = types.SchemaEntry
type State = types.State
type SyncKind = types.SyncKind
type TopCache = types.TopCache

local record_key = "miumiu.ordered"
local reserved_prefix = "miumiu."
local name_limit = 40
local store_limit = 50
local page_limit = 100
local resolve_limit = 16
local defaults = { period_threshold = 10, poll_interval = 60 }
local known_fields = {
	component = true,
	period = true,
	map = true,
	period_threshold = true,
	poll_interval = true,
	on_period_change = true,
	reset = true,
}

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

local function current_period(store: OrderedStore, now: number): PeriodState
	if store.period == nil then
		return { kind = "none" }
	end
	local ok, result = pcall(period_of, store, now)
	if ok then
		return { kind = "period", period = result :: Period }
	end
	logging.warn_once(store.warned, "period_failed", messages.warnings.period_failed(store.name, result))
	return { kind = "failed" }
end

local function store_name(store: OrderedStore, index: number?): string
	return if index == nil then store.name else `{store.name}_{index}`
end

local function suffixed(periodic: OrderedStore, other: OrderedStore): boolean
	if periodic.period == nil then
		return false
	end
	local prefix = `{periodic.name}_`
	if string.sub(other.name, 1, #prefix) ~= prefix then
		return false
	end
	return string.match(string.sub(other.name, #prefix + 1), "^%d+$") ~= nil
end

local function shares_store(store: OrderedStore, other: OrderedStore): boolean
	return suffixed(store, other) or suffixed(other, store)
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
	for field in config do
		if not known_fields[field] then
			error(messages.errors.ordered_config_field(described, tostring(field)), 0)
		end
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
	if config.reset ~= nil then
		if type(config.reset) ~= "boolean" then
			error(messages.errors.ordered_config_invalid(described, reasons.ordered_reset), 0)
		end
		if period == nil then
			error(messages.errors.ordered_config_invalid(described, reasons.ordered_reset_period), 0)
		end
	end
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
		reset = config.reset ~= false,
		map = config.map or default_map,
		period_threshold = threshold,
		poll_interval = poll_interval,
		on_period_change = config.on_period_change,
		warned = {},
	}
	store.initial_score = if initial == nil then nil else score_of(store, initial)
	local current = current_period(store, os.time())
	local full = store_name(store, if current.kind == "period" then current.period.index else nil)
	if #full > store_limit then
		error(messages.errors.ordered_name_long(described, full, store_limit), 0)
	end
	return store
end

local function records_of(truth: Data): { [string]: OrderedRecord }
	local records = truth[record_key]
	return if type(records) == "table" then records else {}
end

local function stored_owed(stored: any): Owed?
	if type(stored) ~= "table" then
		return nil
	end
	local from, last = stored.from, stored.last
	local ordered = type(from) == "number" and type(last) == "number" and from % 1 == 0 and last % 1 == 0
	if not ordered or from > last then
		return nil
	end
	local owed: Owed = table.clone(stored)
	if type(owed.values) ~= "table" then
		owed.values = {}
	end
	if type(owed.taken) ~= "string" then
		owed.taken = nil
	end
	if type(owed.taken_at) ~= "number" then
		owed.taken_at = nil
	end
	return owed
end

local function stored_record(truth: Data, name: string): OrderedRecord
	local stored: any = records_of(truth)[name]
	if type(stored) ~= "table" then
		return {}
	end
	local record: OrderedRecord = table.clone(stored)
	if type(record.period) ~= "number" then
		record.period = nil
	end
	if type(record.pushed) ~= "number" then
		record.pushed = nil
	end
	record.owed = stored_owed(record.owed)
	return record
end

local function owed_of(truth: Data, name: string): Owed?
	return stored_record(truth, name).owed
end

local function periods_of(truth: Data): Periods
	local periods: Periods = {}
	for name in records_of(truth) do
		local period = stored_record(truth, name).period
		if period ~= nil then
			periods[name] = period
		end
	end
	return periods
end

local function stamp_for(state: State, key: string, now: number): number
	return math.max(now, (state.stamps[key] or 0) + 1)
end

local function reset_op(key: string, value: any, at: number): Op
	if value == nil then
		return { kind = "remove", key = key, at = at }
	end
	return { kind = "set", key = key, value = value, at = at }
end

local function field_op(state: State, name: string, field: string, value: any, now: number): Op
	local path = { name, field }
	local at = math.max(now, ops.path_floor(state.stamps, record_key, path) + 1)
	if value == nil then
		return { kind = "drop", key = record_key, path = path, at = at }
	end
	return { kind = "put", key = record_key, path = path, value = value, at = at }
end

local function delivery_limit(store: OrderedStore, period: Period, now: number): number
	if now >= period.start + store.poll_interval then
		return period.index - 1
	end
	return period.index - 2
end

local function is_fresh(owed: Owed, timeout: number, now: number): boolean
	return owed.taken ~= nil and now - (owed.taken_at or 0) <= timeout
end

local function is_held(owed: Owed, claim: Claim, now: number): boolean
	return is_fresh(owed, claim.timeout, now) and owed.taken == claim.id
end

local function claim_owed(store: OrderedStore, owed: Owed, period: Period, now: number, claim: Claim?): Owed?
	if claim == nil or not claim.receiving or store.on_period_change == nil then
		return nil
	end
	if delivery_limit(store, period, now) < owed.from or is_fresh(owed, claim.timeout, now) then
		return nil
	end
	local taken = table.clone(owed)
	taken.taken = claim.id
	taken.taken_at = now
	return taken
end

local function roll_store(store: OrderedStore, now: number, rolled: Rolled, claim: Claim?)
	local current = current_period(store, now)
	if current.kind == "failed" then
		return
	end
	local index = if current.kind == "period" then current.period.index else nil
	local state = rolled.state
	local key = store.entry.key
	local record = stored_record(state.truth, store.name)
	local next_record: OrderedRecord = table.clone(record)
	local stored = state.truth[key]
	local value = if stored == nil then store.initial else stored
	local score = if value == nil then nil else score_of(store, value)
	if index ~= nil and record.period ~= nil and record.period < index then
		local ending = record.pushed == nil and (score == nil or score == store.initial_score)
		if score ~= record.pushed and not ending then
			table.insert(rolled.pushes, { name = store_name(store, record.period), score = score })
		end
		if store.on_period_change then
			local owed = record.owed
			local values = if owed then table.clone(owed.values) else {}
			values[tostring(record.period)] = ops.deep_copy(value)
			next_record.owed = {
				from = if owed then owed.from else record.period,
				last = index - 1,
				values = values,
				taken = if owed then owed.taken else nil,
				taken_at = if owed then owed.taken_at else nil,
			}
		end
		next_record.period = index
		next_record.pushed = nil
		if store.reset then
			local at = stamp_for(state, key, now)
			local reset = reset_op(key, ops.deep_copy(store.initial), at)
			table.insert(rolled.ops, reset)
			rolled.resets[key] = math.max(rolled.resets[key] or 0, at)
			state = ops.replay(state, { reset })
			score = store.initial_score
		end
	end
	if index == nil then
		next_record.period = nil
	end
	local pushed = next_record.pushed
	local unranked = pushed == nil and (score == nil or score == store.initial_score)
	if score ~= pushed and not unranked then
		next_record.pushed = score
		if next_record.period == nil then
			next_record.period = index
		end
		table.insert(rolled.pushes, { name = store_name(store, next_record.period), score = score })
	end
	local owed = next_record.owed
	if owed and current.kind == "period" then
		next_record.owed = claim_owed(store, owed, current.period, now, claim) or owed
	end
	local changed: { Op } = {}
	if next_record.period ~= record.period then
		table.insert(changed, field_op(state, store.name, "period", next_record.period, now))
	end
	if next_record.pushed ~= record.pushed then
		table.insert(changed, field_op(state, store.name, "pushed", next_record.pushed, now))
	end
	if next_record.owed ~= record.owed then
		table.insert(changed, field_op(state, store.name, "owed", next_record.owed, now))
	end
	for _, op in changed do
		table.insert(rolled.ops, op)
		state = ops.replay(state, { op })
	end
	rolled.state = state
end

local function roll(state: State, ordered: { OrderedStore }, now: number, claim: Claim?): Rolled
	local rolled: Rolled = { state = state, ops = {}, pushes = {}, resets = {} }
	for _, store in ordered do
		roll_store(store, now, rolled, claim)
	end
	return rolled
end

local function get_store(config: ResolvedCollectionConfig, name: string): OrderedDataStore
	return util.cached(stores, config.data_store_service, name, function()
		return datastore.open_ordered(config.data_store_service, name)
	end)
end

local function push_one(config: ResolvedCollectionConfig, retry: RetryConfig, key: string, push: Push)
	local store = get_store(config, push.name)
	local score = push.score
	if score == nil then
		datastore.remove_ordered(store, key, retry)
	else
		datastore.set_ordered(store, key, score, retry)
	end
end

local function score_at(config: ResolvedCollectionConfig, name: string, key: string): number?
	return datastore.get_ordered(get_store(config, name), key, config)
end

local function unrank(
	config: ResolvedCollectionConfig,
	retry: RetryConfig,
	ordered: { OrderedStore },
	key: string,
	now: number,
	periods: Periods
)
	for _, store in ordered do
		local current = current_period(store, now)
		local index = periods[store.name]
		if index == nil and current.kind == "period" then
			index = current.period.index
		end
		if current.kind ~= "failed" then
			local full = store_name(store, index)
			local ok, err = pcall(function()
				datastore.remove_ordered(get_store(config, full), key, retry)
			end)
			if not ok then
				logging.warn(messages.warnings.unrank_failed(key, full, err))
			end
		end
	end
end

local function copy_entries(entries: { OrderedEntry }, count: number): { OrderedEntry }
	local copied: { OrderedEntry } = {}
	for index = 1, math.min(count, #entries) do
		table.insert(copied, { key = entries[index].key, score = entries[index].score })
	end
	return copied
end

local function cached_top(service: DataStoreService, name: string, count: number): { OrderedEntry }?
	local by_name = tops[service]
	local cache = if by_name then by_name[name] else nil
	if cache == nil then
		return nil
	end
	if #cache.entries >= count then
		return copy_entries(cache.entries, count)
	end
	if cache.complete then
		return copy_entries(cache.entries, #cache.entries)
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

local function read_top(
	config: ResolvedCollectionConfig,
	retry: RetryConfig,
	name: string,
	count: number,
	ascending: boolean
): TopCache
	local store = get_store(config, name)
	local pages = datastore.get_sorted(store, ascending, math.min(count, page_limit), retry)
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
		datastore.next_page(pages, retry)
	end
end

local function top(
	config: ResolvedCollectionConfig,
	retry: RetryConfig,
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
	local read = read_top(config, retry, name, count, ascending)
	if finished then
		remember_top(config.data_store_service, name, read)
	end
	return copy_entries(read.entries, #read.entries)
end

local function place_of(entries: { OrderedEntry }, key: string): number?
	for index, entry in entries do
		if entry.key == key then
			return index
		end
	end
	return nil
end

local function covered_last(store: OrderedStore, owed: Owed, period: Period, now: number): number
	return math.min(owed.last, delivery_limit(store, period, now), owed.from + resolve_limit - 1)
end

local function resolve(
	config: ResolvedCollectionConfig,
	retry: RetryConfig,
	store: OrderedStore,
	key: string,
	owed: Owed,
	period: Period,
	now: number
): Placing
	local last = covered_last(store, owed, period, now)
	local periods: { PeriodPlace } = {}
	local carried = nil
	for index = owed.from, last do
		local recorded = owed.values[tostring(index)]
		if recorded ~= nil then
			carried = recorded
		end
		local entries = top(config, retry, store, index, store.period_threshold, false, now)
		local place = place_of(entries, key)
		if place ~= nil then
			local value = if recorded ~= nil then recorded elseif store.reset then store.initial else carried
			table.insert(periods, { period = index, value = ops.deep_copy(value), place = place })
		end
	end
	return { store = store, from = owed.from, last = last, periods = periods }
end

local function remaining(owed: Owed, last: number): Owed?
	if last >= owed.last then
		return nil
	end
	local values: { [string]: any } = {}
	for index = last + 1, owed.last do
		local recorded = owed.values[tostring(index)]
		if recorded ~= nil then
			values[tostring(index)] = recorded
		end
	end
	return { from = last + 1, last = owed.last, values = values, taken = owed.taken, taken_at = owed.taken_at }
end

return table.freeze({
	is_reserved = is_reserved,
	create_store = create_store,
	period_of = period_of,
	store_name = store_name,
	owed_of = owed_of,
	periods_of = periods_of,
	current_period = current_period,
	shares_store = shares_store,
	is_held = is_held,
	covered_last = covered_last,
	remaining = remaining,
	field_op = field_op,
	roll = roll,
	push_one = push_one,
	score_at = score_at,
	unrank = unrank,
	top = top,
	resolve = resolve,
})
