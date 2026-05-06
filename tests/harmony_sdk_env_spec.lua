--- Tests for harmony module's hvigor SDK env-var wiring.
---
--- hvigor looks for the SDK path under one of two env-var names
--- depending on which target the active configuration selects:
---   * `DEVECO_SDK_HOME` — HarmonyOS / DevEco Studio target
---   * `OHOS_BASE_SDK_HOME` — OpenHarmony target
--- The harmony module must set both so a profile works regardless
--- of target, without us having to thread "is this OHOS or
--- HarmonyOS?" through the env-building code.

local harmony = require("loomworks.modules.harmony")

--- Find a task by action verb in the list returned by M.tasks.
local function find_task(tasks, action)
    for _, t in ipairs(tasks) do
        if t.loomworks and t.loomworks.action == action then return t end
    end
    return nil
end

--- Resolve a task's env table by invoking its builder closure.
local function resolve_env(task)
    return task.builder().env or {}
end

local function project_ctx()
    return {
        name = "NativeDemo",
        path = "NativeDemo",
        workspace_root = "/fake/root",
        configurations = {
            ["default-default"] = {
                product = "default",
                target = "default",
                modules = { "entry" },
            },
            ["ohos-default"] = {
                product = "ohos",
                target = "default",
                modules = { "entry" },
            },
        },
        tool_data = {
            deveco_home = "/opt/DevEco-Studio",
            node = "/opt/DevEco-Studio/tools/node/node",
            hvigorw_js = "/opt/DevEco-Studio/tools/hvigor/bin/hvigorw.js",
            ohpm = "/opt/DevEco-Studio/tools/ohpm/bin/ohpm",
            java = "/opt/DevEco-Studio/jbr/bin/java",
        },
        type_config = {},
    }
end

describe("harmony hvigor SDK env vars", function()
    it("sets both DEVECO_SDK_HOME and OHOS_BASE_SDK_HOME on configure tasks", function()
        local tasks = harmony.tasks(project_ctx(), "default-default")
        local configure = find_task(tasks, "configure")
        assert.is_not_nil(configure)
        local env = resolve_env(configure)
        local expected = "/opt/DevEco-Studio/sdk"
        assert.equals(expected, env.DEVECO_SDK_HOME,
            "HarmonyOS-targeting hvigor reads DEVECO_SDK_HOME")
        assert.equals(expected, env.OHOS_BASE_SDK_HOME,
            "OpenHarmony-targeting hvigor reads OHOS_BASE_SDK_HOME")
    end)

    it("sets both env vars on build tasks too", function()
        -- Build is a separate task with its own env; the OHOS user
        -- bug surfaced specifically on `nativedemo sync` — confirm
        -- both env vars are set across all hvigor task shapes.
        local tasks = harmony.tasks(project_ctx(), "default-default")
        local build = find_task(tasks, "build")
        assert.is_not_nil(build)
        local env = resolve_env(build)
        assert.equals("/opt/DevEco-Studio/sdk", env.DEVECO_SDK_HOME)
        assert.equals("/opt/DevEco-Studio/sdk", env.OHOS_BASE_SDK_HOME)
    end)

    it("works the same for OpenHarmony-targeting configurations", function()
        -- The fix is target-agnostic — both env vars are always set
        -- so the right one for the active target gets picked up by
        -- hvigor and the other is harmlessly ignored.
        local tasks = harmony.tasks(project_ctx(), "ohos-default")
        local build = find_task(tasks, "build")
        local env = resolve_env(build)
        assert.equals("/opt/DevEco-Studio/sdk", env.OHOS_BASE_SDK_HOME)
        assert.equals("/opt/DevEco-Studio/sdk", env.DEVECO_SDK_HOME)
    end)

    it("uses the same SDK root for both env vars", function()
        -- Aliasing is intentional — they point at the same place.
        -- A divergence would mean hvigor and host tools see different
        -- SDK roots, which is exactly the kind of split-brain that
        -- led to the bug in the first place.
        local tasks = harmony.tasks(project_ctx(), "default-default")
        local env = resolve_env(find_task(tasks, "build"))
        assert.equals(env.DEVECO_SDK_HOME, env.OHOS_BASE_SDK_HOME)
    end)
end)
