local stdio = require("@lune/stdio")

export type Block = { file: string, line: number }

local blocks: { Block } = {}
local hits: { [number]: boolean } = {}

local function register(file: string, line: number): number
	table.insert(blocks, { file = file, line = line })
	return #blocks
end

local function marker(file: string, line: number): string
	return `__cov({register(file, line)})`
end

local function blank(text: string): string
	return string.rep(" ", #text)
end

local function trim(text: string): string
	return string.match(text, "^%s*(.-)%s*$") or ""
end

local function mask(line: string): string
	local masked = string.gsub(line, "%[%[.-%]%]", blank)
	masked = string.gsub(masked, '"[^"]*"', blank)
	masked = string.gsub(masked, "'[^']*'", blank)
	masked = string.gsub(masked, "`[^`]*`", blank)
	masked = string.gsub(masked, "%-%-.*$", blank)
	return masked
end

local function exits(masked: string): boolean
	local trimmed = trim(masked)
	return string.match(trimmed, "^return") ~= nil
		or trimmed == "continue"
		or trimmed == "break"
		or string.match(trimmed, "^error%(") ~= nil
end

local function opens_tail(masked_lines: { string }, index: number): number?
	if trim(masked_lines[index]) ~= "end" then
		return nil
	end
	local previous = index - 1
	while previous > 0 and trim(masked_lines[previous]) == "" do
		previous -= 1
	end
	if previous == 0 or not exits(masked_lines[previous]) then
		return nil
	end
	local following = index + 1
	while masked_lines[following] and trim(masked_lines[following]) == "" do
		following += 1
	end
	local first = masked_lines[following]
	if not first or string.match(trim(first), "^[%)%}]") or string.match(trim(first), "^end") then
		return nil
	end
	if string.match(trim(first), "^else") or string.match(trim(first), "^until") then
		return nil
	end
	return following
end

local function paren_balance(text: string): number
	local balance = 0
	for character in string.gmatch(text, "[()]") do
		balance += if character == "(" then 1 else -1
	end
	return balance
end

local function ends_block(masked: string): boolean
	local trimmed = trim(masked)
	return trimmed == "else"
		or trimmed == "do"
		or trimmed == "then"
		or trimmed == "repeat"
		or string.match(trimmed, "%sthen$") ~= nil
		or string.match(trimmed, "%sdo$") ~= nil
end

local function one_liner(masked: string): number?
	local trimmed = trim(masked)
	if string.match(trimmed, "%send$") == nil then
		return nil
	end
	local _, finish = string.find(masked, "%sthen%s")
	return finish
end

local function function_header_end(masked_lines: { string }, index: number): number?
	local line = masked_lines[index]
	local start = string.find(line, "function%s*%(") or string.find(line, "function%s+[%w_.:]+%s*%(")
	if not start then
		return nil
	end
	local rest = string.sub(line, start)
	local balance = paren_balance(rest)
	if balance <= 0 and string.match(rest, "%send%s*[%),]*$") then
		return nil
	end
	local current = index
	while balance > 0 do
		current += 1
		local next_line = masked_lines[current]
		if not next_line then
			return nil
		end
		balance += paren_balance(next_line)
	end
	return current
end

local function instrument(source: string, file: string): string
	local lines = string.split(source, "\n")
	local masked_lines = table.create(#lines)
	for index, line in lines do
		masked_lines[index] = mask(line)
	end

	local prefixes: { [number]: string } = {}
	local suffixes: { [number]: string } = {}
	local inserts: { [number]: number } = {}

	for index, masked in masked_lines do
		if ends_block(masked) then
			suffixes[index] = ` {marker(file, index)}`
		else
			local at = one_liner(masked)
			if at then
				inserts[index] = at
			end
		end
		local tail = opens_tail(masked_lines, index)
		if tail and not prefixes[tail] and not suffixes[tail] and not inserts[tail] then
			prefixes[tail] = `{marker(file, tail)} `
		end
		local header_end = function_header_end(masked_lines, index)
		if header_end then
			local body = header_end + 1
			local first = masked_lines[body]
			local closes = first and string.match(trim(first), "^[%)%}]") ~= nil
			local ends = first and string.match(first, "^%s*end") ~= nil
			if first and not closes and not ends and not prefixes[body] and not suffixes[body] then
				prefixes[body] = `{marker(file, body)} `
			end
		end
	end

	local output = table.create(#lines)
	for index, line in lines do
		local prefix = prefixes[index]
		if prefix then
			local indent, rest = string.match(line, "^(%s*)(.*)$")
			line = `{indent}{prefix}{rest}`
		end
		local insert_at = inserts[index]
		if insert_at then
			line = `{string.sub(line, 1, insert_at)}{marker(file, index)} {string.sub(line, insert_at + 1)}`
		end
		output[index] = line .. (suffixes[index] or "")
	end
	return table.concat(output, "\n")
end

local function hit(id: number)
	hits[id] = true
end

local function report(): boolean
	local by_file: { [string]: { total: number, covered: number, missed: { number } } } = {}
	local files: { string } = {}
	for id, block in blocks do
		local entry = by_file[block.file]
		if not entry then
			entry = { total = 0, covered = 0, missed = {} }
			by_file[block.file] = entry
			table.insert(files, block.file)
		end
		entry.total += 1
		if hits[id] then
			entry.covered += 1
		else
			table.insert(entry.missed, block.line)
		end
	end
	table.sort(files)

	local total, covered = 0, 0
	for _, file in files do
		local entry = by_file[file]
		total += entry.total
		covered += entry.covered
		if #entry.missed > 0 then
			table.sort(entry.missed)
			local lines = {}
			for _, line in entry.missed do
				table.insert(lines, tostring(line))
			end
			stdio.write(`{file}: {entry.covered}/{entry.total} missed {table.concat(lines, " ")}\n`)
		end
	end
	local percent = if total == 0 then 100 else math.floor(covered / total * 10000) / 100
	stdio.write(`coverage: {covered}/{total} blocks ({percent}%)\n`)
	return covered == total
end

return table.freeze({
	instrument = instrument,
	hit = hit,
	report = report,
})
