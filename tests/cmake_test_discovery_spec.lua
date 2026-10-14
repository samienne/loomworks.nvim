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

        it("parses a testcase spanning ~80k lines in linear time", function()
            -- Regression: the multi-line <testcase> body was accumulated with
            -- repeated string concatenation (O(N^2)); a real 253 MB results file
            -- with an assertion failing 262k times in a loop hung `lw test` for
            -- hours. 20k <failure> elements x 4 lines = 80k lines in one case: ~20 s
            -- with the quadratic code (200k lines exhausts memory instead of
            -- failing on time), well under 0.5 s when linear; the 10 s bound leaves room for loaded CI runners.
            local tmp = vim.fn.tempname() .. ".xml"
            local lines = {
                '<?xml version="1.0" encoding="UTF-8"?>',
                "<testsuites>",
                '  <testsuite name="LoopSuite" tests="2" failures="1">',
                '    <testcase name="Big" classname="LoopSuite" time="1.5">',
            }
            for i = 1, 20000 do
                lines[#lines + 1] = '      <failure message="src/loop.cpp:42&#x0A;Expected" type=""><![CDATA[src/loop.cpp:42'
                lines[#lines + 1] = "Expected equality of these values:"
                lines[#lines + 1] = "  i, which is " .. i
                lines[#lines + 1] = "]]></failure>"
            end
            lines[#lines + 1] = "    </testcase>"
            lines[#lines + 1] = '    <testcase name="Small" classname="LoopSuite" time="0.001" />'
            lines[#lines + 1] = "  </testsuite>"
            lines[#lines + 1] = "</testsuites>"
            local f = io.open(tmp, "w")
            f:write(table.concat(lines, "\n"))
            f:close()

            local t0 = vim.uv.hrtime()
            local results = gtest.parse_xml_results(tmp)
            local elapsed = (vim.uv.hrtime() - t0) / 1e9
            os.remove(tmp)

            assert.is_not_nil(results)
            assert.equals(2, #results)
            assert.equals("test:LoopSuite.Big", results[1].test_id)
            assert.equals("failed", results[1].status)
            assert.equals("src/loop.cpp:42\nExpected equality of these values:\n  i, which is 1\n",
                results[1].message)
            assert.equals("test:LoopSuite.Small", results[2].test_id)
            assert.equals("passed", results[2].status)
            assert.is_true(elapsed < 10, ("parse took %.2f s (limit 10 s)"):format(elapsed))
        end)

        it("caps a case's captured message and output at 1 MiB (line boundary + marker)", function()
            assert.equals(1024 * 1024, gtest.MAX_CAPTURED_BYTES)
            local line = string.rep("x", 79)      -- 80 bytes with its newline
            local big = {}
            for i = 1, 20000 do big[i] = line end   -- 1.6 MB, over the cap
            local body = table.concat(big, "\n")
            local tmp = vim.fn.tempname() .. ".xml"
            local f = io.open(tmp, "w")
            f:write(table.concat({
                '<?xml version="1.0" encoding="UTF-8"?>',
                "<testsuites>",
                '  <testsuite name="S" tests="2" failures="2">',
                '    <testcase name="Big" classname="S" time="1">',
                '      <failure message="m"><![CDATA[src/a.cpp:1',
                body .. "]]></failure>",
                "      <system-out><![CDATA[" .. body .. "]]></system-out>",
                "    </testcase>",
                '    <testcase name="Small" classname="S" time="1">',
                '      <failure message="m"><![CDATA[src/a.cpp:2',
                "Expected: 1]]></failure>",
                "      <system-out>hello</system-out>",
                "    </testcase>",
                "  </testsuite>",
                "</testsuites>",
            }, "\n"))
            f:close()
            local results = gtest.parse_xml_results(tmp)
            os.remove(tmp)
            assert.equals(2, #results)
            local full_msg = "src/a.cpp:1\n" .. body
            for _, s in ipairs({ { results[1].message, #full_msg }, { results[1].output, #body } }) do
                local text, total = s[1], s[2]
                local kept, more = text:match("^(.-)%.%.%. %[truncated: (%d+) more bytes%]$")
                assert.is_not_nil(kept, text:sub(-80))
                assert.is_true(#kept <= gtest.MAX_CAPTURED_BYTES)
                assert.equals("\n", kept:sub(-1))                    -- cut at a line boundary
                assert.equals(total, #kept + tonumber(more))
            end
            -- Location parsing still works on the capped message.
            assert.equals("src/a.cpp", results[1].errors[1].file)
            -- Normal-sized captures are unchanged.
            assert.equals("src/a.cpp:2\nExpected: 1", results[2].message)
            assert.equals("hello", results[2].output)
        end)

        -- Run `fn` with the cap temporarily set to `cap` bytes.
        local function with_cap(cap, fn)
            local saved = gtest.MAX_CAPTURED_BYTES
            gtest.MAX_CAPTURED_BYTES = cap
            local ok, err = pcall(fn)
            gtest.MAX_CAPTURED_BYTES = saved
            if not ok then error(err, 0) end
        end

        it("caps one huge line with no newline quickly (hard cut + marker)", function()
            with_cap(32 * 1024, function()
                local text = string.rep("x", 40 * 1024)
                local t0 = vim.uv.hrtime()
                local capped = gtest.cap_captured(text)
                local elapsed = (vim.uv.hrtime() - t0) / 1e9
                assert.is_true(elapsed < 1, ("cap took %.2f s (limit 1 s)"):format(elapsed))
                local kept, more = capped:match("^(.-)%.%.%. %[truncated: (%d+) more bytes%]$")
                assert.is_not_nil(kept)
                assert.equals(32 * 1024, #kept)
                assert.equals(8 * 1024, tonumber(more))
            end)
        end)

        it("does not split a UTF-8 character straddling a hard cut", function()
            with_cap(10, function()
                -- "é" (2 bytes) at bytes 10-11; "€" (3 bytes) at bytes 9-11.
                for _, case in ipairs({
                    { "abcdefghi" .. "é" .. "xyz", "abcdefghi" },
                    { "abcdefgh" .. "€" .. "xyz", "abcdefgh" },
                    { "abcdefghij" .. "é", "abcdefghij" },   -- char starts after the cap
                }) do
                    local capped = gtest.cap_captured(case[1])
                    local kept, more = capped:match("^(.-)%.%.%. %[truncated: (%d+) more bytes%]$")
                    assert.equals(case[2], kept)
                    assert.equals(#case[1] - #kept, tonumber(more))
                end
            end)
        end)

        it("gtest native XML: a DISABLED test is skipped+disabled, a GTEST_SKIP is skipped (never passed)", function()
            -- Real gtest output shapes (CRLF as written on Windows): a disabled
            -- test is a self-closing testcase with status="notrun"
            -- result="suppressed"; GTEST_SKIP has result="skipped" and, from
            -- gtest 1.11, a <skipped> child (1.10 wrote an empty body).
            local tmp = vim.fn.tempname() .. ".xml"
            local f = io.open(tmp, "wb")
            f:write(table.concat({
                '<?xml version="1.0" encoding="UTF-8"?>',
                '<testsuites tests="5" failures="0" disabled="1" errors="0">',
                '  <testsuite name="S" tests="5" failures="0" disabled="1" skipped="3" errors="0">',
                '    <testcase name="ok" file="a.cpp" line="1" status="run" result="completed" time="0." classname="S" />',
                '    <testcase name="DISABLED_off" file="a.cpp" line="2" status="notrun" result="suppressed" time="0." classname="S" />',
                '    <testcase name="skip_new" file="a.cpp" line="3" status="run" result="skipped" time="0." classname="S">',
                '      <skipped message="a.cpp:3&#x0A;why"><![CDATA[a.cpp:3',
                'why]]></skipped>',
                '    </testcase>',
                '    <testcase name="skip_old" file="a.cpp" line="4" status="run" result="skipped" time="0." classname="S">',
                '    </testcase>',
                '    <testcase name="skip_inline" status="run" result="skipped" time="0." classname="S"></testcase>',
                '  </testsuite>',
                '</testsuites>',
            }, "\r\n"))
            f:close()
            local results = gtest.parse_xml_results(tmp)
            os.remove(tmp)
            local by = {}
            for _, r in ipairs(results) do by[r.test_id] = r end
            assert.equals("passed", by["test:S.ok"].status)
            assert.is_nil(by["test:S.ok"].disabled)
            assert.equals("skipped", by["test:S.DISABLED_off"].status)
            assert.is_true(by["test:S.DISABLED_off"].disabled)
            for _, id in ipairs({ "test:S.skip_new", "test:S.skip_old", "test:S.skip_inline" }) do
                assert.equals("skipped", by[id].status, id)
                assert.is_nil(by[id].disabled, id)
            end
            local c = require("loomworks.remote.test_run").count(results)
            assert.same({ 5, 3, 1 }, { c.total, c.skipped, c.disabled })
        end)

        it("ctest JUnit: a notrun test is skipped, and disabled only when gtest suppressed it", function()
            -- ctest --output-junit writes status="notrun" for every NOT_RUN
            -- test (SKIP_RETURN_CODE, DISABLED property, missing executable);
            -- only gtest's result="suppressed" marks a DISABLED_ test.
            local tmp = vim.fn.tempname() .. ".xml"
            local f = io.open(tmp, "wb")
            f:write(table.concat({
                '<?xml version="1.0" encoding="UTF-8"?>',
                '<testsuite name="Linux" tests="3" failures="0" disabled="0" skipped="2" time="0.1">',
                '    <testcase name="ok" classname="ok" time="0.1" status="run">',
                '        <system-out>fine</system-out>',
                '    </testcase>',
                '    <testcase name="skip_rc" classname="skip_rc" time="0" status="notrun">',
                '        <skipped message="SKIP_RETURN_CODE=77"/>',
                '        <system-out>skipping</system-out>',
                '    </testcase>',
                '    <testcase name="noexe" classname="noexe" time="0" status="notrun"/>',
                '</testsuite>',
            }, "\n"))
            f:close()
            local results = gtest.parse_xml_results(tmp)
            os.remove(tmp)
            local by = {}
            for _, r in ipairs(results) do by[r.test_id] = r end
            assert.equals("passed", by["test:ok.ok"].status)
            for _, id in ipairs({ "test:skip_rc.skip_rc", "test:noexe.noexe" }) do
                assert.equals("skipped", by[id].status, id)
                assert.is_nil(by[id].disabled, id)
            end
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
