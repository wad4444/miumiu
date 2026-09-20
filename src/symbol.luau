local types = require("./types")

type Symbol = types.Symbol

local function create_symbol(name: string): Symbol
	local symbol = newproxy(true)
	local meta = getmetatable(symbol)
	meta.__tostring = function()
		return `Symbol({name})`
	end

	return symbol
end

local function is_marked(value: unknown, mark: Symbol): boolean
	return type(value) == "table" and (value :: any).symbol == mark
end

return table.freeze({
	create_symbol = create_symbol,
	is_marked = is_marked,
})
