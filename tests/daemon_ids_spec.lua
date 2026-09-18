-- Opaque wire identity: monotonic, rename-stable (keyed by object identity),
-- session-local.

local ids = require("loomworks.daemon.ids")

describe("daemon.ids registry", function()
    it("assigns monotonic ids and is idempotent per object", function()
        local reg = ids.new()
        local a, b = { key = "A" }, { key = "B" }
        assert.equals(1, reg:id_for(a))
        assert.equals(2, reg:id_for(b))
        assert.equals(1, reg:id_for(a)) -- same object ⇒ same id
        assert.is_nil(reg:id_for(nil))
    end)

    it("keeps the same id across a rename (id follows the object, not the key)", function()
        local reg = ids.new()
        local p = { key = "old" }
        local id = reg:id_for(p)
        p.key = "new" -- a rename mutates the key in place; the table persists
        assert.equals(id, reg:id_for(p))
    end)

    it("builds a key/name → id index for a workspace", function()
        local reg = ids.new()
        local ws = {
            _profiles = { { key = "dev" }, { key = "rel" } },
            _projects = { { key = "App" } },
            _config_sets = { { name = "set1" } },
            _config_units = { { id = "build/App/Debug" } },
        }
        local idx = reg:index(ws)
        assert.is_number(idx.profiles.dev)
        assert.is_number(idx.profiles.rel)
        assert.is_number(idx.projects.App)
        assert.is_number(idx.config_sets.set1)
        assert.is_number(idx.config_units["build/App/Debug"])
        -- Re-indexing the SAME objects yields the SAME ids.
        local idx2 = reg:index(ws)
        assert.equals(idx.profiles.dev, idx2.profiles.dev)
    end)
end)
