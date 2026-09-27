--- The generated vcvarsall batch files never let a path or argument add a
--- command: the vcvarsall path and arch are validated, every argv element is
--- quoted for cmd.exe, and the batch disables delayed expansion and the
--- current-directory command search. The tests read the generated file; one
--- benign end-to-end test runs cmd.exe on a batch in a build dir whose path has
--- spaces, `(`, `)` and `&` (the path reaches cmd via delayed expansion).

local cmake = require("loomworks.modules.cmake")
local msvc = require("loomworks.msvc")

local function read_all(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

local function find_task(tasks, action)
    for _, t in ipairs(tasks) do
        if t.loomworks and t.loomworks.action == action then return t end
    end
end

describe("msvc batch helpers", function()
    it("bat_quote always quotes, doubles % and trailing backslashes", function()
        assert.equals('"a"', msvc.bat_quote("a"))
        assert.equals('"a b"', msvc.bat_quote("a b"))
        assert.equals('"x&y|z<w>v^u"', msvc.bat_quote("x&y|z<w>v^u"))
        assert.equals('"%%PATH%%"', msvc.bat_quote("%PATH%"))
        assert.equals('"C:\\dir\\\\"', msvc.bat_quote("C:\\dir\\"))
    end)

    it("bat_quote refuses quotes and line breaks", function()
        assert.is_nil(msvc.bat_quote('a"b'))
        assert.is_nil(msvc.bat_quote("a\nb"))
        assert.is_nil(msvc.bat_quote("a\rb"))
    end)

    it("valid_arch accepts vcvarsall architectures only", function()
        assert.is_true(msvc.valid_arch("x64"))
        assert.is_true(msvc.valid_arch("amd64_arm64"))
        assert.is_false(msvc.valid_arch("x64 & echo"))
        assert.is_false(msvc.valid_arch(""))
        assert.is_false(msvc.valid_arch(nil))
    end)

    it("check_vcvarsall requires an absolute, existing, metachar-free vcvarsall.bat", function()
        local dir = (vim.fn.tempname():gsub("\\", "/"))
        vim.fn.mkdir(dir, "p")
        local good = dir .. "/vcvarsall.bat"
        vim.fn.writefile({ "@echo off" }, good)
        if vim.fn.has("win32") == 1 then
            assert.is_true((msvc.check_vcvarsall(good)))
        end
        assert.is_false((msvc.check_vcvarsall("vcvarsall.bat")))
        assert.is_false((msvc.check_vcvarsall(dir .. "/other.bat")))
        assert.is_false((msvc.check_vcvarsall("C:/nope/vcvarsall.bat")))
        assert.is_false((msvc.check_vcvarsall('C:/a&b/vcvarsall.bat')))
        assert.is_false((msvc.check_vcvarsall('C:/a%X%/vcvarsall.bat')))
        assert.is_false((msvc.check_vcvarsall('C:/a"b/vcvarsall.bat')))
        vim.fn.delete(dir, "rf")
    end)

    it("vcvars_env refuses an invalid arch or vcvarsall without running anything", function()
        local saved = vim.system
        local ran = false
        vim.system = function() ran = true; return { wait = function() return { code = 1 } end } end
        local e1, err1 = msvc.vcvars_env("C:/a&b/vcvarsall.bat", "x64")
        local e2, err2 = msvc.vcvars_env("C:/VS/vcvarsall.bat", "x64 & echo")
        vim.system = saved
        assert.is_nil(e1); assert.is_string(err1)
        assert.is_nil(e2); assert.is_string(err2)
        assert.is_false(ran)
    end)
end)

if vim.fn.has("win32") == 1 then
describe("cmake vcvarsall .bat content", function()
    local root, vcvarsall

    before_each(function()
        root = (vim.fn.tempname():gsub("\\", "/"))
        vim.fn.mkdir(root .. "/VS", "p")
        vcvarsall = root .. "/VS/vcvarsall.bat"
        vim.fn.writefile({ "@echo off" }, vcvarsall)
    end)
    after_each(function() vim.fn.delete(root, "rf") end)

    local function ctx(build_dir, over, type_config)
        local td = { generator = "Ninja", vcvarsall = vcvarsall, arch = "x64" }
        for k, v in pairs(over or {}) do td[k] = v end
        return {
            name = "App", path = "App", workspace_root = root,
            configurations = { ["my-debug"] = { variant = "Debug", generator = "Ninja" } },
            tool_data = td,
            type_config = type_config,
            cached_build_dir = build_dir,
        }
    end

    it("quotes every argument and doubles % so an argument cannot expand or chain", function()
        local bd = root .. "/build dir"
        vim.fn.mkdir(bd, "p")
        local configure = find_task(cmake.tasks(
            ctx(bd, nil, { options = { LW_PROBE = "a&b|c %PATH% !x!" } }), "my-debug"), "configure")
        local bat = configure.builder().env.LOOMWORKS_VCVARS_BAT
        local text = read_all(bat)
        assert.is_truthy(text:find("setlocal DisableDelayedExpansion", 1, true))
        assert.is_truthy(text:find('set "NoDefaultCurrentDirectoryInExePath=1"', 1, true))
        assert.is_truthy(text:find('"' .. bd .. '"', 1, true), "build dir must appear quoted:\n" .. text)
        assert.is_truthy(text:find('"-DLW_PROBE=a&b|c %%PATH%% !x!"', 1, true),
            "option must appear quoted with % doubled:\n" .. text)
        -- The command line is one line of quoted tokens only.
        local last = text:match("([^\r\n]+)[\r\n]*$")
        assert.is_nil(last:gsub('"[^"]*"', ""):find("[^%s]"), "unquoted token on the command line: " .. last)
    end)

    it("accepts a build dir with spaces, ( ) and & — the batch path travels in an env var", function()
        local bd = root .. "/Projects (old) & x"
        vim.fn.mkdir(bd, "p")
        local configure = find_task(cmake.tasks(ctx(bd), "my-debug"), "configure")
        local spec = configure.builder()
        -- cmd.exe substitutes the path by delayed expansion after parsing its
        -- command line; the path itself is never on the command line.
        assert.same({ "cmd", "/d", "/v:on", "/c", "!LOOMWORKS_VCVARS_BAT!" }, spec.cmd)
        local bat = spec.env.LOOMWORKS_VCVARS_BAT
        assert.is_truthy(bat:find("Projects (old) & x", 1, true))
        assert.is_truthy(read_all(bat), "the batch file is written")
    end)

    it("refuses a build dir containing %, ! or a quote", function()
        for _, name in ipairs({ "a%PATH%b", "a!b" }) do
            local bd = root .. "/" .. name
            vim.fn.mkdir(bd, "p")
            local configure = find_task(cmake.tasks(ctx(bd), "my-debug"), "configure")
            local ok, err = pcall(configure.builder)
            assert.is_false(ok, name)
            assert.matches("cannot be passed safely", tostring(err), 1, true)
        end
    end)

    it("runs the generated batch from a build dir with ( ) & and spaces under both spawn conventions", function()
        -- Benign end-to-end: the fake vcvarsall.bat only echoes off; the
        -- wrapped command is cmd.exe echoing a marker with an argument that
        -- contains ( ) and &. Run through the editor's job runner (Neovim hands
        -- cmd.exe its arguments verbatim) and through vim.system (arguments
        -- quoted), after the same hardening production applies.
        local bd = root .. "/Projects (old) & x"
        vim.fn.mkdir(bd, "p")
        local comspec = (vim.fn.exepath("cmd.exe"))
        local inner = { comspec, "/d", "/c", "echo", "LW_MARKER a(b)&c" }
        local argv, env = cmake._wrap_cmd(inner, { vcvarsall = vcvarsall, arch = "x64" },
            "Ninja", bd, "probe", {})
        local hardened = assert(require("loomworks.exe").harden_spec({ cmd = argv, env = env }))

        local out = {}
        local job = vim.fn.jobstart(hardened.cmd, {
            env = hardened.env, stdout_buffered = true,
            on_stdout = function(_, d) out[#out + 1] = table.concat(d, " ") end,
        })
        assert.is_true(job > 0)
        assert.same({ 0 }, vim.fn.jobwait({ job }, 10000))
        local job_out = table.concat(out, " ")
        assert.is_truthy(job_out:find("LW_MARKER a(b)&c", 1, true), "jobstart output: " .. job_out)

        local res = vim.system(hardened.cmd, { env = hardened.env, text = true }):wait(10000)
        assert.equals(0, res.code)
        assert.is_truthy((res.stdout or ""):find("LW_MARKER a(b)&c", 1, true),
            "vim.system output: " .. tostring(res.stdout) .. tostring(res.stderr))
    end)

    it("refuses an unsafe vcvarsall path or arch (no unwrapped fallback)", function()
        local bd = root .. "/build"
        vim.fn.mkdir(bd, "p")
        local c1 = find_task(cmake.tasks(ctx(bd, { vcvarsall = root .. "/VS&x/vcvarsall.bat" }), "my-debug"), "configure")
        assert.is_false((pcall(c1.builder)))
        local c2 = find_task(cmake.tasks(ctx(bd, { arch = "x64 & echo" }), "my-debug"), "configure")
        assert.is_false((pcall(c2.builder)))
    end)

    it("does not write through a link planted at the batch file's name", function()
        local bd = root .. "/build"
        vim.fn.mkdir(bd, "p")
        local configure = find_task(cmake.tasks(ctx(bd), "my-debug"), "configure")
        local bat = configure.builder().env.LOOMWORKS_VCVARS_BAT
        -- Replace the batch with a link to a victim file, then regenerate.
        local victim = root .. "/victim.txt"
        vim.fn.writefile({ "keep" }, victim)
        os.remove(bat)
        local uv = vim.uv or vim.loop
        if not uv.fs_symlink(victim, bat) then pending("cannot create a file symlink here") return end
        configure.builder()
        assert.same({ "keep" }, vim.fn.readfile(victim))
    end)
end)
end
