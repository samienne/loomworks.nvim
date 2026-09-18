-- Pipe endpoint address scheme: token stability, the POSIX sun_path length
-- guard (pure, runs on every platform), and the per-platform address format.
-- The real POSIX bind/listen/connect path is exercised by daemon_server_spec on
-- the Linux/macOS CI jobs.

local pipe = require("loomworks.daemon.pipe")
local is_win = package.config:sub(1, 1) == "\\"

describe("daemon.pipe token", function()
    it("is a stable 8-hex token, slash/backslash- and trailing-slash-insensitive", function()
        assert.is_truthy(pipe.token("/x/y"):match("^%x%x%x%x%x%x%x%x$"))
        assert.equals(pipe.token("/a/b/c"), pipe.token("/a/b/c/"))
        assert.equals(pipe.token("/a/b/c"), pipe.token("\\a\\b\\c"))
    end)

    it("differs for different roots", function()
        assert.are_not.equal(pipe.token("/a"), pipe.token("/b"))
    end)

    if not is_win then
        it("is case-SENSITIVE on POSIX (case-sensitive filesystems)", function()
            assert.are_not.equal(pipe.token("/A/b"), pipe.token("/a/b"))
        end)
    else
        it("is case-INSENSITIVE on Windows (case-insensitive filesystems)", function()
            assert.equals(pipe.token("C:/Repo"), pipe.token("c:/repo"))
        end)
    end
end)

describe("daemon.pipe POSIX socket-path length guard (pure)", function()
    it("prefers the first base whose socket path fits sun_path", function()
        local _dir, path = pipe._resolve_socket_path("cafef00d", { "/run/user/1000", "/tmp" })
        assert.is_truthy(path:find("^/run/user/1000/loomworks%-"))
        assert.is_truthy(path:find("cafef00d%.sock$"))
        assert.is_true(#path <= pipe.SUN_PATH_MAX)
    end)

    it("skips a base that would overflow sun_path, falling to a shorter one", function()
        local long = "/" .. string.rep("x", 120)
        local _dir, path = pipe._resolve_socket_path("deadbeef", { long, "/tmp" })
        assert.is_truthy(path:find("^/tmp/loomworks%-"))
        assert.is_true(#path <= pipe.SUN_PATH_MAX)
    end)

    it("uses /tmp as the last resort even if every base overflows", function()
        local long = "/" .. string.rep("x", 200)
        local _dir, path = pipe._resolve_socket_path("deadbeef", { long })
        assert.is_truthy(path:find("^/tmp/loomworks%-"))
        assert.is_truthy(path:find("deadbeef%.sock$"))
    end)
end)

describe("daemon.pipe address format", function()
    if is_win then
        it("is a named pipe on Windows", function()
            local a = pipe.address("C:/some/repo")
            assert.is_truthy(a:find("^\\\\%.\\pipe\\loomworks%-"))
        end)
    else
        it("is a per-user .sock within sun_path on POSIX", function()
            local a = pipe.address("/some/repo")
            assert.is_truthy(a:find("loomworks%-"))
            assert.is_truthy(a:find("%.sock$"))
            assert.is_true(#a <= pipe.SUN_PATH_MAX)
        end)

        it("is stable across calls (deterministic per root)", function()
            assert.equals(pipe.address("/some/repo"), pipe.address("/some/repo"))
        end)
    end
end)
