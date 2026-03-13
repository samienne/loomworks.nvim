local M = {}

local uv = vim.uv or vim.loop

--- Read a file synchronously.
--- @param path string
--- @return string|nil content, string|nil err
function M.read_file(path)
  local fd, err = uv.fs_open(path, "r", 438) -- 0666
  if not fd then return nil, err end
  local stat, stat_err = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, stat_err
  end
  local data, read_err = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not data then return nil, read_err end
  return data, nil
end

--- Write data to path atomically:
---   1. Write to path..".tmp"
---   2. fsync the fd
---   3. If path exists, rename path -> path..".bak"
---   4. Rename tmp -> path (with retry on Windows)
--- @param path string
--- @param data string
--- @return boolean ok, string|nil err
function M.write_file_atomic(path, data)
  local tmp = path .. ".tmp"

  local fd, err = uv.fs_open(tmp, "w", 438)
  if not fd then return false, "open tmp: " .. (err or "unknown") end

  local _, write_err = uv.fs_write(fd, data, 0)
  if write_err then
    uv.fs_close(fd)
    uv.fs_unlink(tmp)
    return false, "write: " .. write_err
  end

  uv.fs_fsync(fd)
  uv.fs_close(fd)

  -- Rotate existing file to .bak (best-effort)
  if uv.fs_stat(path) then
    uv.fs_rename(path, path .. ".bak")
  end

  -- Rename tmp -> target, with retry for Windows lock contention
  local max_retries = 5
  local retry_delay_ms = 50
  for i = 1, max_retries do
    local ok, rename_err, code = uv.fs_rename(tmp, path)
    if ok then return true, nil end
    if code ~= "EACCES" and code ~= "EPERM" then
      return false, "rename: " .. (rename_err or "unknown")
    end
    if i < max_retries then
      uv.sleep(retry_delay_ms)
    end
  end
  return false, "rename failed after retries (file locked?)"
end

--- Read JSON from path. Falls back to path..".bak" on failure.
--- @param path string
--- @return table|nil data, string|nil err
function M.read_json(path)
  local content, read_err = M.read_file(path)
  if content then
    local ok, decoded = pcall(vim.json.decode, content)
    if ok and type(decoded) == "table" then
      return decoded, nil
    end
  end

  -- Try .bak fallback
  local bak = path .. ".bak"
  local bak_content, bak_err = M.read_file(bak)
  if not bak_content then
    return nil, read_err or bak_err or "file not found"
  end

  local ok, decoded = pcall(vim.json.decode, bak_content)
  if ok and type(decoded) == "table" then
    vim.notify("loomworks: loaded from backup: " .. bak, vim.log.levels.WARN)
    return decoded, nil
  end

  return nil, "failed to decode JSON from both " .. path .. " and " .. bak
end

--- Naively pretty-print a compact JSON string with 2-space indentation.
--- @param json string compact JSON
--- @return string pretty JSON
function M._pretty_json(json)
  local indent = 0
  local buf = {}
  local in_string = false
  local i = 1
  local len = #json

  while i <= len do
    local c = json:sub(i, i)

    if in_string then
      buf[#buf + 1] = c
      if c == "\\" then
        -- skip escaped character
        i = i + 1
        buf[#buf + 1] = json:sub(i, i)
      elseif c == '"' then
        in_string = false
      end
    elseif c == '"' then
      in_string = true
      buf[#buf + 1] = c
    elseif c == "{" or c == "[" then
      indent = indent + 1
      buf[#buf + 1] = c
      buf[#buf + 1] = "\n"
      buf[#buf + 1] = string.rep("  ", indent)
    elseif c == "}" or c == "]" then
      indent = indent - 1
      buf[#buf + 1] = "\n"
      buf[#buf + 1] = string.rep("  ", indent)
      buf[#buf + 1] = c
    elseif c == "," then
      buf[#buf + 1] = ","
      buf[#buf + 1] = "\n"
      buf[#buf + 1] = string.rep("  ", indent)
    elseif c == ":" then
      buf[#buf + 1] = ": "
    elseif c ~= " " and c ~= "\n" and c ~= "\r" and c ~= "\t" then
      buf[#buf + 1] = c
    end

    i = i + 1
  end

  return table.concat(buf) .. "\n"
end

--- Write table as JSON atomically.
--- @param path string
--- @param tbl table
--- @return boolean ok, string|nil err
function M.write_json(path, tbl)
  local ok, encoded = pcall(vim.json.encode, tbl)
  if not ok then return false, "json encode: " .. tostring(encoded) end
  -- Pretty-print: 2-space indentation
  local pretty = M._pretty_json(encoded)
  return M.write_file_atomic(path, pretty)
end

--- Ensure a directory exists (mkdir -p equivalent).
--- @param path string
--- @return boolean ok, string|nil err
function M.ensure_dir(path)
  local stat = uv.fs_stat(path)
  if stat and stat.type == "directory" then return true, nil end
  local ok, err = vim.fn.mkdir(path, "p")
  if ok == 0 then return false, err end
  return true, nil
end

--- Recursively remove a directory tree.
--- @param dir string
--- @return boolean ok, string|nil err
function M.rm_rf(dir)
  local stat = uv.fs_stat(dir)
  if not stat then return true, nil end
  if stat.type ~= "directory" then
    local ok, err = uv.fs_unlink(dir)
    if not ok then return false, "unlink " .. dir .. ": " .. (err or "unknown") end
    return true, nil
  end

  local handle = uv.fs_scandir(dir)
  if not handle then return true, nil end

  local errors = {}
  while true do
    local name, ftype = uv.fs_scandir_next(handle)
    if not name then break end
    local full = dir .. "/" .. name
    if ftype == "directory" then
      local ok, err = M.rm_rf(full)
      if not ok then errors[#errors + 1] = err end
    else
      local ok, err = uv.fs_unlink(full)
      if not ok then errors[#errors + 1] = "unlink " .. full .. ": " .. (err or "unknown") end
    end
  end

  local ok, err = uv.fs_rmdir(dir)
  if not ok then errors[#errors + 1] = "rmdir " .. dir .. ": " .. (err or "unknown") end

  if #errors > 0 then
    return false, table.concat(errors, "; ")
  end
  return true, nil
end

--- Recursively remove a directory tree asynchronously via subprocess.
--- Uses rm -rf on Unix, cmd /c rd /s /q on Windows.
--- @param dir string
--- @param callback fun(ok: boolean, err: string|nil)
function M.rm_rf_async(dir, callback)
  local stat = uv.fs_stat(dir)
  if not stat then
    callback(true, nil)
    return
  end

  local cmd
  if vim.fn.has("win32") == 1 then
    -- Normalize to backslashes for Windows rd command
    local win_dir = dir:gsub("/", "\\")
    if stat.type == "directory" then
      cmd = { "cmd", "/c", "rd", "/s", "/q", win_dir }
    else
      cmd = { "cmd", "/c", "del", "/f", "/q", win_dir }
    end
  else
    cmd = { "rm", "-rf", dir }
  end

  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code == 0 then
        callback(true, nil)
      else
        local err = result.stderr or ""
        if err == "" then err = "exit code " .. result.code end
        callback(false, err)
      end
    end)
  end)
end

return M
