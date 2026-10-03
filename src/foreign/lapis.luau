local types = require("../types")
local messages = require("../messages")
local ops = require("../ops")
local util = require("../util")

type Data = types.Data
type LapisCollection = types.LapisCollection
type LapisCreated = types.LapisCreated
type LapisLibrary = types.LapisLibrary
type LapisSource = types.LapisSource

local collections = setmetatable({} :: { [LapisLibrary]: { [string]: LapisCreated } }, { __mode = "k" })

local function get_collection(foreign: LapisSource): LapisCollection
	local created = util.cached(collections, foreign.source, foreign.name, function()
		return { collection = foreign.source.createCollection(foreign.name, foreign.options), options = foreign.options }
	end)
	if created.options ~= foreign.options then
		error(messages.errors.foreign_options_reused(foreign.name), 0)
	end

	return created.collection
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
