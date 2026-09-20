local types = require("../types")
local ops = require("../ops")
local util = require("../util")

type Data = types.Data
type LapisCollection = types.LapisCollection
type LapisLibrary = types.LapisLibrary
type LapisSource = types.LapisSource

local collections = setmetatable({} :: { [LapisLibrary]: { [string]: LapisCollection } }, { __mode = "k" })

local function get_collection(foreign: LapisSource): LapisCollection
	return util.cached(collections, foreign.source, foreign.name, function()
		return foreign.source.createCollection(foreign.name, foreign.options)
	end)
end

local function read(foreign: LapisSource, key: string): Data?
	local value = get_collection(foreign):read(key):expect()
	if type(value) ~= "table" then
		return nil
	end

	return ops.deep_copy(value)
end

return table.freeze({
	read = read,
})
