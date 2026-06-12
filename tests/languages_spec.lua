--- Tests for loomworks/languages.lua — the tracked-language set used
--- to filter cmake's `detect_languages()` output before it drives the
--- language-drift diagnostic.

package.loaded["loomworks.languages"] = nil
local languages = require("loomworks.languages")

describe("loomworks.languages", function()
    describe("tracked_set", function()
        it("includes languages declared by registered modules", function()
            local set = languages.tracked_set()
            -- cmake / meson / shell all declare c++
            assert.is_true(set["c++"])
            -- meson declares c
            assert.is_true(set["c"])
            -- typescript module declares typescript
            assert.is_true(set["typescript"])
        end)

        it("excludes things no module declares and no adapter maps", function()
            local set = languages.tracked_set()
            -- The whole reason this module exists: cmake enables RC
            -- under the hood on Windows for `.rc` files; loomworks has
            -- no routing for it, so the drift diagnostic shouldn't
            -- see it.
            assert.is_nil(set["rc"])
            assert.is_nil(set["asm"])
            assert.is_nil(set["ispc"])
        end)
    end)

    describe("filter", function()
        it("drops untracked entries and preserves order", function()
            local out = languages.filter({ "c++", "rc", "c", "asm" })
            assert.same({ "c++", "c" }, out)
        end)

        it("deduplicates", function()
            local out = languages.filter({ "c++", "c++", "c" })
            assert.same({ "c++", "c" }, out)
        end)

        it("returns an empty array for empty/nil input", function()
            assert.same({}, languages.filter({}))
            assert.same({}, languages.filter(nil))
        end)

        it("returns an empty array when every entry is untracked", function()
            assert.same({}, languages.filter({ "rc", "asm" }))
        end)
    end)
end)
