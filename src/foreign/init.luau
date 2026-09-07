local types = require("./types")
local lapis = require("@self/lapis")

type Data = types.Data
type ForeignSource = types.ForeignSource

local adapters = table.freeze({
	lapis = lapis.read,
})

local function is_supported(kind: unknown): boolean
	return type(kind) == "string" and adapters[kind] ~= nil
end

local function read(foreign: ForeignSource, key: string): Data?
	return adapters[foreign.type](foreign, key)
end

return table.freeze({
	is_supported = is_supported,
	read = read,
})
