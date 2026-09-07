return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local logging = require(ReplicatedStorage.Packages.miumiu.logging)

	describe("logging", function()
		it("routes to the sink and restores warn on nil", function()
			local captured = {}
			logging.set_warn(function(message)
				table.insert(captured, message)
			end)
			logging.warn("routed")
			expect(captured[1]).to.equal("routed")

			logging.set_warn(nil)
			logging.warn("to the console")
			expect(#captured).to.equal(1)
		end)

		it("falls back to warn when the sink throws", function()
			logging.set_warn(function()
				error("sink boom")
			end)
			expect(function()
				logging.warn("still delivered")
			end).never.to.throw()
			logging.set_warn(nil)
		end)
	end)
end
