--- Tests for test integration: GTest helper and CTestUnit.

local gtest = require("loomworks.gtest")

describe("gtest helper", function()

    describe("parse_list_tests", function()
        it("should parse standard --gtest_list_tests output", function()
            local output = table.concat({
                "MathSuite.",
                "  test_add",
                "  test_sub",
                "  test_mul",
                "IOSuite.",
                "  test_read",
                "  test_write",
            }, "\n")

            local entries = gtest.parse_list_tests(output, "/build/test_runner", "target:test_runner")
            assert.equals(5, #entries)
            assert.equals("test:MathSuite.test_add", entries[1].id)
            assert.equals("MathSuite.test_add", entries[1].name)
            assert.equals("target:test_runner", entries[1].parent)
            assert.equals("gtest", entries[1].framework)
            assert.equals("test:IOSuite.test_read", entries[4].id)
        end)

        it("should handle parameterized tests with # suffix", function()
            local output = table.concat({
                "ParamSuite.",
                "  test_values/0  # GetParam() = 1",
                "  test_values/1  # GetParam() = 2",
            }, "\n")

            local entries = gtest.parse_list_tests(output, "/build/runner", "target:runner")
            assert.equals(2, #entries)
            assert.equals("ParamSuite.test_values/0", entries[1].name)
            assert.equals("ParamSuite.test_values/1", entries[2].name)
        end)
    end)

    describe("find_source_locations", function()
        it("should match TEST macros to entries", function()
            local tmp = vim.fn.tempname() .. ".cpp"
            local f = io.open(tmp, "w")
            f:write("#include <gtest/gtest.h>\n")
            f:write("TEST(MathSuite, test_add) { EXPECT_EQ(2, 1+1); }\n")
            f:write("TEST_F(MathSuite, test_sub) { EXPECT_EQ(0, 1-1); }\n")
            f:close()

            local entries = {
                { id = "test:MathSuite.test_add", name = "MathSuite.test_add" },
                { id = "test:MathSuite.test_sub", name = "MathSuite.test_sub" },
            }
            gtest.find_source_locations(entries, { tmp })

            assert.is_not_nil(entries[1].file)
            assert.equals(2, entries[1].line)
            assert.is_not_nil(entries[2].file)
            assert.equals(3, entries[2].line)

            os.remove(tmp)
        end)

        it("should match custom macros like UNIT_TEST", function()
            local tmp = vim.fn.tempname() .. ".cpp"
            local f = io.open(tmp, "w")
            f:write('#include "test.h"\n')
            f:write("UNIT_TEST(API_MySuite, DoSomething, TestSize.Level1)\n")
            f:write("UNIT_TEST_F(API_MySuite, DoOther, TestSize.Level1)\n")
            f:close()

            local entries = {
                { id = "test:API_MySuite.DoSomething", name = "API_MySuite.DoSomething" },
                { id = "test:API_MySuite.DoOther", name = "API_MySuite.DoOther" },
            }
            gtest.find_source_locations(entries, { tmp })

            assert.is_not_nil(entries[1].file)
            assert.equals(2, entries[1].line)
            assert.is_not_nil(entries[2].file)
            assert.equals(3, entries[2].line)

            os.remove(tmp)
        end)

        it("should handle multi-line macros", function()
            local tmp = vim.fn.tempname() .. ".cpp"
            local f = io.open(tmp, "w")
            f:write("UNIT_TEST_P(\n")
            f:write("    API_MySuite, LongTestName, TestSize.Level1)\n")
            f:write("{\n")
            f:write("    // test body\n")
            f:write("}\n")
            f:close()

            local entries = {
                { id = "test:API_MySuite.LongTestName", name = "API_MySuite.LongTestName" },
            }
            gtest.find_source_locations(entries, { tmp })

            assert.is_not_nil(entries[1].file)
            assert.equals(1, entries[1].line)

            os.remove(tmp)
        end)

        it("should match parameterized tests via base name", function()
            local tmp = vim.fn.tempname() .. ".cpp"
            local f = io.open(tmp, "w")
            f:write("TEST_P(MySuite, MyTest) { }\n")
            f:write("INSTANTIATE_TEST_SUITE_P(MyPrefix, MySuite, testing::Values(1,2));\n")
            f:close()

            local entries = {
                { id = "test:MyPrefix/MySuite.MyTest/0", name = "MyPrefix/MySuite.MyTest/0" },
                { id = "test:MyPrefix/MySuite.MyTest/1", name = "MyPrefix/MySuite.MyTest/1" },
            }
            gtest.find_source_locations(entries, { tmp })

            assert.is_not_nil(entries[1].file)
            assert.equals(1, entries[1].line)
            assert.is_not_nil(entries[2].file)
            assert.equals(1, entries[2].line)

            os.remove(tmp)
        end)

        it("should match typed tests by case name", function()
            local tmp = vim.fn.tempname() .. ".cpp"
            local f = io.open(tmp, "w")
            f:write("TYPED_TEST(TypedSuite, MyCase) { }\n")
            f:close()

            -- Typed test: gtest registers with a different suite name
            local entries = {
                { id = "test:RuntimeSuite.MyCase", name = "RuntimeSuite.MyCase" },
            }
            gtest.find_source_locations(entries, { tmp })

            assert.is_not_nil(entries[1].file)
            assert.equals(1, entries[1].line)

            os.remove(tmp)
        end)
    end)

    describe("parse_xml_results", function()
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

            local results = gtest.parse_xml_results(tmp)
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

            local results = gtest.parse_xml_results(tmp)
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

            local results = gtest.parse_xml_results(tmp)
            assert.is_not_nil(results)
            assert.equals(1, #results)
            assert.equals("skipped", results[1].status)

            os.remove(tmp)
        end)

        it("should return nil for missing file", function()
            local results = gtest.parse_xml_results("/nonexistent/path.xml")
            assert.is_nil(results)
        end)
    end)

    describe("build_filter", function()
        it("should strip test: prefix", function()
            assert.equals("MathSuite.test_add", gtest.build_filter("test:MathSuite.test_add"))
        end)

        it("should pass through plain names", function()
            assert.equals("MathSuite.test_add", gtest.build_filter("MathSuite.test_add"))
        end)
    end)
end)
