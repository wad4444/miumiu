return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local datastore = require(ReplicatedStorage.Packages.miumiu.datastore)
	local utils = require(ReplicatedStorage.Tests.utils)

	afterEach(utils.cleanup)

	local retry = { retry_attempts = utils.timings.retry_attempts, retry_base = utils.timings.retry_base }
	local no_retry = { retry_attempts = 1, retry_base = 0 }

	describe("datastore.get_async", function()
		it("returns nil for a missing key", function()
			local backend = utils.create_backend()
			expect(datastore.get_async(utils.open_store(backend), "missing", no_retry)).to.equal(nil)
		end)

		it("reads past the cache every time", function()
			local backend = utils.create_backend()
			datastore.get_async(utils.open_store(backend), "k", no_retry)
			datastore.get_async(utils.open_store(backend), "k", no_retry)
			expect(backend.fresh_reads).to.equal(2)
		end)

		it("returns the stored value", function()
			local backend = utils.create_backend()
			backend:seed("k", { data = { money = 5 } })
			expect(datastore.get_async(utils.open_store(backend), "k", no_retry).data.money).to.equal(5)
		end)

		it("retries a failing call", function()
			local backend = utils.create_backend()
			backend:seed("k", { data = {} })
			backend:fail_next("GetAsync", "before")
			expect(datastore.get_async(utils.open_store(backend), "k", retry).data).to.be.ok()
			expect(backend.calls.GetAsync).to.equal(2)
		end)

		it("throws the last error once attempts run out", function()
			local backend = utils.create_backend()
			backend:fail_next("GetAsync", "before", "boom 1")
			backend:fail_next("GetAsync", "before", "boom 2")
			expect(function()
				datastore.get_async(utils.open_store(backend), "k", { retry_attempts = 2, retry_base = 0 })
			end).to.throw("boom 2")
			expect(backend.calls.GetAsync).to.equal(2)
		end)
	end)

	describe("datastore.update_async", function()
		it("writes what the transform returns", function()
			local backend = utils.create_backend()
			local result = datastore.update_async(utils.open_store(backend), "k", function(old)
				expect(old).to.equal(nil)
				return { data = { money = 1 } }
			end, no_retry)
			expect(result.kind).to.equal("written")
			expect(result.value.data.money).to.equal(1)
			expect(backend:dump("k").data.money).to.equal(1)
		end)

		it("cancels when the transform returns nil", function()
			local backend = utils.create_backend()
			backend:seed("k", { data = { money = 7 } })
			local result = datastore.update_async(utils.open_store(backend), "k", function()
				return nil
			end, no_retry)
			expect(result.kind).to.equal("unchanged")
			expect(result.value.data.money).to.equal(7)
			expect(backend:dump("k").data.money).to.equal(7)
		end)

		it("retries a failing call and writes once", function()
			local backend = utils.create_backend()
			backend:fail_next("UpdateAsync", "before")
			local calls = 0
			local result = datastore.update_async(utils.open_store(backend), "k", function()
				calls += 1
				return { data = { calls = calls } }
			end, retry)
			expect(result.kind).to.equal("written")
			expect(calls).to.equal(1)
			expect(backend.calls.UpdateAsync).to.equal(2)
		end)

		it("rethrows a transform error without retrying or writing", function()
			local backend = utils.create_backend()
			backend:seed("k", { data = { money = 7 } })
			local calls = 0
			expect(function()
				datastore.update_async(utils.open_store(backend), "k", function()
					calls += 1
					error("bad transform")
				end, retry)
			end).to.throw("bad transform")
			expect(calls).to.equal(1)
			expect(backend.calls.UpdateAsync).to.equal(1)
			expect(backend:dump("k").data.money).to.equal(7)
		end)
	end)

	describe("datastore.get_default_service", function()
		it("asks the game for DataStoreService", function()
			expect(datastore.get_default_service()).to.be.ok()
		end)
	end)
end
