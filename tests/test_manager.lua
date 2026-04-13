-- Tests for jupyter.manager internals.
-- Run with: nvim --headless -u NONE -l tests/test_manager.lua

local pass, fail = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then io.write("PASS " .. name .. "\n") pass = pass + 1
  else       io.write("FAIL " .. name .. "\n     " .. tostring(err) .. "\n") fail = fail + 1
  end
end
local function eq(got, want)
  if got ~= want then error(("expected %q, got %q"):format(tostring(want), tostring(got)), 2) end
end

-- Package path setup
local test_file = debug.getinfo(1, "S").source:sub(2)
local tests_dir = test_file:match("(.*[/\\])")  -- directory of this test file
local root_dir  = tests_dir .. ".."             -- project root
package.path = root_dir .. "/nvim-jupyter/lua/?.lua;" ..
               root_dir .. "/nvim-jupyter/lua/?/init.lua;" ..
               package.path

local manager = require("jupyter.manager")
local T = manager._testing

-- -------------------------------------------------------------------------
-- Section 1: parse_url
-- -------------------------------------------------------------------------

test("parse_url: basic localhost with token", function()
  local host, port, base, token = T.parse_url("http://localhost:8888?token=abc")
  eq(host,  "localhost")
  eq(port,  8888)
  eq(base,  "")
  eq(token, "abc")
end)

test("parse_url: 127.0.0.1 with port and token", function()
  local host, port, base, token = T.parse_url("http://127.0.0.1:19988?token=testtoken")
  eq(host,  "127.0.0.1")
  eq(port,  19988)
  eq(base,  "")
  eq(token, "testtoken")
end)

test("parse_url: no token defaults to empty string", function()
  local host, port, _, token = T.parse_url("http://localhost:8888")
  eq(host,  "localhost")
  eq(port,  8888)
  eq(token, "")
end)

test("parse_url: https with explicit port", function()
  -- parse_url requires an explicit port when there is no path before the query string;
  -- "https://example.com:443?token=x" is the safe form for this implementation.
  local host, port, _, token = T.parse_url("https://example.com:443?token=x")
  eq(host,  "example.com")
  eq(port,  443)
  eq(token, "x")
end)

test("parse_url: path preserved, token extracted", function()
  local _, _, base, token = T.parse_url("http://localhost:8888/lab?token=abc")
  eq(base,  "/lab")
  eq(token, "abc")
end)

-- -------------------------------------------------------------------------
-- Section 2: render_lines
-- -------------------------------------------------------------------------

-- Ensure kernel module is loaded (no side effects)
require("jupyter.kernel")

