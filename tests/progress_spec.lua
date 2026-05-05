local progress = require("loomworks.progress")

describe("progress", function()
    describe("ninja parser", function()
        local parse

        before_each(function()
            parse = progress.get("ninja")
            assert.is_not_nil(parse)
        end)

        it("parses standard ninja output and strips path to basename", function()
            -- Path-bearing last token is compacted: deep CMake build
            -- paths would otherwise blow the fidget popup wide.
            local result = parse("[2/10] Building CXX object src/main.cpp.o")
            assert.is_not_nil(result)
            assert.equals(2, result.current)
            assert.equals(10, result.total)
            assert.equals("Building CXX object main.cpp.o", result.message)
        end)

        it("strips deep path to basename", function()
            local result = parse(
                "[7/22] Building CXX object src/CMakeFiles/foo.dir/path/to/file.cpp.o")
            assert.equals("Building CXX object file.cpp.o", result.message)
        end)

        it("strips Windows backslash paths", function()
            local result = parse(
                [[[3/9] Linking CXX executable bin\Release\foo.exe]])
            assert.equals("Linking CXX executable foo.exe", result.message)
        end)

        it("leaves the message alone when last token has no separator", function()
            -- Common with linking where the artifact is at the build
            -- root, or with single-token actions.
            local r1 = parse("[5/5] Linking CXX shared library libfoo.so")
            assert.equals("Linking CXX shared library libfoo.so", r1.message)

            local r2 = parse("[1/1] cmake_check_build_system")
            assert.equals("cmake_check_build_system", r2.message)
        end)

        it("handles single-word messages with separators", function()
            -- Edge case: just one token, nothing to split into prefix.
            -- Message is left unchanged (no prefix to glue back).
            local result = parse("[1/2] some/lone/path.txt")
            assert.equals("some/lone/path.txt", result.message)
        end)

        it("parses ninja output without message", function()
            local result = parse("[1/1]")
            assert.is_not_nil(result)
            assert.equals(1, result.current)
            assert.equals(1, result.total)
        end)

        it("returns nil for non-ninja output", function()
            assert.is_nil(parse("-- Configuring done"))
            assert.is_nil(parse("make[1]: Entering directory"))
            assert.is_nil(parse(""))
            assert.is_nil(parse("Building CXX object without bracket prefix"))
        end)

    end)

    describe("registry", function()
        it("returns nil for unknown tool", function()
            assert.is_nil(progress.get("nonexistent_tool"))
        end)

        it("allows manual registration", function()
            local called = false
            progress.register("test_tool", function(line)
                called = true
                return { current = 1, total = 1 }
            end)
            local parser = progress.get("test_tool")
            assert.is_not_nil(parser)
            parser("test")
            assert.is_true(called)
        end)
    end)
end)
