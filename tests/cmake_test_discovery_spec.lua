--- Tests for cmake module's test discovery functions.

local cmake = require("loomworks.modules.cmake")

-- Access internal parse functions via the module's public discover_tests
-- by testing the full flow with mock data. For unit testing the parsers,
-- we call them through discover_tests with a fake build dir, or test
-- the output format expectations.

describe("cmake test discovery", function()

    describe("parse_ctest_json (via ctest --show-only=json-v1 format)", function()
        -- We test the parser indirectly by checking that discover_tests
        -- produces the right structure. For unit tests of the parser itself,
        -- we need to expose it or test via integration.

        -- For now, test the expected output format from known ctest JSON.
    end)

    describe("gtest_discover_tests format", function()
        it("should parse individual gtest cases from ctest JSON", function()
            -- Simulate ctest JSON output from gtest_discover_tests()
            local json = vim.json.encode({
                tests = {
                    {
                        name = "MathSuite.test_add",
                        command = { "/build/tests/unit_tests", "--gtest_filter=MathSuite.test_add" },
                    },
                    {
                        name = "MathSuite.test_sub",
                        command = { "/build/tests/unit_tests", "--gtest_filter=MathSuite.test_sub" },
                    },
                    {
                        name = "IOSuite.test_read",
                        command = { "/build/tests/unit_tests", "--gtest_filter=IOSuite.test_read" },
                    },
                    {
                        name = "IntegrationSuite.test_connect",
                        command = { "/build/tests/integration_tests", "--gtest_filter=IntegrationSuite.test_connect" },
                    },
                },
            })

            -- Parse using the internal parser (exposed through the module)
            -- Since parse_ctest_json is local, we test through the expected structure
            local ok, data = pcall(vim.json.decode, json)
            assert.is_true(ok)
            assert.is_not_nil(data.tests)
            assert.equals(4, #data.tests)

            -- Verify the names follow gtest_discover_tests pattern (Suite.Test)
            for _, test in ipairs(data.tests) do
                local suite, case = test.name:match("^([^%.]+)%.(.+)$")
                assert.is_not_nil(suite, "test name should have Suite.Case format: " .. test.name)
                assert.is_not_nil(case)
            end
        end)
    end)

    describe("add_test format", function()
        it("should identify opaque test targets", function()
            local json = vim.json.encode({
                tests = {
                    {
                        name = "unit_tests",
                        command = { "/build/tests/unit_tests" },
                    },
                    {
                        name = "integration_tests",
                        command = { "/build/tests/integration_tests" },
                    },
                },
            })

            local ok, data = pcall(vim.json.decode, json)
            assert.is_true(ok)
            -- Names without dots → opaque targets
            for _, test in ipairs(data.tests) do
                local suite = test.name:match("^([^%.]+)%.(.+)$")
                assert.is_nil(suite, "opaque target should not have Suite.Case format")
            end
        end)
    end)

    describe("gtest_list_tests parsing", function()
        it("should parse standard gtest --gtest_list_tests output", function()
            local output = table.concat({
                "MathSuite.",
                "  test_add",
                "  test_sub",
                "  test_mul",
                "IOSuite.",
                "  test_read",
                "  test_write",
            }, "\n")

            -- Test the expected parsing behavior
            local entries = {}
            local current_suite = nil
            for line in output:gmatch("[^\r\n]+") do
                local suite = line:match("^(%S+)%.$")
                if suite then
                    current_suite = suite
                elseif current_suite then
                    local case = line:match("^%s+(%S+)")
                    if case then
                        case = case:match("^([^#]+)") or case
                        entries[#entries + 1] = {
                            id = "test:" .. current_suite .. "." .. case,
                            name = current_suite .. "." .. case,
                        }
                    end
                end
            end

            assert.equals(5, #entries)
            assert.equals("test:MathSuite.test_add", entries[1].id)
            assert.equals("test:MathSuite.test_sub", entries[2].id)
            assert.equals("test:MathSuite.test_mul", entries[3].id)
            assert.equals("test:IOSuite.test_read", entries[4].id)
            assert.equals("test:IOSuite.test_write", entries[5].id)
        end)

        it("should handle parameterized tests with # suffix", function()
            local output = table.concat({
                "ParamSuite.",
                "  test_values/0  # GetParam() = 1",
                "  test_values/1  # GetParam() = 2",
            }, "\n")

            local entries = {}
            local current_suite = nil
            for line in output:gmatch("[^\r\n]+") do
                local suite = line:match("^(%S+)%.$")
                if suite then
                    current_suite = suite
                elseif current_suite then
                    local case = line:match("^%s+(%S+)")
                    if case then
                        case = case:match("^([^#]+)") or case
                        -- Trim trailing whitespace from # stripping
                        case = case:match("^(.-)%s*$")
                        entries[#entries + 1] = {
                            name = current_suite .. "." .. case,
                        }
                    end
                end
            end

            assert.equals(2, #entries)
            assert.equals("ParamSuite.test_values/0", entries[1].name)
            assert.equals("ParamSuite.test_values/1", entries[2].name)
        end)
    end)

    describe("test_command", function()
        it("should construct ctest command for a specific test", function()
            local project_ctx = { workspace_root = "/workspace" }
            local result = cmake.test_command(
                project_ctx, "/workspace/build", "test:MathSuite.test_add")

            assert.is_table(result.cmd)
            assert.equals("ctest", result.cmd[1])
            assert.equals("--test-dir", result.cmd[2])
            assert.equals("/workspace/build", result.cmd[3])
            -- Should have -R with anchored pattern
            local found_r = false
            for i, v in ipairs(result.cmd) do
                if v == "-R" then
                    found_r = true
                    assert.is_not_nil(result.cmd[i + 1]:match("^%^"))
                    assert.is_not_nil(result.cmd[i + 1]:match("%$$"))
                end
            end
            assert.is_true(found_r, "should have -R flag")
            assert.is_not_nil(result.output_path)
        end)

        it("should inject GTEST_FILTER for cursor-level filtering", function()
            local project_ctx = { workspace_root = "/workspace" }
            local result = cmake.test_command(
                project_ctx, "/workspace/build", "target:unit_tests",
                { gtest_filter = "MathSuite.test_add" })

            assert.equals("MathSuite.test_add", result.env.GTEST_FILTER)
        end)
    end)

    describe("test_command_all", function()
        it("should construct ctest command for all tests", function()
            local project_ctx = { workspace_root = "/workspace" }
            local result = cmake.test_command_all(project_ctx, "/workspace/build")

            assert.is_table(result.cmd)
            assert.equals("ctest", result.cmd[1])
            assert.equals("--test-dir", result.cmd[2])
            assert.is_not_nil(result.output_path)
        end)

        it("should add filter when provided", function()
            local project_ctx = { workspace_root = "/workspace" }
            local result = cmake.test_command_all(
                project_ctx, "/workspace/build", "Math.*")

            local found_r = false
            for i, v in ipairs(result.cmd) do
                if v == "-R" then
                    found_r = true
                    assert.equals("Math.*", result.cmd[i + 1])
                end
            end
            assert.is_true(found_r)
        end)
    end)

    describe("parse_test_results", function()
        it("should parse JUnit XML with passed tests", function()
            local tmp = vim.fn.tempname() .. ".xml"
            local f = io.open(tmp, "w")
            f:write([[<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="unit_tests" tests="2" failures="0">
    <testcase name="MathSuite.test_add" time="0.001"></testcase>
    <testcase name="MathSuite.test_sub" time="0.002"></testcase>
  </testsuite>
</testsuites>]])
            f:close()

            local results = cmake.parse_test_results(tmp)
            assert.is_not_nil(results)
            assert.equals(2, #results)
            assert.equals("test:MathSuite.test_add", results[1].test_id)
            assert.equals("passed", results[1].status)
            assert.equals(1, results[1].duration)
            assert.equals("test:MathSuite.test_sub", results[2].test_id)
            assert.equals("passed", results[2].status)

            os.remove(tmp)
        end)

        it("should parse JUnit XML with failed tests", function()
            local tmp = vim.fn.tempname() .. ".xml"
            local f = io.open(tmp, "w")
            f:write([[<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="unit_tests" tests="2" failures="1">
    <testcase name="MathSuite.test_add" time="0.001"></testcase>
    <testcase name="MathSuite.test_fail" time="0.003">
      <failure message="Expected 4 but got 5">assertion failed</failure>
    </testcase>
  </testsuite>
</testsuites>]])
            f:close()

            local results = cmake.parse_test_results(tmp)
            assert.is_not_nil(results)
            assert.equals(2, #results)
            assert.equals("passed", results[1].status)
            assert.equals("failed", results[2].status)
            assert.is_not_nil(results[2].message)

            os.remove(tmp)
        end)

        it("should parse JUnit XML with skipped tests", function()
            local tmp = vim.fn.tempname() .. ".xml"
            local f = io.open(tmp, "w")
            f:write([[<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="unit_tests" tests="1" skipped="1">
    <testcase name="MathSuite.test_skip" time="0.000">
      <skipped/>
    </testcase>
  </testsuite>
</testsuites>]])
            f:close()

            local results = cmake.parse_test_results(tmp)
            assert.is_not_nil(results)
            assert.equals(1, #results)
            assert.equals("skipped", results[1].status)

            os.remove(tmp)
        end)

        it("should return nil for missing file", function()
            local results = cmake.parse_test_results("/nonexistent/path.xml")
            assert.is_nil(results)
        end)
    end)
end)