test("render_lines: empty kernels has Server header and help lines", function()
  local lines = T.render_lines({}, {}, "http://localhost:8888")
  -- First line contains "Server:"
  assert(lines[1]:find("Server:"), "first line should contain 'Server:'")
  -- Last two lines contain help text
  assert(lines[#lines - 1]:find("%[d%]") or lines[#lines]:find("%[d%]"),
    "help lines should contain '[d]'")
  assert(lines[#lines - 1]:find("%[n%]") or lines[#lines]:find("%[n%]"),
    "help lines should contain '[n]'")
  -- No kernel entries (only header, blank line, blank line before help, 2 help lines)
  eq(#lines, 5)
end)

test("render_lines: one kernel no alias shows name, short id, state", function()
  local kernels = { { id = "abcdef1234567890", name = "python3", execution_state = "idle" } }
  local lines = T.render_lines(kernels, {}, "http://x")
  -- Find the kernel line (3rd line, index 3)
  local kline = lines[3]
  assert(kline:find("python3"),  "kernel line should contain kernel name")
  assert(kline:find("abcdef12"), "kernel line should contain short id")
  assert(kline:find("idle"),     "kernel line should contain execution state")
end)

test("render_lines: kernel with alias shows alias in quotes", function()
  local kernels = { { id = "abcdef1234567890", name = "python3", execution_state = "idle" } }
  local aliases = { ["abcdef1234567890"] = "myalias" }
  local lines = T.render_lines(kernels, aliases, "http://x")
  local kline = lines[3]
  assert(kline:find('"myalias"'), "kernel line should contain quoted alias")
end)

test("render_lines: connected kernel shows asterisk marker", function()
  local kernel_mod = require("jupyter.kernel")
  kernel_mod._kernel_id = "abcdef1234567890"

  local kernels = { { id = "abcdef1234567890", name = "python3", execution_state = "idle" } }
  local lines = T.render_lines(kernels, {}, "http://x")
  local kline = lines[3]

  kernel_mod._kernel_id = nil  -- reset

  assert(kline:find("%*"), "connected kernel line should contain '*'")
end)

-- -------------------------------------------------------------------------
-- Section 3: HTTP integration tests (only if JUPYTER_TEST_URL is set)
-- -------------------------------------------------------------------------

local server_url = os.getenv("JUPYTER_TEST_URL")
if server_url then
  manager._host, manager._port, manager._base_path, manager._token = T.parse_url(server_url)

  local function async(fn)
    local done, ok_, data_ = false, nil, nil
    fn(function(ok, data) ok_ = ok; data_ = data; done = true end)
    assert(vim.wait(5000, function() return done end), "timed out")
    return ok_, data_
  end

  local function list_ids()
    local _, data = async(T.api_list)
    local ids = {}
    for _, k in ipairs(data.kernels) do ids[k.id] = true end
    return ids
  end

  -- merged: verifies creation appears in list, kill removes it from list
  test("api_start and api_kill", function()
    local ok, data = async(function(cb) T.api_start("python3", cb) end)
    assert(ok, tostring(data and data.error))
    local kid = data.kernel.id
    assert(type(kid) == "string" and #kid > 0)

    assert(list_ids()[kid], "new kernel should appear in list")

    local kill_ok = async(function(cb) T.api_kill(kid, cb) end)
    assert(kill_ok)

    assert(not list_ids()[kid], "killed kernel should be gone from list")
  end)

  test("api_restart clears kernel state", function()
    local _, started = async(function(cb) T.api_start("python3", cb) end)
    local kid = started.kernel.id

    local msgs = {}
    local partial = ""
    local job_id = vim.fn.jobstart(
      { "python3", root_dir .. "/nvim-jupyter/python/kernel_bridge.py", server_url },
      {
        stdout_buffered = false,
        on_stdout = function(_, data)
          data[1] = partial .. data[1]
          partial = table.remove(data)
          for _, line in ipairs(data) do
            if line ~= "" then
              local ok, msg = pcall(vim.fn.json_decode, line)
              if ok and type(msg) == "table" then table.insert(msgs, msg) end
            end
          end
        end,
      }
    )
    assert(job_id > 0, "failed to start bridge")

    -- Wait for ready
    assert(vim.wait(10000, function()
      for _, m in ipairs(msgs) do if m.type == "ready" then return true end end
      return false
    end), "bridge did not connect")

    -- Helper: send execute and wait for idle
    local function exec(id, code)
      vim.fn.chansend(job_id, vim.fn.json_encode({type="execute", id=id, code=code}) .. "\n")
      assert(vim.wait(8000, function()
        for _, m in ipairs(msgs) do
          if m.type == "status" and m.id == id and m.execution_state == "idle" then return true end
          if m.type == "error" and m.id == id then return true end
        end
        return false
      end), "execute '" .. id .. "' timed out")
    end

    -- Set x = 42
    exec("set_x", "x = 42")

    -- Verify x == 42
    exec("get_x", "x")
    local got_result = false
    for _, m in ipairs(msgs) do
      if m.type == "execute_result" and m.id == "get_x" then
        assert(m.data and m.data["text/plain"] == "42",
          "expected x=42, got " .. tostring(m.data and m.data["text/plain"]))
        got_result = true
      end
    end
    assert(got_result, "no execute_result for x")

    -- Restart via REST API
    local ok = async(function(cb) T.api_restart(kid, cb) end)
    assert(ok, "restart request should succeed")

    -- Give the kernel a moment to come back up
    vim.wait(1500, function() return false end)

    -- x should now be undefined
    msgs = {}  -- clear so we only look at new messages
    exec("post_restart", "x")
    local got_error = false
    for _, m in ipairs(msgs) do
      if m.type == "error" and m.id == "post_restart" then
        assert(m.ename == "NameError",
          "expected NameError, got " .. tostring(m.ename))
        got_error = true
      end
    end
    assert(got_error, "expected NameError after restart but got none")

    -- Clean up
    vim.fn.chansend(job_id, vim.fn.json_encode({type="shutdown"}) .. "\n")
    vim.fn.jobstop(job_id)
    async(function(cb) T.api_kill(kid, cb) end)
  end)

  -- interrupt: verifies the request succeeds and kernel survives.
  test("api_interrupt", function()
    local _, started = async(function(cb) T.api_start("python3", cb) end)
    local kid = started.kernel.id

    local ok = async(function(cb) T.api_interrupt(kid, cb) end)
    assert(ok, "interrupt request should succeed")
    assert(list_ids()[kid], "kernel should still exist after interrupt")

    async(function(cb) T.api_kill(kid, cb) end)
  end)
else
  io.write("SKIP HTTP tests (JUPYTER_TEST_URL not set)\n")
end

-- -------------------------------------------------------------------------
-- Summary and exit
-- -------------------------------------------------------------------------

io.write(("\n%d passed, %d failed\n"):format(pass, fail))
vim.cmd(fail > 0 and "cq" or "q")  -- cq = quit with error code 1
