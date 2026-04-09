-- Kernel manager UI: floating window showing all kernels on a Jupyter server
local M = {}

M._win = nil
M._buf = nil
M._server_url = nil
M._kernels = {}
M._aliases = {}
M._host = nil
M._port = nil
M._base_path = nil
M._token = nil
M._line_offset = 3  -- 0-indexed line where kernel list starts (after header lines)

local alias_file = vim.fn.stdpath("data") .. "/jupyter_kernel_aliases.json"

local uv = vim.uv or vim.loop

local function load_aliases()
  local ok, data = pcall(vim.fn.readfile, alias_file)
  if not ok or #data == 0 then return {} end
  local ok2, decoded = pcall(vim.fn.json_decode, table.concat(data, "\n"))
  if ok2 and type(decoded) == "table" then return decoded end
  return {}
end

local function save_aliases(aliases)
  local ok, encoded = pcall(vim.fn.json_encode, aliases)
  if ok then
    vim.fn.writefile({ encoded }, alias_file)
  end
end

local function parse_url(url)
  -- url like: http://localhost:8888?token=abc
  --        or http://localhost:8888/path/?token=abc
  local scheme, host, port_str, path, query = url:match("^(https?)://([^:/]+):?(%d*)(/?[^?]*)%??(.*)$")
  local port = tonumber(port_str) or (scheme == "https" and 443 or 80)
  path = path:gsub("/$", "")  -- strip trailing slash
  local token = query:match("token=([^&]+)") or ""
  return host, port, path, token
end

local function with_token(path)
  if M._token ~= "" then
    local sep = path:find("?", 1, true) and "&" or "?"
    return path .. sep .. "token=" .. M._token
  end
  return path
end

