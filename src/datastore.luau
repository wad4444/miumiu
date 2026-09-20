local types = require("./types")

type DataStore = types.DataStore
type DataStoreGetOptions = types.DataStoreGetOptions
type DataStorePages = types.DataStorePages
type DataStoreService = types.DataStoreService
type OrderedDataStore = types.OrderedDataStore
type RetryConfig = types.RetryConfig
type UpdateResult<T> = types.UpdateResult<T>

local single_attempt: RetryConfig = table.freeze({ retry_attempts = 1, retry_base = 0 })

local fresh_options: DataStoreGetOptions? = nil

local function get_default_service(): DataStoreService
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

local function set_async(store: DataStore, key: string, value: any, retry_config: RetryConfig)
	retry(retry_config, function()
		store:SetAsync(key, value)
	end)
end

local function update_async<T>(
	store: DataStore,
	key: string,
	transform: (old: T?) -> T?,
	retry_config: RetryConfig,
	user_ids: { number }?
): UpdateResult<T>
	local result: UpdateResult<T> = { kind = "unchanged", value = nil }
	local transform_error: any = nil

	retry(retry_config, function()
		store:UpdateAsync(key, function(old: T?)
			result = { kind = "unchanged", value = old }
			transform_error = nil
			local ok, new = pcall(transform, old)
			if not ok then
				transform_error = new
				return nil
			end
			if new == nil then
				return nil
			end
			result = { kind = "written", value = new }
			return new, user_ids
		end)
	end)

	if transform_error ~= nil then
		error(transform_error, 0)
	end

	return result
end

local function open_ordered(service: DataStoreService, name: string): OrderedDataStore
	return service:GetOrderedDataStore(name)
end

local function get_ordered(store: OrderedDataStore, key: string, retry_config: RetryConfig): any
	return retry(retry_config, function()
		return (store:GetAsync(key))
	end)
end

local function set_ordered(store: OrderedDataStore, key: string, value: number, retry_config: RetryConfig)
	retry(retry_config, function()
		store:SetAsync(key, value)
	end)
end

local function remove_ordered(store: OrderedDataStore, key: string, retry_config: RetryConfig)
	retry(retry_config, function()
		store:RemoveAsync(key)
	end)
end

local function get_sorted(
	store: OrderedDataStore,
	ascending: boolean,
	page_size: number,
	retry_config: RetryConfig
): DataStorePages
	return retry(retry_config, function()
		return (store:GetSortedAsync(ascending, page_size))
	end)
end

local function next_page(pages: DataStorePages, retry_config: RetryConfig)
	retry(retry_config, function()
		pages:AdvanceToNextPageAsync()
	end)
end

return table.freeze({
	single_attempt = single_attempt,
	get_default_service = get_default_service,
	open = open,
	get_async = get_async,
	set_async = set_async,
	update_async = update_async,
	open_ordered = open_ordered,
	get_ordered = get_ordered,
	set_ordered = set_ordered,
	remove_ordered = remove_ordered,
	get_sorted = get_sorted,
	next_page = next_page,
})
