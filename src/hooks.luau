local types = require("./types")
local symbol = require("./symbol")

type ClosedHook = types.ClosedHook
type PulledHook = types.PulledHook
type WritingHook = types.WritingHook

return table.freeze({
	pulled = symbol.create_symbol("pulled") :: PulledHook,
	closed = symbol.create_symbol("closed") :: ClosedHook,
	writing = symbol.create_symbol("writing") :: WritingHook,
})
