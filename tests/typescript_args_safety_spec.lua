--- The typescript module runs npm/npx through `cmd /c` on Windows, which
--- re-parses its arguments: npm script names (from type_config) and tsconfig
--- names (from type_config or `tsconfig.<variant>.json` files in the project)
--- must not be able to add commands. Unsafe names are refused when the task is
--- built; ordinary names pass unchanged.

local ts = require("loomworks.modules.typescript")

local function write(p, text)
    vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
    local f = assert(io.open(p, "w")); f:write(text); f:close()
end

local function find_task(tasks, action)
    for _, t in ipairs(tasks) do
        if t.loomworks and t.loomworks.action == action then return t end
    end
end

describe("typescript command arguments", function()
    local root

    before_each(function()
        root = (vim.fn.tempname():gsub("\\", "/"))
        write(root .. "/App/package.json", vim.json.encode({
            scripts = { ["build:prod"] = "tsc", ["evil&x"] = "tsc", clean = "rimraf dist" },
        }))
        write(root .. "/App/tsconfig.json", "{}")
    end)
    after_each(function() vim.fn.delete(root, "rf") end)

    local function ctx(type_config, configurations)
        return {
            name = "App", path = "App", workspace_root = root,
            type_config = type_config or {},
            configurations = configurations or {},
            configuration_key = "default",
        }
    end

    it("accepts ordinary script names", function()
        local build = find_task(ts.tasks(ctx({ scripts = { build = "build:prod" } }), "default"), "build")
        local cmd = build.builder().cmd
        assert.equals("build:prod", cmd[#cmd])
    end)

    it("refuses a script name with cmd metacharacters", function()
        local build = find_task(ts.tasks(ctx({ scripts = { build = "evil&x" } }), "default"), "build")
        local ok, err = pcall(build.builder)
        assert.is_false(ok)
        assert.matches("refusing", tostring(err), 1, true)
    end)

    it("refuses a tsconfig variant file name with cmd metacharacters", function()
        write(root .. "/App/tsconfig.a&b.json", "{}")
        local build = find_task(ts.tasks(ctx({}, { ["a&b"] = { tsconfig = "tsconfig.a&b.json" } }), "a&b"), "build")
        local ok = pcall(build.builder)
        assert.is_false(ok)
    end)

    it("clean refuses an unsafe clean script too", function()
        local clean = find_task(ts.clean_tasks(ctx({ scripts = { clean = "evil&x" } }), "default"), "clean")
        assert.is_false((pcall(clean.builder)))
    end)
end)
