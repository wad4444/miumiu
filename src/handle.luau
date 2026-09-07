local types = require("./types")
local callbacks = require("./callbacks")
local hooks = require("./hooks")
local logging = require("./logging")
local messages = require("./messages")
local symbol = require("./symbol")

type BatchInternal = types.BatchInternal
type Callback = types.Callback
type Outcome = types.Outcome
type Symbol = types.Symbol

local batch_symbol = symbol.create_symbol("Batch")

local function get_outcome(self: BatchInternal): Outcome
	return self.internal_values.outcome
end

local function is_settled(self: BatchInternal): boolean
	return self.internal_values.outcome.kind ~= "pending"
end

local function hook(self: BatchInternal, hook_symbol: Symbol, callback: Callback): () -> ()
	local outcome = self.internal_values.outcome
	if outcome.kind == "landed" and hook_symbol == (hooks.landed :: any) then
		callbacks.invoke(self, hook_symbol, callback)
	elseif outcome.kind == "refused" and hook_symbol == (hooks.refused :: any) then
		callbacks.invoke(self, hook_symbol, callback, outcome.message)
	end
	return callbacks.connect(self.internal_hooks, hook_symbol, callback)
end

local function await(self: BatchInternal)
	if not is_settled(self) then
		table.insert(self.internal_waiters, coroutine.running())
		coroutine.yield()
	end
	local outcome = self.internal_values.outcome
	if outcome.kind == "refused" then
		error(outcome.message, 0)
	end
end

local function settle(self: BatchInternal, outcome: Outcome)
	if is_settled(self) then
		return
	end
	self.internal_values.outcome = outcome
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

local function land(self: BatchInternal)
	settle(self, { kind = "landed" })
end

local function refuse(self: BatchInternal, id: string, keys: { string }, message: string)
	settle(self, { kind = "refused", message = message })
	task.defer(function()
		local listeners = self.internal_hooks[hooks.refused]
		if listeners == nil or #listeners == 0 then
			logging.warn(messages.warnings.batch_refused(id, keys, message))
		end
	end)
end

local function is_batch(value: unknown): boolean
	return symbol.is_marked(value, batch_symbol)
end

local template = {
	symbol = batch_symbol,
	internal_values = {
		outcome = { kind = "pending" } :: Outcome,
	},
	internal_hooks = {},
	internal_waiters = {},
	get_outcome = get_outcome,
	is_settled = is_settled,
	hook = hook,
	await = await,
	land = land,
	refuse = refuse,
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
