local types = require("./types")

type Warned = types.Warned

local function default_sink(message: string)
	warn(message)
end

local sink: (message: string) -> () = default_sink

local function warn_message(message: string)
	local ok = pcall(sink, message)
	if not ok then
		default_sink(message)
	end
end

local function warn_once(warned: Warned, once: string, message: string)
	if warned[once] then
		return
	end
	warned[once] = true
	warn_message(message)
end

local function set_warn(next_sink: ((message: string) -> ())?)
	sink = next_sink or default_sink
end

return table.freeze({
	warn = warn_message,
	warn_once = warn_once,
	set_warn = set_warn,
})
