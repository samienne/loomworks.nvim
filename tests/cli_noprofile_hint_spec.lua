-- Non-interactive "no profile specified" refusal (spec §16.3) names the
-- command the user actually invoked. Previously every verb routed through
-- resolve_build_target/resolve_profile and the hint always read
-- `lw build <profile>`, even for `lw test` / `lw run` / `lw clean` / `lw reset`.
-- Under `nvim --headless` stdin is not a tty, so these take the
-- non-interactive path and die before touching any workspace state.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

local function capture(fn)
  local out_buf, err_buf = {}, {}
  local rw, rs, rex = io.write, io.stderr, os.exit
  io.write = function(s) out_buf[#out_buf + 1] = s end
  io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
  local exit_code
  os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
  local ok, ret = pcall(fn)
  io.write, io.stderr, os.exit = rw, rs, rex
  return {
    ok = ok, ret = ret, exit_code = exit_code,
    stdout = table.concat(out_buf), stderr = table.concat(err_buf),
  }
end

local function ws2()
  return { _profiles = { { key = "Debug" }, { key = "Release" } }, _config_sets = {} }
end

local function refusal(fn)
  local r = capture(fn)
  assert.equals(1, r.exit_code)
  assert.is_truthy(r.stderr:find("no profile specified", 1, true), r.stderr)
  return r.stderr
end

describe("non-interactive no-profile refusal names the invoked command", function()
  it("lw build → lw build <profile>", function()
    local err = refusal(function() cli.cmd_build(ws2(), { "build" }) end)
    assert.is_truthy(err:find("lw build <profile>", 1, true), err)
  end)

  it("lw test → lw test <profile>", function()
    local err = refusal(function() cli.cmd_test(ws2(), { "test" }) end)
    assert.is_truthy(err:find("lw test <profile>", 1, true), err)
    assert.is_falsy(err:find("lw build <profile>", 1, true), err)
  end)

  it("lw clean → lw clean <profile>", function()
    local err = refusal(function() cli.cmd_clean(ws2(), nil) end)
    assert.is_truthy(err:find("lw clean <profile>", 1, true), err)
    assert.is_falsy(err:find("lw build <profile>", 1, true), err)
  end)

  it("lw reset → lw reset <profile>", function()
    local err = refusal(function() cli.cmd_reset(ws2(), { "reset" }) end)
    assert.is_truthy(err:find("lw reset <profile>", 1, true), err)
    assert.is_falsy(err:find("lw build <profile>", 1, true), err)
  end)

  it("lw run → lw run <profile> <target> (one operand is always a target)", function()
    local err = refusal(function() cli.cmd_run(ws2(), { "run" }) end)
    assert.is_truthy(err:find("lw run <profile> <target>", 1, true), err)
    assert.is_falsy(err:find("lw build <profile>", 1, true), err)
  end)

  it("lw run <target> → same run hint", function()
    local err = refusal(function() cli._run_selection(ws2(), { "app" }) end)
    assert.is_truthy(err:find("lw run <profile> <target>", 1, true), err)
  end)

  it("resolve_profile quotes the caller-supplied usage (target set/clear)", function()
    local err = refusal(function()
      cli._resolve_profile(ws2(), nil, { usage = "lw target clear <profile>" })
    end)
    assert.is_truthy(err:find("lw target clear <profile>", 1, true), err)
    assert.is_falsy(err:find("lw build <profile>", 1, true), err)
  end)
end)
