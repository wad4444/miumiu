local types = require("./types")
local logging = require("./logging")
local messages = require("./messages")

type Callback = types.Callback
type CallbackRegistry = types.CallbackRegistry
type Symbol = types.Symbol

local function connect(registry: CallbackRegistry, hook: Symbol, callback: Callback): () -> ()
	local callbacks = registry[hook]
	if not callbacks then
		callbacks = {}
		registry[hook] = callbacks
	end
	table.insert(callbacks, callback)
	return function()
		local index = table.find(callbacks, callback)
		if index then
			table.remove(callbacks, index)
		end
	end
end

local function invoke(owner: unknown, hook: Symbol, callback: Callback, ...: any)
	local ok, err = pcall(callback, ...)
	if not ok then
		logging.warn(messages.warnings.hook_failed(owner, hook, err))
	end
end

local function fire(registry: CallbackRegistry, hook: Symbol, owner: unknown, ...: any)
	local callbacks = registry[hook]
	if not callbacks then
		return
	end
	for _, callback in table.clone(callbacks) do
		invoke(owner, hook, callback, ...)
	end
end

return table.freeze({
	connect = connect,
	invoke = invoke,
	fire = fire,
})
