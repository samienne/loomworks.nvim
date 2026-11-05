--- tests/fixtures/sdkstub — a harness-only SDK provider `fake_c2c`: an
--- acquired module of a test's data dir (tests/daemon_helpers.lua
--- `install_stub_module`), never in a release bundle. It detects the one
--- directory $LW_TEST_FAKE_SDK (version 3) and validates any directory.

local SDK = require("loomworks.sdk")

local P = { id = "fake_c2c", api_version = require("loomworks.api_versions").sdk,
    display_name = "Fake C2c", path_prompt = "Path to the fake SDK" }

function P.validate(path)
    local st = (vim.uv or vim.loop).fs_stat(path)
    return st and st.type == "directory" and { version = "3" } or nil
end

function P.create_sdk(key, path, version)
    return SDK.new({ key = key, type = "fake_c2c", version = version, path = path,
        resolved = true, provider = P })
end

function P.detect_all()
    local dir = os.getenv("LW_TEST_FAKE_SDK")
    return dir and { { path = dir, version = "3" } } or {}
end

function P.match_version() return true end

return P
