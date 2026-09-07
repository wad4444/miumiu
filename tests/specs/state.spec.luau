return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local jecs = require(ReplicatedStorage.Packages.jecs)
	local state = require(ReplicatedStorage.Packages.miumiu.state)

	describe("state.get", function()
		it("returns one table per world", function()
			local world = jecs.world()
			local first = state.get(world)
			expect(state.get(world)).to.equal(first)
			expect(first.collections).to.be.ok()
		end)

		it("keeps worlds apart", function()
			local a = state.get(jecs.world())
			local b = state.get(jecs.world())
			expect(a).never.to.equal(b)
		end)
	end)
end
