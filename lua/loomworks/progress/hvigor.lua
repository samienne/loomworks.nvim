--- loomworks/progress/hvigor.lua — Hvigor progress parser.
--- Parses lines like:
---   > hvigor Finished :entry:default@CompileArkTS... after 15 s 299 ms
---   > hvigor UP-TO-DATE :entry:default@PreBuild...
---   > hvigor WARN: Base Setup System [OHOS]

--- @param line string
--- @return loomworks.ProgressUpdate|nil
local function parse(line)
    -- Finished step: "> hvigor Finished :module:target@Step... after N s M ms"
    local step = line:match("Finished :[^@]+@(.-)%.%.%. after")
    if step then
        return { message = step }
    end

    -- Up-to-date step: "> hvigor UP-TO-DATE :module:target@Step..."
    step = line:match("UP%-TO%-DATE :[^@]+@(.-)%.%.%.")
    if step then
        return { message = step .. " (cached)" }
    end

    -- Build result: "> hvigor BUILD SUCCESSFUL in N s M ms"
    if line:match("BUILD SUCCESSFUL") then
        return { message = "BUILD SUCCESSFUL" }
    end

    -- Build failure
    if line:match("BUILD FAILED") then
        return { message = "BUILD FAILED" }
    end

    return nil
end

return parse
