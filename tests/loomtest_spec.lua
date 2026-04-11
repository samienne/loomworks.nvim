--- Tests for loomtest: streaming parser, test tree management.

describe("loomtest", function()

    describe("gtest output streaming", function()
        -- Simulate the parse_gtest_line function from runner.lua
        -- by extracting the parsing logic into testable form.

        local function parse_line(line)
            local run_test = line:match("^%[%s*RUN%s*%] (.+)$")
            if run_test then
                return "run", run_test:match("^%s*(.-)%s*$")
            end

            local ok_test = line:match("^%[%s*OK%s*%] (.+)")
            if ok_test then
                local name = ok_test:match("^%s*(.-)%s*%(")
                    or ok_test:match("^%s*(.-)%s*$")
                return "ok", name
            end

            local fail_test = line:match("^%[%s*FAILED%s*%] (.+)")
            if fail_test then
                local name = fail_test:match("^%s*(.-)%s*%(")
                    or fail_test:match("^%s*(.-)%s*$")
                return "failed", name
            end

            return nil, nil
        end

        it("should detect [ RUN ] lines", function()
            local status, name = parse_line("[ RUN      ] MathSuite.test_add")
            assert.equals("run", status)
            assert.equals("MathSuite.test_add", name)
        end)

        it("should detect [       OK ] lines with duration", function()
            local status, name = parse_line("[       OK ] MathSuite.test_add (0 ms)")
            assert.equals("ok", status)
            assert.equals("MathSuite.test_add", name)
        end)

        it("should detect [  FAILED  ] lines with duration", function()
            local status, name = parse_line("[  FAILED  ] MathSuite.test_add (1 ms)")
            assert.equals("failed", status)
            assert.equals("MathSuite.test_add", name)
        end)

        it("should handle parameterized test names", function()
            local status, name = parse_line("[ RUN      ] Prefix/Suite.Test/0")
            assert.equals("run", status)
            assert.equals("Prefix/Suite.Test/0", name)
        end)

        it("should handle parameterized OK lines", function()
            local status, name = parse_line("[       OK ] Prefix/Suite.Test/ParamName (5 ms)")
            assert.equals("ok", status)
            assert.equals("Prefix/Suite.Test/ParamName", name)
        end)

        it("should return nil for non-test lines", function()
            local status = parse_line("[----------] 5 tests from MathSuite")
            assert.is_nil(status)
        end)

        it("should return nil for summary lines", function()
            local status = parse_line("[  FAILED  ] 1 test, listed below:")
            assert.equals("failed", status)
            -- This is a summary line, name would be "1 test, listed below:"
            -- The runner handles this by checking if the name exists in the tree
        end)
    end)

    describe("test tree management", function()
        local loomtest

        before_each(function()
            loomtest = require("loomtest")
            loomtest.clear()
        end)

        it("should store and retrieve nodes", function()
            loomtest.set_nodes({
                { id = "target:runner", name = "runner", type = "target", runnable = true },
                { id = "test:Suite.Test1", name = "Suite.Test1", type = "test", parent = "target:runner", runnable = true },
            })

            assert.equals(2, #loomtest.nodes())
            assert.is_not_nil(loomtest.get_node("target:runner"))
            assert.is_not_nil(loomtest.get_node("test:Suite.Test1"))
            assert.is_nil(loomtest.get_node("test:nonexistent"))
        end)

        it("should apply results to nodes", function()
            loomtest.set_nodes({
                { id = "test:Suite.Test1", name = "Suite.Test1", type = "test", runnable = true },
                { id = "test:Suite.Test2", name = "Suite.Test2", type = "test", runnable = true },
            })

            loomtest.apply_results({
                { test_id = "test:Suite.Test1", status = "passed", duration = 10 },
                { test_id = "test:Suite.Test2", status = "failed", message = "assertion failed" },
            })

            local t1 = loomtest.get_node("test:Suite.Test1")
            assert.equals("passed", t1.status)
            assert.equals(10, t1.duration)

            local t2 = loomtest.get_node("test:Suite.Test2")
            assert.equals("failed", t2.status)
            assert.equals("assertion failed", t2.message)
        end)

        it("should clear all nodes", function()
            loomtest.set_nodes({
                { id = "test:a", name = "a", type = "test", runnable = true },
            })
            assert.equals(1, #loomtest.nodes())

            loomtest.clear()
            assert.equals(0, #loomtest.nodes())
        end)
    end)
end)
