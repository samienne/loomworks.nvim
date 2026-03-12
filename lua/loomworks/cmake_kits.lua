local M = {}

--- @class loomworks.CmakeKit
--- @field id string unique identifier (e.g. "msvc-17-2022-enterprise", "ninja-gcc-14.2.0")
--- @field display string human-readable name (e.g. "MSVC 17 2022 (Enterprise)")
--- @field generator string cmake -G value
--- @field compiler_id string|nil compiler identifier
--- @field compiler_path string|nil path to compiler binary
--- @field env table<string, string> environment variables needed
--- @field vcvarsall string|nil path to vcvarsall.bat (MSVC kits)
--- @field arch string|nil target architecture for vcvarsall
--- @field clangd_path string|nil path to clangd binary bundled with this toolchain

--- @type loomworks.CmakeKit[]|nil
M._cached = nil

local uv = vim.uv or vim.loop

--- Run a command synchronously via vim.fn.system and return trimmed stdout.
--- @param cmd string[]
--- @return string|nil output
local function run(cmd)
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then return nil end
  return vim.trim(result)
end

--- Extract version from compiler --version output.
--- @param output string|nil
--- @return string|nil version
local function parse_version(output)
  if not output then return nil end
  return output:match("(%d+%.%d+%.%d+)") or output:match("(%d+%.%d+)")
end

--- Try to find and get version of a compiler binary.
--- @param name string binary name (e.g. "gcc", "clang++-19")
--- @return string|nil path, string|nil version
local function probe_compiler(name)
  if vim.fn.executable(name) ~= 1 then return nil, nil end
  local path = vim.fn.exepath(name)
  if path == "" then return nil, nil end
  local ver_output = run({ path, "--version" })
  local version = parse_version(ver_output)
  return path, version
end

--- Detect Visual Studio installations via vswhere.exe.
--- @return loomworks.CmakeKit[]
local function detect_msvc_kits()
  local kits = {}

  local vswhere = "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
  if not uv.fs_stat(vswhere) then return kits end

  local output = run({ vswhere, "-all", "-format", "json", "-products", "*" })
  if not output then return kits end

  local ok, installs = pcall(vim.json.decode, output)
  if not ok or type(installs) ~= "table" then return kits end

  for _, install in ipairs(installs) do
    if not install.installationPath or not install.catalog then goto continue end

    local version_line = install.catalog.productLineVersion -- "2022", "2019", etc.
    local product_id = install.productId or ""

    local vs_major = ({
      ["2022"] = "17",
      ["2019"] = "16",
      ["2017"] = "15",
    })[version_line]

    if not vs_major then goto continue end

    local product_type = product_id:match("%.(%w+)$") or "Unknown"
    local generator = "Visual Studio " .. vs_major .. " " .. version_line
    local install_path = install.installationPath:gsub("\\", "/")

    local vcvarsall = install_path .. "/VC/Auxiliary/Build/vcvarsall.bat"
    local has_vcvarsall = uv.fs_stat(vcvarsall) ~= nil

    kits[#kits + 1] = {
      id = "msvc-" .. vs_major .. "-" .. version_line .. "-" .. product_type:lower(),
      display = "MSVC " .. vs_major .. " " .. version_line .. " (" .. product_type .. ")",
      generator = generator,
      compiler_id = "msvc-" .. vs_major,
      env = {},
      vcvarsall = has_vcvarsall and vcvarsall or nil,
      arch = "x64",
    }

    ::continue::
  end

  table.sort(kits, function(a, b) return a.id > b.id end)
  return kits
end

--- Try to find a clangd binary alongside a compiler path.
--- Looks for clangd in the same directory as the compiler.
--- @param compiler_path string
--- @return string|nil clangd_path
local function find_sibling_clangd(compiler_path)
  local dir = compiler_path:match("^(.+)/[^/]+$")
  if not dir then return nil end
  local candidate = dir .. "/clangd"
  if vim.fn.executable(candidate) == 1 then return candidate end
  -- Try with .exe on Windows
  candidate = dir .. "/clangd.exe"
  if uv.fs_stat(candidate) then return candidate end
  return nil
end

