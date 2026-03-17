local M = {}

local config = require("jupyter.config")
local kernel = require("jupyter.kernel")

M.config = vim.deepcopy(config.defaults)

local _registered_prefix = nil

local function deep_merge(base, override)
  local result = vim.deepcopy(base)
  for k, v in pairs(override) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = deep_merge(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

function M.setup(user_config)
  user_config = user_config or {}
  M.config = deep_merge(config.defaults, user_config)

  local maps = M.config.mappings
  local p = maps.execute_prefix

  -- Clean up previously registered prefix keymaps
  if _registered_prefix then
    local old_p = _registered_prefix
    local old_last = old_p:sub(-1) == ">" and old_p:match("<[^>]+>$") or old_p:sub(-1)
    pcall(vim.keymap.del, "n", old_p)
    pcall(vim.keymap.del, "n", old_p .. old_last)
    pcall(vim.keymap.del, "v", old_p)
    _registered_prefix = nil
  end

  if p then
    _G._jupyter_execute_operator = function(motion_type)
      M.execute_operator(motion_type)
    end
    -- Force-clear any existing mapping on the prefix key before overriding
    pcall(vim.keymap.del, "n", p)
    pcall(vim.keymap.del, "v", p)
    -- <prefix><motion> — operator
    vim.keymap.set("n", p, function()
      vim.o.operatorfunc = "v:lua._jupyter_execute_operator"
      return "g@"
    end, { expr = true, noremap = true, desc = "Jupyter: execute motion/text-object" })
    -- <prefix><last-key> — execute current line (e.g. gxx, <leader>jxx)
    local last_key = p:sub(-1) == ">" and p:match("<[^>]+>$") or p:sub(-1)
    vim.keymap.set("n", p .. last_key, M.execute_line, { noremap = true, desc = "Jupyter: execute line" })
    -- <prefix> in visual — execute selection
    vim.keymap.set("v", p, M.execute_visual, { noremap = true, desc = "Jupyter: execute visual selection" })
    _registered_prefix = p
  end
  if maps.interrupt then
    vim.keymap.set("n", maps.interrupt, M.interrupt, { desc = "Jupyter: interrupt kernel" })
  end
  if maps.connect then
    vim.keymap.set("n", maps.connect, M.connect, { desc = "Jupyter: connect to kernel" })
  end
  if maps.disconnect then
    vim.keymap.set("n", maps.disconnect, M.disconnect, { desc = "Jupyter: disconnect from kernel" })
  end

  vim.api.nvim_create_user_command("JupyterConnect", function(cmd_opts)
    local arg = cmd_opts.args ~= "" and cmd_opts.args or nil
    M.connect(arg)
  end, { nargs = "?", complete = "file", desc = "Connect to Jupyter kernel (file, URL, or new)" })

  vim.api.nvim_create_user_command("JupyterDisconnect", function(_)
    M.disconnect()
  end, { desc = "Disconnect from Jupyter kernel" })

  vim.api.nvim_create_user_command("JupyterExecuteLine", function(_)
    M.execute_line()
  end, { desc = "Execute current line" })

  vim.api.nvim_create_user_command("JupyterExecuteVisual", function(_)
    M.execute_visual()
  end, { range = true, desc = "Execute visual selection" })

  vim.api.nvim_create_user_command("JupyterInterrupt", function(_)
    M.interrupt()
  end, { desc = "Interrupt Jupyter kernel" })
end

local function on_ready_handler(msg)
  if msg.type == "ready" then
    vim.notify("Jupyter: connected" .. (msg.kernel_id and (" [" .. msg.kernel_id:sub(1,8) .. "]") or ""))
  elseif msg.type == "kernel_list" then
    local kernels = msg.kernels
    local labels = vim.tbl_map(function(k)
      local state = k.execution_state ~= "" and (" — " .. k.execution_state) or ""
      return k.name .. " [" .. k.id:sub(1, 8) .. "]" .. state
    end, kernels)
    vim.ui.select(labels, { prompt = "Select kernel: " }, function(_, idx)
      if idx then
        kernel.send_raw(vim.fn.json_encode({ type = "select_kernel", id = kernels[idx].id }) .. "\n")
      else
        vim.notify("Jupyter: no kernel selected", vim.log.levels.WARN)
        kernel.stop()
      end
    end)
  elseif msg.type == "error" then
    vim.notify("Jupyter: " .. tostring(msg.message), vim.log.levels.ERROR)
  end
end

function M.connect(arg)
  if arg then
    kernel.start({
      connection_arg = arg,
      python_path = M.config.python_path,
      on_ready = on_ready_handler,
    })
    return
  end

  local lines = vim.fn.systemlist("jupyter server list 2>/dev/null")
  local servers = {}
  for _, line in ipairs(lines) do
    local url = line:match("^(https?://%S+)%s*::")
    if url then
      table.insert(servers, url)
    end
  end
  table.insert(servers, "Enter manually...")

  vim.ui.select(servers, { prompt = "Connect to Jupyter:" }, function(choice)
    if not choice then return end
    if choice == "Enter manually..." then
      vim.ui.input({ prompt = "Server URL or connection file: " }, function(input)
        if input and input ~= "" then
          kernel.start({
            connection_arg = input,
            python_path = M.config.python_path,
            on_ready = on_ready_handler,
          })
        end
      end)
    else
      kernel.start({
        connection_arg = choice,
        python_path = M.config.python_path,
        on_ready = on_ready_handler,
      })
    end
  end)
end

function M.disconnect()
  kernel.stop()
  vim.notify("Jupyter: disconnected")
end

function M.execute(code)
  if not kernel.is_running() then
    vim.notify("Jupyter: kernel not running. Use :JupyterConnect", vim.log.levels.WARN)
    return
  end
  kernel.execute(code)
end

function M.execute_line()
  M.execute(vim.api.nvim_get_current_line())
end

function M.execute_visual()
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "x", false)
  local buf = vim.api.nvim_get_current_buf()
  local start_pos = vim.api.nvim_buf_get_mark(buf, "<")
  local end_pos   = vim.api.nvim_buf_get_mark(buf, ">")
  local lines = vim.api.nvim_buf_get_lines(buf, start_pos[1] - 1, end_pos[1], false)
  if #lines > 0 then
    -- 2147483647 is vim's MAXCOL, meaning "end of line" — don't trim in that case
    if end_pos[2] < 2147483647 then
      lines[#lines] = lines[#lines]:sub(1, end_pos[2] + 1)
    end
    lines[1] = lines[1]:sub(start_pos[2] + 1)
  end
  M.execute(table.concat(lines, "\n"))
end

-- Called by operatorfunc after a motion/text-object
function M.execute_operator(motion_type)
  local buf = vim.api.nvim_get_current_buf()
  local start_mark = vim.api.nvim_buf_get_mark(buf, "[")
  local end_mark   = vim.api.nvim_buf_get_mark(buf, "]")
  local lines = vim.api.nvim_buf_get_lines(buf, start_mark[1] - 1, end_mark[1], false)

  if motion_type == "char" and #lines > 0 then
    lines[#lines] = lines[#lines]:sub(1, end_mark[2] + 1)
    lines[1] = lines[1]:sub(start_mark[2] + 1)
  end

  M.execute(table.concat(lines, "\n"))
end

function M.interrupt()
  kernel.interrupt()
  vim.notify("Jupyter: interrupt sent")
end

return M