local function http_request(method, path, body, callback)
  -- callback(ok, response_body_string)
  uv.getaddrinfo(M._host, nil, { socktype = "stream", protocol = "tcp" }, function(err, res)
    if err or not res or #res == 0 then
      vim.schedule(function() callback(false, err or "getaddrinfo failed") end)
      return
    end

    local tcp = uv.new_tcp()
    tcp:connect(res[1].addr, M._port, function(cerr)
      if cerr then
        vim.schedule(function() callback(false, cerr) end)
        tcp:close()
        return
      end

      -- Build HTTP request
      local host_header = M._host .. ":" .. tostring(M._port)
      local req_lines = {
        method .. " " .. path .. " HTTP/1.1",
        "Host: " .. host_header,
        "Connection: close",
      }
      if body and body ~= "" then
        table.insert(req_lines, "Content-Type: application/json")
        table.insert(req_lines, "Content-Length: " .. tostring(#body))
      end
      table.insert(req_lines, "")
      table.insert(req_lines, "")
      local request = table.concat(req_lines, "\r\n")
      if body and body ~= "" then
        request = request .. body
      end

      tcp:write(request, function(werr)
        if werr then
          vim.schedule(function() callback(false, werr) end)
          tcp:close()
          return
        end

        local buffer = ""
        tcp:read_start(function(rerr, data)
          if rerr then
            vim.schedule(function() callback(false, rerr) end)
            tcp:close()
            return
          end

          if data then
            buffer = buffer .. data
          else
            -- EOF: close and parse
            tcp:close()

            -- Split headers from body
            local header_end = buffer:find("\r\n\r\n")
            if not header_end then
              vim.schedule(function() callback(false, "malformed HTTP response") end)
              return
            end

            local headers = buffer:sub(1, header_end - 1)
            local resp_body = buffer:sub(header_end + 4)

            -- Extract status code from first line
            local status_code = tonumber(headers:match("^HTTP/%S+%s+(%d+)"))
            local ok = status_code ~= nil and status_code >= 200 and status_code < 300

            vim.schedule(function() callback(ok, resp_body) end)
          end
        end)
      end)
    end)
  end)
end

local function api_list(callback)
  http_request("GET", with_token(M._base_path .. "/api/kernels"), nil, function(ok, body)
    if not ok then callback(false, { error = body }); return end
    local jok, data = pcall(vim.fn.json_decode, body)
    if jok then callback(true, { kernels = data })
    else callback(false, { error = "bad JSON" }) end
  end)
end

local function api_kill(id, callback)
  http_request("DELETE", with_token(M._base_path .. "/api/kernels/" .. id), nil, function(ok, body)
    callback(ok, ok and { type = "killed", id = id } or { error = body })
  end)
end

local function api_start(kernel_name, callback)
  local body = vim.fn.json_encode({ name = kernel_name })
  http_request("POST", with_token(M._base_path .. "/api/kernels"), body, function(ok, resp_body)
    if not ok then callback(false, { error = resp_body }); return end
    local jok, data = pcall(vim.fn.json_decode, resp_body)
    if jok then callback(true, { kernel = data })
    else callback(false, { error = "bad JSON" }) end
  end)
end

local function api_restart(id, callback)
  http_request("POST", with_token(M._base_path .. "/api/kernels/" .. id .. "/restart"), nil, function(ok, body)
    callback(ok, ok and { type = "restarted", id = id } or { error = body })
  end)
end

local function api_interrupt(id, callback)
  http_request("POST", with_token(M._base_path .. "/api/kernels/" .. id .. "/interrupt"), nil, function(ok, body)
    callback(ok, ok and { type = "interrupted", id = id } or { error = body })
  end)
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "JupyterManagerHeader", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "JupyterManagerKernel", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "JupyterManagerBusy",   { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "JupyterManagerAlias",  { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "JupyterManagerHelp",   { link = "Comment", default = true })
end

local function render_lines(kernels, aliases, server_url)
  local lines = {}
  local connected_id = require("jupyter.kernel")._kernel_id

  table.insert(lines, "  Server: " .. (server_url or ""))
  table.insert(lines, "")

  for i, k in ipairs(kernels) do
    local short_id = k.id:sub(1, 8)
    local state = k.execution_state or "unknown"
    local alias = aliases[k.id]
    local connected_marker = (k.id == connected_id) and "*" or " "
    local bullet = alias and "●" or "○"

    local line = string.format("  %s%d  %s %-12s [%s]",
      connected_marker, i, bullet, k.name or "?", short_id)

    if alias then
      line = line .. '  "' .. alias .. '"'
    end

    line = line .. "  " .. state
    table.insert(lines, line)
  end

  table.insert(lines, "")
  table.insert(lines, "  [d]kill  [r]refresh  [R]restart  [i]interrupt")
  table.insert(lines, "  [n]new   [a]alias    [Enter]connect  [q]close")

  return lines
end

local function apply_highlights(buf, kernels)
  local ns = vim.api.nvim_create_namespace("jupyter_manager_hl")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  -- Header line (line 0)
  vim.api.nvim_buf_add_highlight(buf, ns, "JupyterManagerHeader", 0, 0, -1)

  -- Kernel lines start at line 2 (0-indexed), i.e. M._line_offset
  local connected_id = require("jupyter.kernel")._kernel_id
  for i, k in ipairs(kernels) do
    local lnum = M._line_offset + (i - 1)
    local state = k.execution_state or ""
    local hl = (k.id == connected_id) and "JupyterManagerHeader"
      or (state == "busy" and "JupyterManagerBusy" or "JupyterManagerKernel")
    vim.api.nvim_buf_add_highlight(buf, ns, hl, lnum, 0, -1)
  end

  -- Help lines at the end
  local total_lines = vim.api.nvim_buf_line_count(buf)
  if total_lines >= 2 then
    vim.api.nvim_buf_add_highlight(buf, ns, "JupyterManagerHelp", total_lines - 2, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, ns, "JupyterManagerHelp", total_lines - 1, 0, -1)
  end
end

local function redraw()
  if not M._buf or not vim.api.nvim_buf_is_valid(M._buf) then return end

  local lines = render_lines(M._kernels, M._aliases, M._server_url)

  vim.api.nvim_buf_set_option(M._buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M._buf, "modifiable", false)

  apply_highlights(M._buf, M._kernels)
end

local function refresh(callback)
  api_list(function(ok, result)
    vim.schedule(function()
      if ok and result.kernels then
        M._kernels = result.kernels
      elseif not ok then
        vim.notify("Jupyter manager: " .. tostring(result.error), vim.log.levels.ERROR)
      end
      redraw()
      if callback then callback() end
    end)
  end)
end

local function get_kernel_at_cursor()
  if not M._win or not vim.api.nvim_win_is_valid(M._win) then return nil end
  local cursor = vim.api.nvim_win_get_cursor(M._win)
  local lnum = cursor[1] - 1  -- 0-indexed
  local idx = lnum - M._line_offset + 1
  if idx >= 1 and idx <= #M._kernels then
    return M._kernels[idx], idx
  end
  return nil, nil
end

local function set_keymaps(buf)
  local opts = { noremap = true, silent = true, buffer = buf }

  vim.keymap.set("n", "q", function() M.close() end, opts)
  vim.keymap.set("n", "<Esc>", function() M.close() end, opts)

  vim.keymap.set("n", "r", function()
    refresh()
  end, opts)

  vim.keymap.set("n", "d", function()
    local k = get_kernel_at_cursor()
    if not k then return end
    api_kill(k.id, function(ok, result)
      vim.schedule(function()
        if ok then
          -- If we just killed the connected kernel, stop the bridge
          local bridge = require("jupyter.kernel")
          if bridge._kernel_id == k.id then
            bridge.stop()
            vim.notify("Jupyter: killed connected kernel, disconnected")
          else
            vim.notify("Jupyter: killed kernel " .. k.id:sub(1, 8))
          end
          refresh()
        else
          vim.notify("Jupyter manager kill: " .. tostring(result.error), vim.log.levels.ERROR)
        end
      end)
    end)
  end, opts)

  vim.keymap.set("n", "R", function()
    local k = get_kernel_at_cursor()
    if not k then return end
    api_restart(k.id, function(ok, result)
      vim.schedule(function()
        if ok then
          vim.notify("Jupyter: restarted kernel " .. k.id:sub(1, 8))
        else
          vim.notify("Jupyter manager restart: " .. tostring(result.error), vim.log.levels.ERROR)
        end
        refresh()
      end)
    end)
  end, opts)

  vim.keymap.set("n", "i", function()
    local k = get_kernel_at_cursor()
    if not k then return end
    api_interrupt(k.id, function(ok, result)
      vim.schedule(function()
        if ok then
          vim.notify("Jupyter: interrupted kernel " .. k.id:sub(1, 8))
        else
          vim.notify("Jupyter manager interrupt: " .. tostring(result.error), vim.log.levels.ERROR)
        end
        refresh()
      end)
    end)
  end, opts)

  vim.keymap.set("n", "n", function()
    vim.ui.input({ prompt = "Kernel name (default: python3): " }, function(name)
      if name == nil then return end
      if name == "" then name = "python3" end
      api_start(name, function(ok, result)
        vim.schedule(function()
          if ok then
            local kid = result.kernel and result.kernel.id or ""
            vim.notify("Jupyter: started new kernel " .. kid:sub(1, 8))
          else
            vim.notify("Jupyter manager start: " .. tostring(result.error), vim.log.levels.ERROR)
          end
          refresh()
        end)
      end)
    end)
  end, opts)

  vim.keymap.set("n", "a", function()
    local k = get_kernel_at_cursor()
    if not k then return end
    local current = M._aliases[k.id] or ""
    vim.ui.input({ prompt = "Alias for " .. k.id:sub(1, 8) .. " (empty to clear): ", default = current }, function(alias)
      if alias == nil then return end
      if alias == "" then
        M._aliases[k.id] = nil
      else
        M._aliases[k.id] = alias
      end
      save_aliases(M._aliases)
      redraw()
    end)
  end, opts)

  vim.keymap.set("n", "<CR>", function()
    -- Connect to selected kernel via JupyterConnect with the server URL.
    -- User will see the kernel selection dialog and can pick the right kernel.
    M.close()
    require("jupyter").connect(M._server_url)
  end, opts)
end

function M.open(server_url, python_path)
  M._server_url = server_url
  M._host, M._port, M._base_path, M._token = parse_url(server_url)
  M._aliases = load_aliases()

  setup_highlights()

  -- If window already open, just refresh and focus
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    vim.api.nvim_set_current_win(M._win)
    refresh()
    return
  end

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  M._buf = buf

  -- Compute window size/position (will resize after fetch)
  local width = 60
  local height = 10
  local ui = vim.api.nvim_list_uis()[1]
  local col = math.floor((ui.width - width) / 2)
  local row = math.floor((ui.height - height) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = "rounded",
    title = " Jupyter Kernels ",
    title_pos = "center",
  })
  M._win = win

  set_keymaps(buf)

  -- Auto-close when leaving the window
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      M.close()
    end,
  })

  -- Initial content while loading
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  Server: " .. server_url, "", "  Loading kernels..." })
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  -- Fetch kernels and render
  refresh(function()
    -- Resize window to fit content
    if M._win and vim.api.nvim_win_is_valid(M._win) then
      local n = #M._kernels
      local new_height = math.min(n + 6, 20)
      new_height = math.max(new_height, 6)
      local new_row = math.floor((ui.height - new_height) / 2)
      vim.api.nvim_win_set_config(M._win, {
        relative = "editor",
        width = width,
        height = new_height,
        col = col,
        row = new_row,
      })
    end
  end)
end

function M.close()
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    vim.api.nvim_win_close(M._win, true)
  end
  M._win = nil
  M._buf = nil
end

function M.is_open()
  return M._win ~= nil and vim.api.nvim_win_is_valid(M._win)
end

return M
