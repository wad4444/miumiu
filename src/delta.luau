local types = require("./types")
local messages = require("./messages")

type Op = types.Op

local function reject(key: string, reason: string)
	error(messages.errors.not_a_delta(key, reason), 0)
end

local function is_array(value: { [any]: any }): boolean
	local count = 0
	for _ in value do
		count += 1
	end
	return count == #value
end

local function diff_arrays(key: string, previous: { any }, value: { any }): { Op }
	local result: { Op } = {}
	if #value >= #previous then
		for index = 1, #previous do
			if previous[index] ~= value[index] then
				reject(key, messages.reasons.in_place)
			end
		end
		for index = #previous + 1, #value do
			table.insert(result, { kind = "insert", key = key, value = value[index] })
		end
		return result
	end

	local cursor = 1
	for _, element in previous do
		if cursor <= #value and element == value[cursor] then
			cursor += 1
		else
			table.insert(result, { kind = "erase", key = key, value = element })
		end
	end
	if cursor ~= #value + 1 then
		reject(key, messages.reasons.in_place)
	end
	return result
end

local function diff_dictionaries(key: string, previous: { [string]: any }, value: { [string]: any }): { Op }
	local result: { Op } = {}
	local at = os.time()
	for field, entry in value do
		if type(field) ~= "string" then
			reject(key, messages.reasons.string_keys)
		end
		if previous[field] ~= entry then
			if string.find(field, "/", 1, true) then
				reject(key, messages.reasons.slash_keys)
			end
			table.insert(result, { kind = "put", key = key, path = { field }, value = entry, at = at })
		end
	end
	for field in previous do
		if value[field] == nil then
			if string.find(field, "/", 1, true) then
				reject(key, messages.reasons.slash_keys)
			end
			table.insert(result, { kind = "drop", key = key, path = { field }, at = at })
		end
	end
	return result
end

local function diff(key: string, previous: any, value: any): { Op }
	if value == nil then
		reject(key, messages.reasons.removed)
	end

	if type(value) == "number" then
		if previous ~= nil and type(previous) ~= "number" then
			reject(key, messages.reasons.type_changed)
		end
		local delta = value - (previous or 0)
		if delta == 0 then
			return {}
		end
		return { { kind = "add", key = key, delta = delta } }
	end

	if type(value) ~= "table" then
		reject(key, messages.reasons.not_a_table(type(value)))
	end
	if previous ~= nil and type(previous) ~= "table" then
		reject(key, messages.reasons.type_changed)
	end

	local before: { [any]: any } = previous or {}
	local before_array = is_array(before)
	local value_array = is_array(value)
	if next(before) == nil then
		before_array = value_array
	elseif next(value) == nil then
		value_array = before_array
	end
	if before_array ~= value_array then
		reject(key, messages.reasons.mixed)
	end

	if value_array then
		return diff_arrays(key, before, value)
	end
	return diff_dictionaries(key, before, value)
end

return table.freeze({
	diff = diff,
})