--- Detect C/C++ compilers in PATH.
--- @return { id: string, display: string, path: string, version: string, family: string, clangd_path: string|nil }[]
local function detect_compilers()
  local compilers = {}
  local seen = {}

  -- Candidate binary names: plain + versioned (gcc-13, clang++-19, etc.)
  local candidates = {}
  for _, base in ipairs({ "gcc", "g++", "clang", "clang++" }) do
    candidates[#candidates + 1] = base
    for v = 8, 25 do
      candidates[#candidates + 1] = base .. "-" .. v
    end
  end

  for _, name in ipairs(candidates) do
    local path, version = probe_compiler(name)
    if not path or not version then goto continue end
    if seen[path] then goto continue end

    local family
    if name:match("^clang") then
      family = "clang"
    elseif name:match("^g[c%+]") then
      family = "gcc"
    end
    if not family then goto continue end

    -- Deduplicate by family+version (gcc and g++ report same version)
    local compound_id = family .. "-" .. version
    if seen[compound_id] then goto continue end
    seen[compound_id] = true
    seen[path] = true

    -- For C compiler, try to find the C++ counterpart
    local is_cpp = name:match("%+%+")
    local cpp_path = path
    if not is_cpp then
      local cpp_name = name:gsub("^gcc", "g++"):gsub("^clang$", "clang++"):gsub("^clang%-(%d)", "clang++-%1")
      local cpp_p = probe_compiler(cpp_name)
      if cpp_p then cpp_path = cpp_p end
    end

    compilers[#compilers + 1] = {
      id = compound_id,
      display = family == "gcc" and ("GCC " .. version) or ("Clang " .. version),
      path = cpp_path,
      version = version,
      family = family,
      clangd_path = find_sibling_clangd(cpp_path),
    }

    ::continue::
  end

  table.sort(compilers, function(a, b)
    if a.family ~= b.family then return a.family < b.family end
    return a.version > b.version
  end)

  return compilers
end

--- Detect all available cmake build kits.
--- @return loomworks.CmakeKit[]
function M.detect()
  if M._cached then return M._cached end

  local kits = {}

  -- MSVC kits (Visual Studio generator, compiler implicit)
  local msvc = detect_msvc_kits()
  for _, kit in ipairs(msvc) do
    kits[#kits + 1] = kit
  end

  -- Ninja kits (one per detected compiler)
  local ninja_available = vim.fn.executable("ninja") == 1
  if ninja_available then
    local compilers = detect_compilers()
    for _, comp in ipairs(compilers) do
      kits[#kits + 1] = {
        id = "ninja-" .. comp.id,
        display = "Ninja - " .. comp.display,
        generator = "Ninja",
        compiler_id = comp.id,
        compiler_path = comp.path,
        clangd_path = comp.clangd_path,
        env = {},
      }
    end

    -- Ninja + MSVC kits (needs vcvarsall environment)
    for _, msvc_kit in ipairs(msvc) do
      if msvc_kit.vcvarsall then
        kits[#kits + 1] = {
          id = "ninja-" .. msvc_kit.compiler_id .. "-" .. msvc_kit.id:match("[^-]+$"),
          display = "Ninja - " .. msvc_kit.display,
          generator = "Ninja",
          compiler_id = msvc_kit.compiler_id,
          env = {},
          vcvarsall = msvc_kit.vcvarsall,
          arch = msvc_kit.arch,
        }
      end
    end
  end

  M._cached = kits
  return kits
end

--- Find a kit by its id.
--- @param id string
--- @return loomworks.CmakeKit|nil
function M.get_by_id(id)
  for _, kit in ipairs(M.detect()) do
    if kit.id == id then return kit end
  end
  return nil
end

--- Find a kit by its display name.
--- @param display string
--- @return loomworks.CmakeKit|nil
function M.get_by_display(display)
  for _, kit in ipairs(M.detect()) do
    if kit.display == display then return kit end
  end
  return nil
end

--- Get the default kit (first MSVC if available, else first Ninja).
--- @return loomworks.CmakeKit|nil
function M.default_kit()
  local kits = M.detect()
  return kits[1]
end

--- Clear cache (for testing or after PATH changes).
function M.clear_cache()
  M._cached = nil
end

return M
