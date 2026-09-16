return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local codec = require(ReplicatedStorage.Packages.miumiu.codec)
	local utils = require(ReplicatedStorage.Tests.utils)

	local function component(fields: { [string]: any }): any
		local entry =
			{ kind = "component", id = 1, key = "codes", initial = { kind = "none" }, lazy = false, holders = {} }
		for name, value in fields do
			entry[name] = value
		end
		return entry
	end

	local tag: any = { kind = "tag", id = 1, key = "tutorial", initial = { kind = "none" }, holders = {} }

	describe("codec.stored_form and codec.runtime_form", function()
		it("pass values through without serdes and convert with one", function()
			local plain = component({})
			expect(codec.stored_form(plain, 5)).to.equal(5)
			expect(codec.runtime_form(plain, 5)).to.equal(5)
			local with = component({ serdes = utils.create_set_serdes() })
			local stored = codec.stored_form(with, { b = true, a = true })
			expect(stored[1]).to.equal("a")
			expect(stored[2]).to.equal("b")
			expect(codec.runtime_form(with, { "a" }).a).to.equal(true)
			expect(codec.stored_form(with, nil)).to.equal(nil)
			expect(codec.stored_form(tag, true)).to.equal(true)
		end)

		it("rejects a serialize that returns nil or yields", function()
			local returning_nil = component({
				serdes = {
					serialize = function()
						return nil
					end,
					deserialize = function(value)
						return value
					end,
				},
			})
			expect(function()
				codec.stored_form(returning_nil, {})
			end).to.throw("returned nil")
			local yielding = component({
				serdes = {
					serialize = function()
						task.wait()
					end,
					deserialize = function(value)
						return value
					end,
				},
			})
			expect(function()
				codec.stored_form(yielding, {})
			end).to.throw("yielded")
		end)
	end)

	describe("codec.check_guard", function()
		it("accepts without a guard, reports a rejection reason, and reports a throw", function()
			expect(codec.check_guard(component({}), 1).kind).to.equal("ok")
			local guarded = component({
				guard = function(value)
					return type(value) == "number", "must be a number"
				end,
			})
			expect(codec.check_guard(guarded, 1).kind).to.equal("ok")
			local rejected = codec.check_guard(guarded, "x")
			assert(rejected.kind == "rejected")
			expect(rejected.reason).to.equal("must be a number")
			local throwing = component({
				guard = function()
					error("guard boom", 0)
				end,
			})
			local thrown = codec.check_guard(throwing, 1)
			assert(thrown.kind == "rejected")
			expect((string.find(thrown.reason :: string, "guard boom", 1, true))).to.be.ok()
		end)
	end)

	describe("codec.op_for", function()
		it("maps tags to booleans, removals to remove, and sets through the stored form", function()
			expect((codec.op_for(tag, "added", nil) :: any).value).to.equal(true)
			expect((codec.op_for(tag, "removed", nil) :: any).value).to.equal(false)
			local entry = component({ serdes = utils.create_set_serdes() })
			expect(codec.op_for(entry, "removed", nil).kind).to.equal("remove")
			local set = codec.op_for(entry, "changed", { a = true })
			assert(set.kind == "set")
			expect(set.key).to.equal("codes")
			expect(set.value[1]).to.equal("a")
			expect(set.at <= os.time()).to.equal(true)
		end)
	end)
end
