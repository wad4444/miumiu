return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local callbacks = require(ReplicatedStorage.Packages.miumiu.callbacks)
	local miumiu = require(ReplicatedStorage.Packages.miumiu)
	local utils = require(ReplicatedStorage.Tests.utils)

	afterEach(utils.cleanup)

	describe("callbacks", function()
		it("connects, fires in order with arguments, and disconnects", function()
			local registry = {}
			local seen = {}
			local disconnect = callbacks.connect(registry, miumiu.hooks.pulled, function(value)
				table.insert(seen, `a{value}`)
			end)
			callbacks.connect(registry, miumiu.hooks.pulled, function(value)
				table.insert(seen, `b{value}`)
			end)
			expect(callbacks.is_connected(registry, miumiu.hooks.pulled)).to.equal(true)
			expect(callbacks.is_connected(registry, miumiu.hooks.closed)).to.equal(false)
			callbacks.fire(registry, miumiu.hooks.pulled, "owner", 1)
			expect(table.concat(seen, ",")).to.equal("a1,b1")
			disconnect()
			disconnect()
			callbacks.fire(registry, miumiu.hooks.pulled, "owner", 2)
			expect(table.concat(seen, ",")).to.equal("a1,b1,b2")
			callbacks.fire(registry, miumiu.hooks.closed, "owner")
		end)

		it("warns instead of raising when a callback throws, and keeps firing the rest", function()
			local backend = utils.create_backend()
			local registry = {}
			local ran = false
			callbacks.connect(registry, miumiu.hooks.writing, function()
				error("hook boom", 0)
			end)
			callbacks.connect(registry, miumiu.hooks.writing, function()
				ran = true
			end)
			callbacks.fire(registry, miumiu.hooks.writing, "Session(k)")
			expect(ran).to.equal(true)
			expect(utils.warned(backend, "hook boom")).to.equal(true)
			expect(utils.warned(backend, "Session(k)")).to.equal(true)
		end)
	end)
end
