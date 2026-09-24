--- Tests for the advisory suggestion cache (loomworks.health_cache, §16.31).
--- Pure module: driven by an injected in-memory io so read/write, schema
--- versioning, and corruption resilience are all deterministic.

local health_cache = require("loomworks.health_cache")

local function mem_io()
    local store = {}
    return {
        store = store,
        read_json = function(path)
            local c = store[path]
            if not c then return nil, "enoent" end
            local ok, d = pcall(vim.json.decode, c)
            if ok then return d end
            return nil, "bad"
        end,
        write_json = function(path, tbl)
            local ok, enc = pcall(vim.json.encode, tbl)
            if not ok then return false, "encode" end
            store[path] = enc
            return true
        end,
        ensure_dir = function() return true end,
    }
end

describe("health_cache path", function()
    it("sits beside the build cache under .nvim/", function()
        assert.equals("/root/.nvim/loomworks.health.json", health_cache.path("/root"))
    end)
end)

describe("health_cache read resilience", function()
    it("returns an empty, well-formed cache when the file is missing", function()
        local io_dep = mem_io()
        local data = health_cache.read(io_dep, "/root")
        assert.equals(health_cache.SCHEMA_VERSION, data._meta.version)
        assert.is_nil(data.local_tier)
        assert.is_nil(data.network_tier)
    end)

    it("treats corrupt JSON as empty (never raises)", function()
        local io_dep = mem_io()
        io_dep.store[health_cache.path("/root")] = "{ not json"
        local data = health_cache.read(io_dep, "/root")
        assert.equals(health_cache.SCHEMA_VERSION, data._meta.version)
        assert.is_nil(data.local_tier)
    end)

    it("treats a schema-version mismatch as empty", function()
        local io_dep = mem_io()
        io_dep.store[health_cache.path("/root")] = vim.json.encode({
            _meta = { version = health_cache.SCHEMA_VERSION + 99 },
            local_tier = { items = { { title = "stale" } }, key = "x" },
        })
        local data = health_cache.read(io_dep, "/root")
        assert.is_nil(data.local_tier) -- discarded
    end)

    it("returns empty when the io has neither read_json nor read_file", function()
        local data = health_cache.read({ write_json = function() end }, "/root")
        assert.equals(health_cache.SCHEMA_VERSION, data._meta.version)
    end)

    it("falls back to read_file + decode when read_json is absent", function()
        local store = {}
        local io_dep = {
            read_file = function(path) return store[path] end,
            write_json = function() return true end,
        }
        store[health_cache.path("/root")] = vim.json.encode({
            _meta = { version = health_cache.SCHEMA_VERSION },
            local_tier = { items = { { title = "L" } }, key = "k", computed_at = 5 },
        })
        local data = health_cache.read(io_dep, "/root")
        assert.equals("k", data.local_tier.key)
        assert.equals(5, data.local_tier.computed_at)
    end)
end)

describe("health_cache write/read roundtrip", function()
    it("persists both tiers and stamps the schema version", function()
        local io_dep = mem_io()
        local ok = health_cache.write(io_dep, "/root", {
            local_tier = { items = { { title = "L" } }, computed_at = 10, key = "k1" },
            network_tier = { items = { { title = "N" } }, computed_at = 20 },
        })
        assert.is_true(ok)

        local data = health_cache.read(io_dep, "/root")
        assert.equals(health_cache.SCHEMA_VERSION, data._meta.version)
        assert.equals("k1", data.local_tier.key)
        assert.equals(10, data.local_tier.computed_at)
        assert.equals("L", data.local_tier.items[1].title)
        assert.equals(20, data.network_tier.computed_at)
        assert.equals("N", data.network_tier.items[1].title)
    end)

    it("normalizes a tier missing its items array to an empty list", function()
        local io_dep = mem_io()
        io_dep.store[health_cache.path("/root")] = vim.json.encode({
            _meta = { version = health_cache.SCHEMA_VERSION },
            local_tier = { key = "k" }, -- no items
        })
        local data = health_cache.read(io_dep, "/root")
        assert.same({}, data.local_tier.items)
        assert.equals("k", data.local_tier.key)
    end)

    it("reports failure when the io cannot write", function()
        local ok, err = health_cache.write({}, "/root", health_cache.empty())
        assert.is_false(ok)
        assert.is_string(err)
    end)
end)
