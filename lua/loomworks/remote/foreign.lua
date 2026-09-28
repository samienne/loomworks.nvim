--- loomworks/remote/foreign.lua — foreign build-target artifacts (spec §18.1).
---
--- A build-target artifact is **foreign** when the Tool that built its
--- ConfigUnit carries a target-platform token, or when the host-executability
--- probe (remote/probe.lua) finds a format/architecture the host cannot run.
--- Invariant (spec §15 #19): a foreign artifact never executes on the host.
--- Every local execution path for a build-target artifact calls
--- `M.check_local` first; the headless run/test paths call `M.classify` to
--- route a foreign artifact to a device runner instead.

local M = {}

local function basename(p)
    return (tostring(p):gsub("\\", "/"):match("([^/]+)$")) or tostring(p)
end

--- @class loomworks.ForeignArtifact
--- @field artifact string absolute host path of the artifact
--- @field name string artifact base name
--- @field unit loomworks.ConfigUnit|nil
--- @field tool loomworks.Tool|nil
--- @field platform string|nil target-platform token (nil for a probe-only mismatch)
--- @field sdk loomworks.SDK|nil SDK that produced the kit
--- @field reason "token"|"probe"
--- @field what string|nil probe description ("an ELF aarch64 executable")

--- Classify an artifact built by `unit`. Returns nil when it is host-runnable.
--- `deps.probe` (injectable) is the probe module.
--- @param unit loomworks.ConfigUnit|nil
--- @param artifact string absolute path
--- @param deps? { probe?: table, host?: table }
--- @return loomworks.ForeignArtifact|nil
function M.classify(unit, artifact, deps)
    deps = deps or {}
    local tool = unit and unit.tool_object and unit:tool_object() or nil
    local token = tool and tool.execution_platform and tool:execution_platform() or nil
    local f = {
        artifact = artifact, name = basename(artifact), unit = unit, tool = tool,
        platform = token, sdk = tool and tool.sdk and tool:sdk() or nil,
    }
    if token then
        f.reason = "token"
        return f
    end
    local probe = deps.probe or require("loomworks.remote.probe")
    local mismatch, what = probe.mismatch(probe.read(artifact), deps.host)
    if mismatch then
        f.reason, f.what = "probe", what
        return f
    end
    return nil
end

--- Kit label for messages.
local function kit_name(tool)
    if not tool then return "?" end
    return tool.key or tool.label or "?"
end

--- The refusal message for a foreign artifact (spec §18.1): names the
--- artifact, the platform and the remedy.
--- @param f loomworks.ForeignArtifact
--- @param remedy? string replaces the default remedy line
--- @return string
function M.refusal(f, remedy)
    local head
    if f.reason == "token" then
        head = string.format("%s was built for %s by kit %s;\n    this host cannot run it.",
            f.name, f.platform, kit_name(f.tool))
    else
        local host = require("loomworks.remote.probe").host()
        head = string.format("%s is %s;\n    this host (%s %s) cannot run it.",
            f.name, f.what or "a foreign executable",
            ({ elf = "ELF", pe = "PE", macho = "Mach-O" })[host.format] or host.format,
            host.arch or "?")
    end
    if not remedy then
        if f.reason == "probe" then
            remedy = "Its kit declares no target platform, so it cannot be routed to a device."
        else
            local runner = require("loomworks.remote.runners").for_foreign(f)
            remedy = runner
                and ("Run it on a device with `lw run` / `lw test --target` (device runner '"
                    .. runner.id .. "').")
                or "No device runner serves that platform."
        end
    end
    return head .. " " .. remedy
end

--- Guard for every LOCAL execution of a build-target artifact (spec §18.1):
--- returns true when the host may run it, else nil + the refusal message.
--- @param unit loomworks.ConfigUnit|nil
--- @param artifact string
--- @param deps? table
--- @return boolean|nil ok, string|nil err, loomworks.ForeignArtifact|nil foreign
function M.check_local(unit, artifact, deps)
    local f = M.classify(unit, artifact, deps)
    if not f then return true end
    return nil, M.refusal(f), f
end

--- Is the unit's kit foreign by token (no artifact needed)? Used to keep host
--- batch runners and discovery probes away from a cross build.
--- @param unit loomworks.ConfigUnit|nil
--- @return string|nil token, loomworks.Tool|nil tool
function M.unit_platform(unit)
    local tool = unit and unit.tool_object and unit:tool_object() or nil
    local token = tool and tool.execution_platform and tool:execution_platform() or nil
    return token, tool
end

return M
