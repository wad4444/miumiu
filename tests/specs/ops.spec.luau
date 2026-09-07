return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local ops = require(ReplicatedStorage.Packages.miumiu.ops)
	local utils = require(ReplicatedStorage.Tests.utils)

	local set = utils.set
	local add = utils.add

	local function replay(truth, stamps, list)
		return ops.replay({ truth = truth, stamps = stamps }, list)
	end

	describe("ops.replay", function()
		it("applies a newer set and records its stamp", function()
			local state = replay({}, {}, { set("money", 5, 10) })
			expect(state.truth.money).to.equal(5)
			expect(state.stamps.money).to.equal(10)
		end)

		it("drops a set older than the stamp", function()
			local state = replay({ money = 5 }, { money = 10 }, { set("money", 1, 9) })
			expect(state.truth.money).to.equal(5)
			expect(state.stamps.money).to.equal(10)
		end)

		it("keeps the existing value on a tie", function()
			local state = replay({ money = 5 }, { money = 10 }, { set("money", 1, 10) })
			expect(state.truth.money).to.equal(5)
		end)

		it("removes with the same stamp rule", function()
			local state = replay({ money = 5 }, { money = 10 }, { { kind = "remove", key = "money", at = 9 } })
			expect(state.truth.money).to.equal(5)
			state = ops.replay(state, { { kind = "remove", key = "money", at = 11 } })
			expect(state.truth.money).to.equal(nil)
			expect(state.stamps.money).to.equal(11)
		end)

		it("inits only when the key is absent, without a stamp", function()
			local state = replay({}, {}, { { kind = "init", key = "money", value = 100 } })
			expect(state.truth.money).to.equal(100)
			expect(state.stamps.money).to.equal(nil)
			local same = ops.replay(state, { { kind = "init", key = "money", value = 7 } })
			expect(same).to.equal(state)
			expect(same.truth.money).to.equal(100)
		end)

		it("adds, treating a missing value as zero", function()
			local state = replay({}, {}, { add("money", 3), add("money", -1) })
			expect(state.truth.money).to.equal(2)
		end)

		it("inserts, creating the array", function()
			local state = replay({}, {}, {
				{ kind = "insert", key = "items", value = "a" },
				{ kind = "insert", key = "items", value = "b" },
			})
			expect(table.concat(state.truth.items, ",")).to.equal("a,b")
		end)

		it("erases the first deep-equal element only", function()
			local state = replay({ items = { { id = 1 }, { id = 2 }, { id = 1 } } }, {}, {
				{ kind = "erase", key = "items", value = { id = 1 } },
			})
			expect(#state.truth.items).to.equal(2)
			expect(state.truth.items[1].id).to.equal(2)
			expect(state.truth.items[2].id).to.equal(1)
		end)

		it("erase is a no-op when absent", function()
			local state = replay({ items = { "a" } }, {}, {
				{ kind = "erase", key = "items", value = "z" },
				{ kind = "erase", key = "other", value = "z" },
			})
			expect(#state.truth.items).to.equal(1)
			expect(state.truth.other).to.equal(nil)
		end)

		it("puts and drops fields", function()
			local state = replay(
				{},
				{},
				{ { kind = "put", key = "settings", path = { "volume" }, at = 1, value = 0.5 } }
			)
			expect(state.truth.settings.volume).to.equal(0.5)
			state = ops.replay(state, {
				{ kind = "drop", key = "settings", path = { "volume" }, at = 2 },
				{ kind = "drop", key = "none", path = { "x" }, at = 2 },
			})
			expect(state.truth.settings.volume).to.equal(nil)
			expect(state.truth.none).to.equal(nil)
		end)

		it("puts and drops along nested paths, creating tables on the way", function()
			local state = replay({}, {}, {
				{ kind = "put", key = "inventory", path = { "a", "parts", "x" }, at = 1, value = { money = 1 } },
				{ kind = "put", key = "inventory", path = { "a", "money" }, at = 1, value = 3 },
			})
			expect(state.truth.inventory.a.parts.x.money).to.equal(1)
			expect(state.truth.inventory.a.money).to.equal(3)
			local before = state.truth.inventory.a
			state = ops.replay(state, {
				{ kind = "drop", key = "inventory", path = { "a", "parts", "x" }, at = 2 },
				{ kind = "drop", key = "inventory", path = { "b", "parts", "y" }, at = 2 },
				{ kind = "drop", key = "nothing", path = { "z" }, at = 2 },
			})
			expect(state.truth.inventory.a.parts.x).to.equal(nil)
			expect(state.truth.inventory.b).to.equal(nil)
			expect(state.truth.nothing).to.equal(nil)
			expect(before.parts.x).to.be.ok()
		end)

		it("stamps puts and drops per path and lets an ancestor put outrank them", function()
			local state = replay({}, {}, {
				{ kind = "put", key = "inventory", path = { "a", "parts", "x" }, at = 5, value = { money = 1 } },
			})
			expect(state.stamps["inventory/a/parts/x"]).to.equal(5)
			state = ops.replay(state, {
				{ kind = "put", key = "inventory", path = { "a", "parts", "x" }, at = 4, value = { money = 2 } },
			})
			expect(state.truth.inventory.a.parts.x.money).to.equal(1)
			state = ops.replay(state, {
				{ kind = "put", key = "inventory", path = { "a" }, at = 7, value = { money = 3 } },
				{ kind = "put", key = "inventory", path = { "a", "parts", "x" }, at = 6, value = { money = 4 } },
			})
			expect(state.truth.inventory.a.money).to.equal(3)
			expect(state.truth.inventory.a.parts).to.equal(nil)
			state = ops.replay(state, { { kind = "drop", key = "inventory", path = { "a" }, at = 7 } })
			expect(state.truth.inventory.a.money).to.equal(3)
			state = ops.replay(state, { { kind = "drop", key = "inventory", path = { "a" }, at = 8 } })
			expect(state.truth.inventory.a).to.equal(nil)
			expect(state.stamps["inventory/a"]).to.equal(8)
			expect(ops.path_floor(state.stamps, "inventory", { "a", "parts", "x" })).to.equal(8)
		end)

		it("orders a key's own stamp against its paths", function()
			local state = replay({}, {}, { set("settings", { volume = 1 }, 10) })
			state = ops.replay(state, {
				{ kind = "put", key = "settings", path = { "volume" }, at = 9, value = 2 },
			})
			expect(state.truth.settings.volume).to.equal(1)
			state = ops.replay(state, {
				{ kind = "put", key = "settings", path = { "volume" }, at = 11, value = 3 },
			})
			expect(state.truth.settings.volume).to.equal(3)
			expect(state.stamps["settings/volume"]).to.equal(11)
			state = ops.replay(state, { set("settings", { volume = 4 }, 12) })
			expect(state.truth.settings.volume).to.equal(4)
			expect(state.stamps["settings/volume"]).to.equal(nil)
			state = ops.replay(state, {
				{ kind = "put", key = "settings", path = { "volume" }, at = 11, value = 5 },
			})
			expect(state.truth.settings.volume).to.equal(4)
		end)

		it("clears the stamps under a path a put or drop replaces", function()
			local state = replay({}, {}, {
				{ kind = "put", key = "inventory", path = { "a", "parts", "x" }, at = 12, value = { money = 1 } },
			})
			state = ops.replay(state, {
				{ kind = "put", key = "inventory", path = { "a" }, at = 10, value = { money = 2 } },
			})
			expect(state.truth.inventory.a.money).to.equal(2)
			expect(state.stamps["inventory/a/parts/x"]).to.equal(nil)
			state = ops.replay(state, {
				{ kind = "put", key = "inventory", path = { "a", "parts", "x" }, at = 11, value = { money = 3 } },
			})
			expect(state.truth.inventory.a.parts.x.money).to.equal(3)
			state = ops.replay(state, { { kind = "drop", key = "inventory", path = { "a" }, at = 13 } })
			expect(state.stamps["inventory/a/parts/x"]).to.equal(nil)
			expect(state.stamps["inventory/a"]).to.equal(13)
		end)

		it("never mutates its inputs", function()
			local items = { "a" }
			local settings = { volume = 1 }
			local truth = { money = 1, items = items, settings = settings }
			local stamps = { money = 5 }
			local state = replay(truth, stamps, {
				set("money", 9, 10),
				{ kind = "insert", key = "items", value = "b" },
				{ kind = "put", key = "settings", path = { "volume" }, at = 1, value = 0 },
			})
			expect(truth.money).to.equal(1)
			expect(#items).to.equal(1)
			expect(settings.volume).to.equal(1)
			expect(stamps.money).to.equal(5)
			expect(state.truth.money).to.equal(9)
			expect(#state.truth.items).to.equal(2)
			expect(state.truth.settings.volume).to.equal(0)
			expect(state.stamps.money).to.equal(10)
		end)

		it("returns the same state when nothing applies", function()
			local input = { truth = { money = 5, items = { "a" } }, stamps = { money = 10 } }
			local state = ops.replay(input, {
				set("money", 1, 9),
				{ kind = "erase", key = "items", value = "z" },
				{ kind = "drop", key = "items", path = { "x" }, at = 0 },
			})
			expect(state).to.equal(input)
		end)

		it("clones a nested table once per key", function()
			local items = { "a" }
			local state = replay({ items = items }, {}, {
				{ kind = "insert", key = "items", value = "b" },
				{ kind = "insert", key = "items", value = "c" },
			})
			expect(table.concat(state.truth.items, ",")).to.equal("a,b,c")
			expect(state.truth.items).never.to.equal(items)
			expect(#items).to.equal(1)
		end)
	end)

	describe("ops.deep_equal", function()
		it("compares nested tables by value", function()
			expect(ops.deep_equal({ a = { 1, 2 } }, { a = { 1, 2 } })).to.equal(true)
			expect(ops.deep_equal({ a = { 1, 2 } }, { a = { 1, 3 } })).to.equal(false)
			expect(ops.deep_equal({ a = 1 }, { a = 1, b = 2 })).to.equal(false)
			expect(ops.deep_equal(1, "1")).to.equal(false)
		end)
	end)
end
