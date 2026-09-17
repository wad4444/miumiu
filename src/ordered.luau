local types = require("./types")
local collection = require("./collection")
local messages = require("./messages")
local rankings = require("./rankings")
local schema = require("./schema")
local state = require("./state")
local symbol = require("./symbol")
local util = require("./util")

type World = types.World
type Entity<T = nil> = types.Entity<T>
type OrderedEntry = types.OrderedEntry
type OrderedInternal = types.OrderedInternal
type OrderedStore = types.OrderedStore
type Period = types.Period
type ResolvedCollectionConfig = types.ResolvedCollectionConfig
type TopOptions = types.TopOptions

local ordered_symbol = symbol.create_symbol("Ordered")

local function get_name(self: OrderedInternal): string
	return self.internal_values.store.name
end

local function get_period(self: OrderedInternal): Period?
	return rankings.period_of(self.internal_values.store, os.time())
end

local function index_of(self: OrderedInternal, period: number?): number?
	local store = self.internal_values.store
	local current = rankings.period_of(store, os.time())
	if current == nil then
		if period ~= nil then
			error(messages.errors.no_periods(store.name), 0)
		end
		return nil
	end
	return period or current.index
end

local function get_top(self: OrderedInternal, count: number, options: TopOptions?): { OrderedEntry }
	local values = self.internal_values
	if type(count) ~= "number" or count < 1 or count % 1 ~= 0 then
		error(messages.errors.bad_count(values.store.name, count), 0)
	end
	local given: TopOptions = options or {}
	local index = index_of(self, given.period)
	return rankings.top(values.config, values.store, index, count, given.ascending == true, os.time())
end

local function get_score(self: OrderedInternal, key: string, period: number?): number?
	local values = self.internal_values
	return rankings.score_at(values.config, rankings.store_name(values.store, index_of(self, period)), key)
end

local function is_ordered(value: unknown): boolean
	return symbol.is_marked(value, ordered_symbol)
end

local template = {
	symbol = ordered_symbol,
	internal_values = {
		store = (nil :: any) :: OrderedStore,
		config = (nil :: any) :: ResolvedCollectionConfig,
	},
	get_name = get_name,
	get_period = get_period,
	get_top = get_top,
	get_score = get_score,
}

local meta = {
	__tostring = function(self: OrderedInternal)
		return `Ordered({self.internal_values.store.name})`
	end,
}

local function create_ordered(store: OrderedStore, config: ResolvedCollectionConfig): OrderedInternal
	local ordered = table.clone(template)
	ordered.internal_values = table.clone(template.internal_values)
	ordered.internal_values.store = store
	ordered.internal_values.config = config
	setmetatable(ordered, meta)
	return ordered :: OrderedInternal
end

local function get_ordered(world: World, entity: Entity): OrderedInternal
	local world_state = state.get(world)
	local existing = world_state.ordered[entity]
	if existing then
		return existing
	end
	local store = schema.get(world).ordered[entity]
	if store == nil then
		error(messages.errors.not_ordered(util.describe(world, entity)), 0)
	end
	local created = create_ordered(store, collection.get(world, store.collection).config)
	world_state.ordered[entity] = created
	return created
end

return table.freeze({
	get_ordered = get_ordered,
	is_ordered = is_ordered,
})
