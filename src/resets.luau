local types = require("./types")
local batch = require("./batch")
local capture = require("./capture")
local ids = require("./ids")
local jecs = require("./dependencies/jecs")
local logging = require("./logging")
local messages = require("./messages")
local rankings = require("./rankings")
local state = require("./state")

type Entity<T = nil> = types.Entity<T>
type Context = types.Context
type LinkState = types.LinkState
type OnPeriodChange = types.OnPeriodChange
type Placing = types.Placing
type SessionInternal = types.SessionInternal

local function receiver_of(context: Context, link_state: LinkState): Entity?
	local shallow = jecs.pair(ids.data_shallow, link_state.collection)
	for entity in link_state.entities do
		if not context.world:has(entity, shallow) then
			return entity
		end
	end
	return nil
end

local function run_one(context: Context, loaded: SessionInternal, entity: Entity, name: string, placing: Placing)
	local world = context.world
	local owed = rankings.owed_of(loaded:get_truth(), name)
	if owed == nil or owed.from ~= placing.from then
		loaded:forget_placing(name, placing, false)
		return
	end
	local on_period_change = placing.store.on_period_change :: OnPeriodChange
	local ok, err = pcall(function()
		local handle = batch.batch(world, function()
			for _, placed in placing.periods do
				on_period_change(world, entity, placed.value, placed.place, placed.period)
			end
			capture.record_ops(context, loaded, {
				rankings.field_op(loaded:get_state(), name, "owed", rankings.remaining(owed, placing.last), os.time()),
			})
		end)
		handle:silence()
	end)
	loaded:forget_placing(name, placing, not ok)
	if not ok then
		logging.warn(messages.warnings.period_change_failed(loaded:get_key(), name, err))
	end
end

local function run_all(context: Context)
	for _, by_key in context.world_state.link_states do
		for _, link_state in by_key do
			local loaded = state.open_session(link_state)
			if loaded == nil or next(loaded:get_placings()) == nil then
				continue
			end
			local entity = receiver_of(context, link_state)
			if entity == nil then
				continue
			end
			for name, placing in table.clone(loaded:get_placings()) do
				run_one(context, loaded, entity, name, placing)
			end
		end
	end
end

return table.freeze({
	run_all = run_all,
})
