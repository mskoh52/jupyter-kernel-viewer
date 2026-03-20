-- Manages the Python bridge subprocess
local M = {}

M._job_id = nil
M._kernel_id = nil
M._callbacks = {}  -- req_id -> callback function
M._ready_cb = nil
M._buf = ""        -- partial line buffer

local function uuid()
  math.randomseed(os.time() + math.random(1000))
  return string.format("%08x-%04x-%04x-%04x-%012x",
    math.random(0, 0xffffffff), math.random(0, 0xffff),
    math.random(0x4000, 0x4fff), math.random(0x8000, 0xbfff),
    math.random(0, 0xffffffffffff))
end

local function dispatch(msg)
  local msg_type = msg.type
  local id = msg.id

  -- kernel_list: pass to ready_cb but don't clear it (ready comes after selection)
  if msg_type == "kernel_list" then
    if M._ready_cb then
      M._ready_cb(msg)
    end
    return
  end

  -- ready / top-level error: terminal setup messages
  if msg_type == "ready" or (msg_type == "error" and id == nil) then
    if M._ready_cb then
      M._ready_cb(msg)
      M._ready_cb = nil
    end
    return
  end

  if id and M._callbacks[id] then
    M._callbacks[id](msg)
    if msg_type == "status" and msg.execution_state == "idle" then
      M._callbacks[id] = nil
    end
  end
end

local function on_stdout(_, data, _)
  -- Neovim splits on newlines before calling this, so data is a list of
  -- line fragments. data[1] continues the previous partial line; the last
  -- element is a new partial line (empty string means a trailing newline).
  data[1] = M._buf .. data[1]
  M._buf = table.remove(data)  -- save last (possibly partial) line
  for _, line in ipairs(data) do
    if line ~= "" then
      local ok, msg = pcall(vim.fn.json_decode, line)
      if ok and type(msg) == "table" then
        dispatch(msg)
      else
        vim.notify("jupyter: bad stdout: " .. line, vim.log.levels.WARN)
      end
    end
  end
end

local function on_stderr(_, data, _)
  for _, line in ipairs(data) do
    if line ~= "" then
      vim.notify("jupyter (stderr): " .. line, vim.log.levels.WARN)
    end
  end
end

local function on_exit(_, code, _)
  M._job_id = nil
  M._kernel_id = nil
  M._callbacks = {}
  M._buf = ""
  if code ~= 0 then
    vim.notify("jupyter: bridge exited with code " .. tostring(code), vim.log.levels.WARN)
  end
end

function M.start(opts)
  opts = opts or {}
  local python = opts.python_path or "python3"

  local script_path = debug.getinfo(1, "S").source:sub(2)
  local script_dir = script_path:match("(.*[/\\])")
  local bridge = script_dir .. "../../python/kernel_bridge.py"

  local cmd = { python, bridge }
  if opts.connection_arg then
    table.insert(cmd, opts.connection_arg)
  end

  M._ready_cb = opts.on_ready
  M._buf = ""

  M._job_id = vim.fn.jobstart(cmd, {
    stdin = "pipe",
    stdout_buffered = false,
    env = { PYDEVD_DISABLE_FILE_VALIDATION = "1" },
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = on_exit,
  })

  if M._job_id <= 0 then
    vim.notify("jupyter: failed to start Python bridge", vim.log.levels.ERROR)
    M._job_id = nil
  end
end

function M.stop()
  if not M.is_running() then return end
  vim.fn.chansend(M._job_id, vim.fn.json_encode({ type = "shutdown" }) .. "\n")
  vim.fn.jobstop(M._job_id)
  M._job_id = nil
  M._kernel_id = nil
  M._callbacks = {}
end

function M.interrupt()
  if not M.is_running() then return end
  vim.fn.chansend(M._job_id, vim.fn.json_encode({ type = "interrupt" }) .. "\n")
end

function M.send_raw(data)
  if M.is_running() then
    vim.fn.chansend(M._job_id, data)
  end
end

function M.execute(code, on_result)
  if not M.is_running() then
    vim.notify("jupyter: kernel not running", vim.log.levels.WARN)
    return nil
  end
  local id = uuid()
  if on_result then
    M._callbacks[id] = on_result
  end
  vim.fn.chansend(M._job_id, vim.fn.json_encode({ type = "execute", id = id, code = code }) .. "\n")
  return id
end

function M.is_running()
  return M._job_id ~= nil and M._job_id > 0
end

return M
