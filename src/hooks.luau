local types = require("./types")
local symbol = require("./symbol")

type ClosedHook = types.ClosedHook
type LandedHook = types.LandedHook
type PulledHook = types.PulledHook
type RefusedHook = types.RefusedHook
type WritingHook = types.WritingHook

return table.freeze({
	pulled = symbol.create_symbol("pulled") :: PulledHook,
	closed = symbol.create_symbol("closed") :: ClosedHook,
	writing = symbol.create_symbol("writing") :: WritingHook,
	landed = symbol.create_symbol("landed") :: LandedHook,
	refused = symbol.create_symbol("refused") :: RefusedHook,
})
