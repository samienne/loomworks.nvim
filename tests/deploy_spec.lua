local deploy = require("loomworks.deploy")

describe("deploy", function()
    describe("normalize_sources", function()
        it("wraps single descriptor in array", function()
            local result = deploy.normalize_sources({ project = "A", target = "t" })
            assert.equals(1, #result)
            assert.equals("A", result[1].project)
        end)

        it("returns array as-is", function()
            local arr = { { project = "A", target = "t" }, { project = "B", path = "x" } }
            local result = deploy.normalize_sources(arr)
            assert.equals(2, #result)
            assert.equals("B", result[2].project)
        end)
    end)

    describe("validate_deploy_definitions", function()
        it("accepts pre_build boolean field", function()
            local ok, err = deploy.validate_deploy_definitions({
                ["dest/"] = { project = "A", target = "t", pre_build = true },
            })
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("rejects non-boolean pre_build", function()
            local ok, err = deploy.validate_deploy_definitions({
                ["dest/"] = { project = "A", target = "t", pre_build = "yes" },
            })
            assert.is_false(ok)
            assert.is_not_nil(err)
            assert.matches("pre_build", err)
        end)

        it("accepts omitted pre_build (defaults false)", function()
            local ok = deploy.validate_deploy_definitions({
                ["dest/"] = { project = "A", target = "t" },
            })
            assert.is_true(ok)
        end)
    end)

    describe("partition_by_phase", function()
        it("returns empty dicts for nil input", function()
            local pre, post = deploy.partition_by_phase(nil)
            assert.are.same({}, pre)
            assert.are.same({}, post)
        end)

        it("puts pre_build sources in pre dict", function()
            local pre, post = deploy.partition_by_phase({
                ["dest/"] = { project = "A", target = "t", pre_build = true },
            })
            assert.equals(1, #pre["dest/"])
            assert.equals("A", pre["dest/"][1].project)
            assert.is_nil(post["dest/"])
        end)

        it("puts non-pre_build sources in post dict", function()
            local pre, post = deploy.partition_by_phase({
                ["dest/"] = { project = "A", target = "t" },
            })
            assert.is_nil(pre["dest/"])
            assert.equals(1, #post["dest/"])
        end)

        it("splits mixed array sources into both dicts", function()
            local pre, post = deploy.partition_by_phase({
                ["dest/"] = {
                    { project = "A", target = "t1", pre_build = true },
                    { project = "B", target = "t2" },
                },
            })
            assert.equals(1, #pre["dest/"])
            assert.equals("A", pre["dest/"][1].project)
            assert.equals(1, #post["dest/"])
            assert.equals("B", post["dest/"][1].project)
        end)
    end)

    describe("merge_deploy_sources", function()
        it("returns empty table when both inputs are nil", function()
            local merged = deploy.merge_deploy_sources(nil, nil)
            assert.are.same({}, merged)
        end)

        it("returns project-only when launch is nil", function()
            local merged = deploy.merge_deploy_sources(
                { ["dest/"] = { project = "A", target = "t" } }, nil)
            assert.equals(1, #merged["dest/"])
            assert.equals("A", merged["dest/"][1].project)
        end)

        it("returns launch-only when project is nil", function()
            local merged = deploy.merge_deploy_sources(
                nil, { ["dest/"] = { project = "A", target = "t" } })
            assert.equals(1, #merged["dest/"])
        end)

        it("unions sources for directory destination", function()
            local merged = deploy.merge_deploy_sources(
                { ["lib/"] = { project = "A", target = "libA" } },
                { ["lib/"] = { project = "B", target = "libB" } })
            assert.equals(2, #merged["lib/"])
            assert.equals("A", merged["lib/"][1].project)
            assert.equals("B", merged["lib/"][2].project)
        end)

        it("launch overrides project for file destination", function()
            local merged = deploy.merge_deploy_sources(
                { ["file.so"] = { project = "A", target = "t1" } },
                { ["file.so"] = { project = "B", target = "t2" } })
            assert.equals(1, #merged["file.so"])
            assert.equals("B", merged["file.so"][1].project)
        end)

        it("does not mutate input dicts", function()
            local project_deploy = { ["lib/"] = { project = "A", target = "libA" } }
            local launch_deploy = { ["lib/"] = { project = "B", target = "libB" } }
            deploy.merge_deploy_sources(project_deploy, launch_deploy)
            -- Original project deploy should still be single descriptor (not modified)
            assert.equals("A", project_deploy["lib/"].project)
        end)

        it("handles distinct destinations by including both", function()
            local merged = deploy.merge_deploy_sources(
                { ["a.so"] = { project = "A", target = "t1" } },
                { ["b.so"] = { project = "B", target = "t2" } })
            assert.equals("A", merged["a.so"][1].project)
            assert.equals("B", merged["b.so"][1].project)
        end)

        it("preserves pre_build flag through merge", function()
            local merged = deploy.merge_deploy_sources(
                { ["lib/"] = { project = "A", target = "t", pre_build = true } }, nil)
            assert.is_true(merged["lib/"][1].pre_build)
        end)
    end)
end)
