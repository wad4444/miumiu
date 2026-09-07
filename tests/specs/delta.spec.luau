return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local types = require(ReplicatedStorage.Packages.miumiu.types)
	local delta = require(ReplicatedStorage.Packages.miumiu.delta)

	type Op = types.Op

	local function delta_of(op: Op): number
		assert(op.kind == "add")
		return op.delta
	end

	local function value_of(op: Op): any
		assert(op.kind == "insert" or op.kind == "erase")
		return op.value
	end

	local function field_of(op: Op): string
		assert(op.kind == "put" or op.kind == "drop")
		return op.path[1]
	end

	describe("delta.diff", function()
		it("turns a number change into add", function()
			local result = delta.diff("money", 10, 15)
			expect(#result).to.equal(1)
			expect(result[1].kind).to.equal("add")
			expect(delta_of(result[1])).to.equal(5)
		end)

		it("yields nothing for an unchanged number", function()
			expect(#delta.diff("money", 10, 10)).to.equal(0)
		end)

		it("adds from zero when there was no value", function()
			expect(delta_of(delta.diff("money", nil, 7)[1])).to.equal(7)
		end)

		it("turns appended elements into inserts", function()
			local result = delta.diff("items", { "a" }, { "a", "b", "c" })
			expect(#result).to.equal(2)
			expect(result[1].kind).to.equal("insert")
			expect(value_of(result[1])).to.equal("b")
			expect(value_of(result[2])).to.equal("c")
		end)

		it("turns missing elements into erases", function()
			local result = delta.diff("items", { "a", "b", "c" }, { "b" })
			expect(#result).to.equal(2)
			expect(result[1].kind).to.equal("erase")
			expect(value_of(result[1])).to.equal("a")
			expect(value_of(result[2])).to.equal("c")
		end)

		it("inserts everything when there was no array", function()
			expect(#delta.diff("items", nil, { "a", "b" })).to.equal(2)
		end)

		it("compares elements by reference", function()
			local sword = { id = "sword" }
			local kept = delta.diff("items", { sword }, { sword, { id = "bow" } })
			expect(#kept).to.equal(1)
			expect(kept[1].kind).to.equal("insert")
			expect(function()
				delta.diff("items", { sword }, { { id = "sword" }, { id = "bow" } })
			end).to.throw("not a delta")
		end)

		it("rejects an element changed in place", function()
			expect(function()
				delta.diff("items", { "a", "b" }, { "a", "x" })
			end).to.throw("not a delta")
			expect(function()
				delta.diff("items", { "a", "b", "c" }, { "c", "a" })
			end).to.throw("not a delta")
		end)

		it("turns dictionary changes into put and drop", function()
			local result = delta.diff("settings", { volume = 1, muted = false }, { volume = 0.5, theme = "dark" })
			expect(#result).to.equal(3)
			local kinds = {}
			for _, op in result do
				kinds[field_of(op)] = op.kind
			end
			expect(kinds.volume).to.equal("put")
			expect(kinds.theme).to.equal("put")
			expect(kinds.muted).to.equal("drop")
		end)

		it("puts every field when there was no dictionary", function()
			expect(#delta.diff("settings", nil, { a = 1, b = 2 })).to.equal(2)
		end)

		it("accepts an empty table on either side", function()
			expect(delta.diff("items", {}, { "a" })[1].kind).to.equal("insert")
			expect(delta.diff("items", { "a" }, {})[1].kind).to.equal("erase")
			expect(delta.diff("settings", {}, { a = 1 })[1].kind).to.equal("put")
		end)

		it("rejects non-string dictionary keys and shape changes", function()
			expect(function()
				delta.diff("settings", {}, { [2] = "x" })
			end).to.throw("dictionary keys must be strings")
			expect(function()
				delta.diff("money", "text", 5)
			end).to.throw("type changed")
			expect(function()
				delta.diff("items", 5, {})
			end).to.throw("type changed")
		end)

		it("rejects removal, non-table values and mixed shapes", function()
			expect(function()
				delta.diff("money", 1, nil)
			end).to.throw("not a delta")
			expect(function()
				delta.diff("money", 1, "one")
			end).to.throw("not a delta")
			expect(function()
				delta.diff("flag", false, true)
			end).to.throw("not a delta")
			expect(function()
				delta.diff("items", { "a" }, { a = 1 })
			end).to.throw("not a delta")
		end)
	end)
end
