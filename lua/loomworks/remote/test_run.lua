--- loomworks/remote/test_run.lua — named test executables (spec §16.16,
--- §18.6): results-option handling, outcome judgement and JUnit output shared
--- by the local and the device path of `lw test --target <exe>`.
---
--- A named executable runs directly (never through the native batch runner)
--- with its framework's machine-readable results option; the results file is
--- parsed with the same parser as local results (gtest.parse_xml_results).
--- Outcome = failed when any of: non-zero exit status; the results contain a
--- failure or error; results were requested but no results file came back;
--- a crash report was collected (device runs); a transport failure.

local M = {}

--- Device-relative directory (under the staging root) for results files.
M.RESULTS_REL = ".loomworks/results"

--- Summarise parsed results.
--- @param results table[]|nil gtest.parse_xml_results output
--- @return { total: integer, failed: integer, errored: integer, skipped: integer, failed_ids: string[] }
function M.count(results)
    local c = { total = 0, failed = 0, errored = 0, skipped = 0, failed_ids = {} }
    for _, r in ipairs(results or {}) do
        c.total = c.total + 1
        if r.status == "failed" then
            c.failed = c.failed + 1
            c.failed_ids[#c.failed_ids + 1] = (r.test_id or "?"):gsub("^test:", "")
        elseif r.status == "errored" then
            c.errored = c.errored + 1
            c.failed_ids[#c.failed_ids + 1] = (r.test_id or "?"):gsub("^test:", "")
        elseif r.status == "skipped" then
            c.skipped = c.skipped + 1
        end
    end
    return c
end

--- Judge an executable's outcome (spec §18.6).
--- @param o { status: integer|nil, results_requested: boolean, results: table[]|nil, results_missing: boolean, crashes?: integer, transport_error?: string }
--- @return boolean failed, string[] reasons
function M.judge(o)
    local reasons = {}
    if o.transport_error then reasons[#reasons + 1] = "device/transport failure" end
    if o.status ~= nil and o.status ~= 0 then reasons[#reasons + 1] = "exit status " .. o.status end
    if o.status == nil and not o.transport_error then reasons[#reasons + 1] = "no exit status" end
    if o.results_requested and o.results_missing then reasons[#reasons + 1] = "no results file came back" end
    local c = M.count(o.results)
    if c.failed + c.errored > 0 then
        reasons[#reasons + 1] = (c.failed + c.errored) .. " failed test" .. ((c.failed + c.errored) == 1 and "" or "s")
    end
    if (o.crashes or 0) > 0 then reasons[#reasons + 1] = "crash report collected" end
    return #reasons > 0, reasons
end

local function xml_escape(s)
    return (tostring(s or ""):gsub("[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" })
        :gsub("[%z\1-\8\11\12\14-\31]", ""))
end

--- Render parsed results as JUnit XML.
--- @param name string suite name (the executable)
--- @param results table[]
--- @return string
function M.junit_xml(name, results)
    local c = M.count(results)
    local by_class, order = {}, {}
    for _, r in ipairs(results or {}) do
        local id = (r.test_id or "test:?"):gsub("^test:", "")
        local cls, tname = id:match("^(.*)%.([^%.]+)$")
        if not cls then cls, tname = name, id end
        if not by_class[cls] then by_class[cls] = {}; order[#order + 1] = cls end
        table.insert(by_class[cls], { name = tname, r = r })
    end
    local out = { '<?xml version="1.0" encoding="UTF-8"?>',
        string.format('<testsuites name="%s" tests="%d" failures="%d" errors="%d" skipped="%d">',
            xml_escape(name), c.total, c.failed, c.errored, c.skipped) }
    for _, cls in ipairs(order) do
        local cases = by_class[cls]
        local f, e, sk = 0, 0, 0
        for _, k in ipairs(cases) do
            if k.r.status == "failed" then f = f + 1 elseif k.r.status == "errored" then e = e + 1
            elseif k.r.status == "skipped" then sk = sk + 1 end
        end
        out[#out + 1] = string.format('  <testsuite name="%s" tests="%d" failures="%d" errors="%d" skipped="%d">',
            xml_escape(cls), #cases, f, e, sk)
        for _, k in ipairs(cases) do
            local time = k.r.duration and string.format(' time="%.3f"', k.r.duration / 1000) or ""
            local head = string.format('    <testcase classname="%s" name="%s"%s', xml_escape(cls), xml_escape(k.name), time)
            if k.r.status == "failed" then
                out[#out + 1] = head .. ">"
                out[#out + 1] = '      <failure message="' .. xml_escape((k.r.message or "failed"):match("[^\n]*"))
                    .. '">' .. xml_escape(k.r.message or "") .. "</failure>"
                out[#out + 1] = "    </testcase>"
            elseif k.r.status == "errored" then
                out[#out + 1] = head .. ">"
                out[#out + 1] = '      <error message="' .. xml_escape((k.r.message or "error"):match("[^\n]*"))
                    .. '">' .. xml_escape(k.r.message or "") .. "</error>"
                out[#out + 1] = "    </testcase>"
            elseif k.r.status == "skipped" then
                out[#out + 1] = head .. "><skipped/></testcase>"
            else
                out[#out + 1] = head .. "/>"
            end
        end
        out[#out + 1] = "  </testsuite>"
    end
    out[#out + 1] = "</testsuites>"
    return table.concat(out, "\n") .. "\n"
end

--- The JUnit output path for one executable: the requested path itself when
--- a single executable runs, else `<stem>-<name><ext>`.
--- @param junit string
--- @param name string
--- @param several boolean
--- @return string
function M.junit_path(junit, name, several)
    if not several then return junit end
    local stem, ext = junit:match("^(.*)(%.[^./\\]+)$")
    local safe = tostring(name):gsub("[^%w%._%-]", "_")
    if stem then return stem .. "-" .. safe .. ext end
    return junit .. "-" .. safe
end

--- Write a file (creating its directory).
--- @return boolean ok, string|nil err
function M.write_file(path, content)
    local dir = path:match("^(.*)[/\\][^/\\]+$")
    if dir then vim.fn.mkdir(dir, "p") end
    local f, err = io.open(path, "wb")
    if not f then return false, tostring(err) end
    f:write(content)
    f:close()
    return true
end

--- The `before_exec` hook of a device test run (spec §18.6): detect the
--- framework with the list probe executed on the device; for gtest, remove a
--- stale results file and point `--gtest_output` at a device-side file in the
--- staging root. Returns the hook and a state table (`framework`,
--- `results_name`).
--- @param name string executable base name
--- @return function hook, table state
function M.device_hook(name)
    local gtest = require("loomworks.gtest")
    local st = {}
    local safe = tostring(name):gsub("[^%w%._%-]", "_")
    local rel = M.RESULTS_REL .. "/" .. safe .. ".xml"
    local function hook(plan, dev)
        local status, lines = dev.probe({ "--gtest_list_tests" })
        if status == nil then error("framework probe failed: " .. tostring(lines), 0) end
        if status == 0 and gtest.looks_like_gtest(table.concat(lines or {}, "\n")) then
            st.framework = "gtest"
            dev.mkdir(M.RESULTS_REL)
            dev.remove({ rel })
            plan.argv[#plan.argv + 1] = "--gtest_output=xml:" .. plan.root .. "/" .. rel
            st.results_name = safe .. ".xml"
            return { { name = st.results_name, device_rel = rel } }
        end
        return {}
    end
    return hook, st
end

return M
