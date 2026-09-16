local types = require("./types")
local callbacks = require("./callbacks")
local hooks = require("./hooks")
local logging = require("./logging")
local messages = require("./messages")
local symbol = require("./symbol")

type BatchInternal = types.BatchInternal
type BatchPhase = types.BatchPhase
type Callback = types.Callback
type Outcome = types.Outcome
type SettledOutcome = types.SettledOutcome
type Symbol = types.Symbol

local batch_symbol = symbol.create_symbol("Batch")

local function get_outcome(self: BatchInternal): Outcome
	return self.internal_values.outcome
end

local function get_result(self: BatchInternal): any
	local phase = self.internal_values.phase
	return if phase.kind == "held" then phase.result else nil
end

local function get_keys(self: BatchInternal): { string }
	return self.internal_keys
end

local function is_settled(self: BatchInternal): boolean
	return self.internal_values.outcome.kind ~= "pending"
end

local function hook(self: BatchInternal, hook_symbol: Symbol, callback: Callback): () -> ()
	local outcome = self.internal_values.outcome
	if outcome.kind == "landed" and hook_symbol == (hooks.landed :: any) then
		callbacks.invoke(hook_symbol, self, callback)
	elseif outcome.kind == "refused" and hook_symbol == (hooks.refused :: any) then
		callbacks.invoke(hook_symbol, self, callback, outcome.message)
	end
	return callbacks.connect(self.internal_hooks, hook_symbol, callback)
end

local function await(self: BatchInternal): SettledOutcome
	local values = self.internal_values
	if values.phase.kind == "running" then
		error(messages.errors.batch_awaited_inside(), 0)
	end
	values.awaited = true
	local flush = values.flush
	if flush ~= nil and not is_settled(self) then
		values.flush = nil
		flush()
	end
	if not is_settled(self) then
		table.insert(self.internal_waiters, coroutine.running())
		coroutine.yield()
	end
	return self.internal_values.outcome :: SettledOutcome
end

local function flush_with(self: BatchInternal, flush: () -> ())
	self.internal_values.flush = flush
end

local function settle(self: BatchInternal, outcome: Outcome)
	if is_settled(self) then
		return
	end
	self.internal_values.outcome = table.freeze(outcome)
	self.internal_values.flush = nil
	if outcome.kind == "refused" then
		callbacks.fire(self.internal_hooks, hooks.refused, self, outcome.message)
	else
		callbacks.fire(self.internal_hooks, hooks.landed, self)
	end
	local waiters = table.clone(self.internal_waiters)
	table.clear(self.internal_waiters)
	for _, waiter in waiters do
		if coroutine.status(waiter) == "suspended" then
			task.spawn(waiter)
		end
	end
end

local function enter(self: BatchInternal)
	self.internal_values.phase = { kind = "running" }
end

local function hold(self: BatchInternal, result: any, keys: { string })
	self.internal_values.phase = { kind = "held", result = result }
	self.internal_keys = table.freeze(table.clone(keys))
end

local function land(self: BatchInternal)
	settle(self, { kind = "landed" })
end

local function refuse(self: BatchInternal, id: string, message: string, heard: boolean)
	settle(self, { kind = "refused", message = message })
	task.defer(function()
		if
			not heard
			and not self.internal_values.awaited
			and not callbacks.is_connected(self.internal_hooks, hooks.refused)
		then
			logging.warn(messages.warnings.batch_refused(id, self.internal_keys, message))
		end
	end)
end

local function is_batch(value: unknown): boolean
	return symbol.is_marked(value, batch_symbol)
end

local template = {
	symbol = batch_symbol,
	internal_values = {
		outcome = table.freeze({ kind = "pending" }) :: Outcome,
		phase = table.freeze({ kind = "held", result = nil }) :: BatchPhase,
		awaited = false,
		flush = nil :: (() -> ())?,
	},
	internal_hooks = {},
	internal_waiters = {},
	internal_keys = table.freeze({}),
	get_outcome = get_outcome,
	get_result = get_result,
	get_keys = get_keys,
	is_settled = is_settled,
	hook = hook,
	await = await,
	enter = enter,
	hold = hold,
	land = land,
	refuse = refuse,
	flush_with = flush_with,
}

local meta = {
	__tostring = function(self: BatchInternal)
		return `Batch({self.internal_values.outcome.kind})`
	end,
}

local function create_batch(): BatchInternal
	local batch = table.clone(template)
	batch.internal_values = table.clone(template.internal_values)
	batch.internal_hooks = {}
	batch.internal_waiters = {}
	setmetatable(batch, meta)
	return batch :: BatchInternal
end

return table.freeze({
	create_batch = create_batch,
	is_batch = is_batch,
})
