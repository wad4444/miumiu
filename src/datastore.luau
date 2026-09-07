local types = require("./types")

type DataStore = types.DataStore
type DataStoreGetOptions = types.DataStoreGetOptions
type DataStoreService = types.DataStoreService
type RetryConfig = types.RetryConfig
type UpdateResult<T> = types.UpdateResult<T>

local single_attempt: RetryConfig = table.freeze({ retry_attempts = 1, retry_base = 0 })

local fresh_options: DataStoreGetOptions? = nil

local function default_service(): DataStoreService
	return game:GetService("DataStoreService") :: any
end

local function get_fresh_options(): DataStoreGetOptions
	if fresh_options == nil then
		local options = Instance.new("DataStoreGetOptions")
		options.UseCache = false
		fresh_options = options :: any
	end
	return fresh_options :: DataStoreGetOptions
end

local function open(service: DataStoreService, name: string): DataStore
	return service:GetDataStore(name)
end

local function retry<T...>(retry_config: RetryConfig, fn: () -> T...): T...
	local attempts = math.max(1, retry_config.retry_attempts)
	local last_error: any = nil

	for attempt = 1, attempts do
		local result = table.pack(pcall(fn))
		if result[1] then
			return table.unpack(result, 2, result.n)
		end
		last_error = result[2]
		if attempt < attempts then
			task.wait(retry_config.retry_base * 2 ^ (attempt - 1))
		end
	end

	error(last_error, 0)
end

local function get_async(store: DataStore, key: string, retry_config: RetryConfig): any
	local options = get_fresh_options()
	return retry(retry_config, function()
		return (store:GetAsync(key, options))
	end)
end

local function set_async(store: DataStore, key: string, value: any, retry_config: RetryConfig, user_ids: { number }?)
	retry(retry_config, function()
		store:SetAsync(key, value, user_ids)
	end)
end

local function update_async<T>(
	store: DataStore,
	key: string,
	transform: (old: T?) -> T?,
	retry_config: RetryConfig,
	user_ids: { number }?
): UpdateResult<T>
	local result: UpdateResult<T> = { value = nil, written = false }
	local transform_error: any = nil

	retry(retry_config, function()
		store:UpdateAsync(key, function(old: T?)
			result = { value = old, written = false }
			transform_error = nil
			local ok, new = pcall(transform, old)
			if not ok then
				transform_error = new
				return nil
			end
			if new == nil then
				return nil
			end
			result = { value = new, written = true }
			return new, user_ids
		end)
	end)

	if transform_error ~= nil then
		error(transform_error, 0)
	end
	return result
end

return table.freeze({
	single_attempt = single_attempt,
	default_service = default_service,
	open = open,
	get_async = get_async,
	set_async = set_async,
	update_async = update_async,
})
