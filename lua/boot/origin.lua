-- Where lw releases are published, by version.
--
-- lw moved repositories at 0.2: every release below 0.2 (0.1.x, pre-releases
-- included) is published in samienne/loomworks.nvim and stays there; every
-- release from 0.2.0 on (0.2.0-beta.1 included) in samienne/loomworks. A
-- version's origin is fixed by the version alone — there is no fallback to the
-- other repository. The launcher templates (boot.launcher) apply the same rule
-- in sh/cmd, by the same prefix test: a version starting `0.0.` or `0.1.` is
-- legacy, anything else is current.
--
-- Queries for the LATEST release only ever go to the current repository. A
-- release-url override (LOOMWORKS_RELEASE_URL / `release-url`) is one mirror for
-- all versions; boot.update applies it before consulting this module.
--
-- Pure and dependency-free.

local M = {}

M.GITHUB = "https://github.com"

-- The repository lw is published in from 0.2.0 on.
M.REPO = "samienne/loomworks"

-- The repository every lw release below 0.2 was published in.
M.LEGACY_REPO = "samienne/loomworks.nvim"

--- Is `version` below 0.2 (published in the legacy repository)?
--- @param version string a release version (already validated by the caller)
--- @return boolean
function M.is_legacy(version)
  return tostring(version):match("^0%.[01]%.") ~= nil
end

--- The `owner/name` repository `version` is published in.
--- @param version string
--- @return string
function M.release_repo(version)
  return M.is_legacy(version) and M.LEGACY_REPO or M.REPO
end

--- The repository URL `version` is published in.
--- @param version string
--- @return string
function M.release_origin(version)
  return M.GITHUB .. "/" .. M.release_repo(version)
end

--- The URL directory holding `version`'s release assets.
--- @param version string
--- @return string
function M.download_base(version)
  return M.release_origin(version) .. "/releases/download/v" .. version
end

-- The newest non-prerelease's assets (GitHub resolves `latest`): the `stable`
-- channel. Only the current repository.
M.LATEST_DOWNLOAD = M.GITHUB .. "/" .. M.REPO .. "/releases/latest/download"

-- The releases API of the current repository (the `unstable` channel's query).
M.RELEASES_API = "https://api.github.com/repos/" .. M.REPO .. "/releases"

return M
