local luau = require("@lune/luau")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local coverage = require("./coverage")

local cases = {
	{
		name = "a one-line if as the first statement keeps the body marker, the then marker and the tail after the function",
		source = "local function one(x)\n\tif x then return 1 end\n\treturn 2\nend\nreturn one",
		markers = 3,
	},
	{
		name = "a one-line if after an early exit gets the tail marker and the then marker",
		source = "local function two(x)\n\tif x then\n\t\treturn 1\n\tend\n\tif x then return 2 end\n\treturn 3\nend\nreturn two",
		markers = 5,
	},
	{
		name = "a header spanning lines marks the body after its closing paren and the tail after the function",
		source = "local function three(\n\ta,\n\tb\n)\n\treturn a + b\nend\nreturn three",
		markers = 2,
	},
	{
		name = "a multi-line if as the first statement keeps the body marker and the then marker",
		source = "local function four(x)\n\tif x then\n\t\treturn 1\n\tend\n\treturn 2\nend\nreturn four",
		markers = 4,
	},
	{
		name = "strings and comments holding keywords are masked",
		source = 'local function five(x)\n\tlocal text = "if x then end"\n\treturn text -- if x then\nend\nreturn five',
		markers = 2,
	},
}

local failures = 0
for _, case in cases do
	local instrumented = coverage.instrument(case.source, "check")
	local _, markers = string.gsub(instrumented, "__cov%(", "")
	local compiled, err = pcall(luau.compile, instrumented)
	if not compiled then
		failures += 1
		stdio.ewrite(`{case.name}: instrumented source does not compile: {err}\n{instrumented}\n`)
	elseif markers ~= case.markers then
		failures += 1
		stdio.ewrite(`{case.name}: expected {case.markers} markers, got {markers}\n{instrumented}\n`)
	end
end

if failures > 0 then
	stdio.ewrite(`coverage instrumenter: {failures} case(s) failed\n`)
	process.exit(1)
end
stdio.write(`coverage instrumenter: {#cases} cases ok\n`)
