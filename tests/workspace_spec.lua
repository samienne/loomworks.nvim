local workspace = require("loomworks.workspace")
local h = require("tests.helpers")

describe("workspace", function()
    describe("paths", function()
        it("returns all three file paths", function()
            local p = workspace.paths("/my/workspace")
            assert.equals("/my/workspace/loomworks.json", p.config)
            assert.equals("/my/workspace/.nvim/loomworks.user.json", p.user)
            assert.equals("/my/workspace/.nvim/loomworks.cache.json", p.cache)
        end)
    end)

    describe("resolve_root", function()
        it("strips trailing slash", function()
            local root = workspace.resolve_root(nil, function(p) return p .. "/" end)
            assert.is_nil(root:match("/$"))
        end)

        it("uses provided path", function()
            -- Use a path that's already absolute on whichever platform the
            -- tests run on. `resolve_root` runs `fnamemodify(:p)` on the
            -- input, so a POSIX-style "/my/path" would resolve against cwd
            -- on Windows.
            local input = vim.fn.has("win32") == 1 and "C:/my/path" or "/my/path"
            local root = workspace.resolve_root(input, function(p) return p end)
            assert.equals(input, root)
        end)
    end)

    describe("assemble", function()
        it("assembles workspace from raw content", function()
            local config_json = h.make_config_json()
            local ws, err = workspace.assemble("/root", config_json, nil, nil)
            assert.is_nil(err)
            assert.is_not_nil(ws)
            assert.equals("/root", ws.root)
            assert.is_not_nil(ws.config.projects.App)
            assert.equals("cmake", ws.config.projects.App.type)
        end)

        it("loads empty workspace when config_content is nil but user_content exists", function()
            local user = vim.json.encode({ _meta = { version = 2 } })
            local ws, err = workspace.assemble("/root", nil, user, nil)
            assert.is_not_nil(ws)
            assert.is_nil(err)
            assert.equals("/root", ws.root)
        end)

        it("loads empty workspace when both config and user are nil", function()
            local ws, err = workspace.assemble("/root", nil, nil, nil)
            assert.is_not_nil(ws)
            assert.equals("/root", ws.root)
        end)

        it("returns error on invalid config JSON", function()
            local ws, err = workspace.assemble("/root", "broken", nil, nil)
            assert.is_nil(ws)
            assert.is_not_nil(err)
        end)

        it("uses defaults when user/cache content is nil", function()
            local config_json = h.make_config_json()
            local ws = workspace.assemble("/root", config_json, nil, nil)
            assert.is_not_nil(ws.user)
            assert.is_not_nil(ws.cache)
            assert.equals(2, ws.user._meta.version)
            assert.equals(8, ws.cache._meta.version)
        end)

        it("parses user.json when provided", function()
            local config_json = h.make_config_json()
            local user_json = h.make_user_json({ active_profile = "debug" })
            local ws = workspace.assemble("/root", config_json, user_json, nil)
            assert.equals("debug", ws.user.active_profile)
        end)

        it("parses cache.json when provided", function()
            local config_json = h.make_config_json()
            local cache_json = h.make_cache_json({
                configurations = {
                    ["App/Debug"] = {
                        project_key = "App",
                        config_key = "Debug",
                        type = "cmake",
                        state = "built",
                    },
                },
            })
            local ws = workspace.assemble("/root", config_json, nil, cache_json)
            assert.equals("built", ws.cache.build_dirs["build/App/Debug"].state)
        end)

        it("derives name from directory when not in config", function()
            local config_json = h.make_config_json()
            local ws = workspace.assemble("/home/user/my-project", config_json, nil, nil)
            assert.equals("my-project", ws.name)
        end)

        it("uses config name when provided", function()
            local config_json = h.make_config_json({ name = "CustomName" })
            local ws = workspace.assemble("/root", config_json, nil, nil)
            assert.equals("CustomName", ws.name)
        end)

        it("computes cache hash from config content", function()
            local config_json = h.make_config_json()
            local ws = workspace.assemble("/root", config_json, nil, nil)
            assert.is_not_nil(ws.cache._meta.loomworks_hash)
            assert.are_not.equals("", ws.cache._meta.loomworks_hash)
        end)

        it("produces consistent hash for same content", function()
            local config_json = h.make_config_json()
            local ws1 = workspace.assemble("/root", config_json, nil, nil)
            local ws2 = workspace.assemble("/root", config_json, nil, nil)
            assert.equals(ws1.cache._meta.loomworks_hash, ws2.cache._meta.loomworks_hash)
        end)

        it("sets cache_version_mismatch false when no cache content", function()
            local config_json = h.make_config_json()
            local ws = workspace.assemble("/root", config_json, nil, nil)
            assert.is_false(ws.cache_version_mismatch)
        end)

        it("sets cache_version_mismatch false on matching version", function()
            local config_json = h.make_config_json()
            local cache_json = h.make_cache_json()
            local ws = workspace.assemble("/root", config_json, nil, cache_json)
            assert.is_false(ws.cache_version_mismatch)
        end)

        it("sets cache_version_mismatch true on wrong version", function()
            local config_json = h.make_config_json()
            local cache_json = vim.json.encode({
                _meta = { version = 1 },
                projects = {},
            })
            local ws = workspace.assemble("/root", config_json, nil, cache_json)
            assert.is_true(ws.cache_version_mismatch)
            -- Cache data should be defaults (empty)
            assert.are.same({}, ws.cache.build_dirs)
        end)

        it("normalizes user projects from raw JSON format", function()
            local config_json = h.make_config_json()
            local user_json = h.make_user_json({
                projects = {
                    MyLib = { cmake = { configurations = { Custom = { variant = "Custom" } } } },
                },
            })
            local ws = workspace.assemble("/root", config_json, user_json, nil)
            assert.equals("cmake", ws.user.projects.MyLib.type)
            assert.equals("MyLib", ws.user.projects.MyLib.path)
            assert.is_not_nil(ws.user.projects.MyLib.type_config)
        end)

        it("leaves user data alone when no projects field", function()
            local config_json = h.make_config_json()
            local user_json = h.make_user_json({ active_profile = "debug" })
            local ws = workspace.assemble("/root", config_json, user_json, nil)
            assert.is_nil(ws.user.projects)
            assert.equals("debug", ws.user.active_profile)
        end)
    end)

    describe("merge_configs", function()
        it("shared-only projects appear in merged config", function()
            local shared = {
                name = "test",
                projects = {
                    App = { type = "cmake", path = "App", type_config = {} },
                },
            }
            local merged, user_pks, user_csn = workspace.merge_configs(nil, shared)
            assert.is_not_nil(merged.projects.App)
            assert.equals("cmake", merged.projects.App.type)
            assert.is_falsy(next(user_pks))
            assert.is_falsy(next(user_csn))
        end)

        it("user project overrides shared project with same key", function()
            local shared = {
                projects = {
                    App = { type = "cmake", path = "shared/App", type_config = {} },
                },
            }
            local user = {
                projects = {
                    App = { type = "cmake", path = "user/App", type_config = {} },
                },
            }
            local merged, user_pks = workspace.merge_configs(user, shared)
            assert.equals("user/App", merged.projects.App.path)
            assert.is_true(user_pks["App"])
        end)

        it("user and shared projects combine when keys differ", function()
            local shared = {
                projects = {
                    App = { type = "cmake", path = "App", type_config = {} },
                },
            }
            local user = {
                projects = {
                    MyLib = { type = "cmake", path = "MyLib", type_config = {} },
                },
            }
            local merged, user_pks = workspace.merge_configs(user, shared)
            assert.is_not_nil(merged.projects.App)
            assert.is_not_nil(merged.projects.MyLib)
            assert.is_true(user_pks["MyLib"])
            assert.is_falsy(user_pks["App"])
        end)

        it("user config_set overrides shared config_set", function()
            local shared = {
                configuration_sets = {
                    Debug = { App = "Debug" },
                },
            }
            local user = {
                configuration_sets = {
                    Debug = { App = "Release" },
                },
            }
            local merged, _, user_csn = workspace.merge_configs(user, shared)
            assert.equals("Release", merged.configuration_sets.Debug.App)
            assert.is_true(user_csn["Debug"])
        end)

        it("returns nil configuration_sets when none exist", function()
            local merged = workspace.merge_configs(nil, { projects = {} })
            assert.is_nil(merged.configuration_sets)
        end)

        it("handles nil user and nil shared gracefully", function()
            local merged = workspace.merge_configs(nil, nil)
            assert.are.same({}, merged.projects)
            assert.is_nil(merged.configuration_sets)
        end)

        it("solo dev: everything from user, no shared config", function()
            local user = {
                projects = {
                    App = { type = "cmake", path = "App", type_config = {} },
                },
                configuration_sets = {
                    Debug = { App = "Debug" },
                },
            }
            local merged, user_pks, user_csn = workspace.merge_configs(user, { projects = {} })
            assert.is_not_nil(merged.projects.App)
            assert.is_true(user_pks["App"])
            assert.equals("Debug", merged.configuration_sets.Debug.App)
            assert.is_true(user_csn["Debug"])
        end)

        -- Per-configuration merge tests
        it("per-config merge: user configs overlay shared configs", function()
            local shared = {
                projects = {
                    App = { type = "cmake", path = "App", type_config = {
                        configurations = {
                            Debug = { variant = "Debug" },
                            Release = { variant = "Release" },
                        },
                    }},
                },
            }
            local user = {
                projects = {
                    App = { type = "cmake", path = "App", type_config = {
                        configurations = {
                            Debug = { variant = "Debug", toolchain = "my-tc" },
                            Asan = { inherits = "Debug", options = { USE_ASAN = "ON" } },
                        },
                    }},
                },
            }
            local merged, _, _, prov = workspace.merge_configs(user, shared)
            local configs = merged.projects.App.type_config.configurations
            -- All three configs present
            assert.is_not_nil(configs.Debug)
            assert.is_not_nil(configs.Release)
            assert.is_not_nil(configs.Asan)
            -- User's Debug wins (has toolchain)
            assert.equals("my-tc", configs.Debug.toolchain)
            -- Shared Release preserved
            assert.equals("Release", configs.Release.variant)
            -- Provenance tracks which configs came from user
            assert.is_true(prov.App.user_configs.Debug)
            assert.is_true(prov.App.user_configs.Asan)
            assert.is_falsy(prov.App.user_configs and prov.App.user_configs.Release)
        end)

        it("per-config merge: user launch configs overlay shared", function()
            local shared = {
                projects = {
                    App = { type = "cmake", path = "App", type_config = {},
                        launch = { run = { command = "shared-cmd" }, test = { command = "test" } } },
                },
            }
            local user = {
                projects = {
                    App = { type = "cmake", path = "App", type_config = {},
                        launch = { run = { command = "user-cmd" }, debug = { command = "dbg" } } },
                },
            }
            local merged, _, _, prov = workspace.merge_configs(user, shared)
            assert.equals("user-cmd", merged.projects.App.launch.run.command)
            assert.equals("test", merged.projects.App.launch.test.command)
            assert.equals("dbg", merged.projects.App.launch.debug.command)
            assert.is_true(prov.App.user_launches.run)
            assert.is_true(prov.App.user_launches.debug)
            assert.is_falsy(prov.App.user_launches and prov.App.user_launches.test)
        end)

        it("per-config merge: user variables overlay shared", function()
            local shared = {
                projects = {
                    App = { type = "cmake", path = "App", type_config = {},
                        variables = { LIB_PATH = { type = "path", default = "/lib" } } },
                },
            }
            local user = {
                projects = {
                    App = { type = "cmake", path = "App", type_config = {},
                        variables = { LIB_PATH = { type = "path", default = "/user/lib" },
                                      MY_VAR = { type = "string", default = "foo" } } },
                },
            }
            local merged, _, _, prov = workspace.merge_configs(user, shared)
            assert.equals("/user/lib", merged.projects.App.variables.LIB_PATH.default)
            assert.equals("foo", merged.projects.App.variables.MY_VAR.default)
            assert.is_true(prov.App.user_variables.LIB_PATH)
            assert.is_true(prov.App.user_variables.MY_VAR)
        end)

        it("per-config merge: user module settings overlay shared", function()
            local shared = {
                projects = {
                    App = { type = "cmake", path = "App", type_config = {
                        compile_commands_from = "shared-config",
                    }},
                },
            }
            local user = {
                projects = {
                    App = { type = "cmake", path = "App", type_config = {
                        compile_commands_from = "user-config",
                    }},
                },
            }
            local merged = workspace.merge_configs(user, shared)
            assert.equals("user-config", merged.projects.App.type_config.compile_commands_from)
        end)

        it("per-config merge: shared-only project has empty provenance", function()
            local shared = {
                projects = {
                    App = { type = "cmake", path = "App", type_config = {} },
                },
            }
            local _, _, _, prov = workspace.merge_configs(nil, shared)
            assert.are.same({}, prov.App)
        end)
    end)
end)
