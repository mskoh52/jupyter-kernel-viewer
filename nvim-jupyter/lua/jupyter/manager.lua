-- Floating window UI for managing Jupyter kernels via the `jkm` CLI.
local M = {}

M._win = nil
M._buf = nil
M._kernels = {}      -- list of {id=..., name=...}
M._aliases = {}      -- kernel_id -> alias (nvim-local, persisted to JSON)
M._server_url = nil  -- discovered from `jkm server list`
M._line_offset = 2   -- 0-indexed line where first kernel row appears

local alias_file = vim.fn.stdpath("data") .. "/jupyter_kernel_aliases.json"

local function load_aliases()
  local ok, lines = pcall(vim.fn.readfile, alias_file)
  if not ok or not lines or #lines == 0 then return {} end
  local ok2, decoded = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
  if not ok2 or type(decoded) ~= "table" then return {} end
  return decoded
end

local function save_aliases(t)
  local ok, encoded = pcall(vim.fn.json_encode, t)
  if not ok then return end
  pcall(vim.fn.writefile, { encoded }, alias_file)
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "JupyterManagerHeader", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "JupyterManagerKernel", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "JupyterManagerBusy",   { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "JupyterManagerAlias",  { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "JupyterManagerHelp",   { link = "Comment", default = true })
end

local function jkm(args, callback)
  local out, err = {}, {}
  local cmd = { "jkm" }
  for _, a in ipairs(args) do table.insert(cmd, a) end
  local jid = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data then return end
      for _, l in ipairs(data) do if l ~= "" then table.insert(out, l) end end
    end,
    on_stderr = function(_, data)
      if not data then return end
      for _, l in ipairs(data) do if l ~= "" then table.insert(err, l) end end
    end,
    on_exit = function(_, code)
      vim.schedule(function() callback(code == 0, out, err) end)
    end,
  })
  if jid <= 0 then
    vim.schedule(function() callback(false, {}, { "failed to spawn jkm (is it on PATH?)" }) end)
  end
end

local function jkm_on_server(args, callback)
  -- jkm internally identifies servers by their base URL without query string.
  -- Passing the full URL with ?token=... fails to match.
  local selector = (M._server_url or ""):gsub("%?.*$", "")
  local full = { "--server", selector }
  for _, a in ipairs(args) do table.insert(full, a) end
  jkm(full, callback)
end

-- "ID (name)"
local function parse_kernel_list(lines)
  local r = {}
  for _, line in ipairs(lines) do
    local id, name = line:match("^(%S+)%s+%((.-)%)")
    if id then table.insert(r, { id = id, name = name }) end
  end
  return r
end

-- "URL :: root_dir"
local function parse_server_list(lines)
  local r = {}
  for _, line in ipairs(lines) do
    local url, root = line:match("^(%S+)%s*::%s*(.+)$")
    if url then table.insert(r, { url = url, root = root }) end
  end
  return r
end

local function pick_server(servers, on_pick)
  if #servers == 0 then
    vim.notify("Jupyter: no servers running", vim.log.levels.ERROR)
    return
  end
  if #servers == 1 then
    on_pick(servers[1])
    return
  end
  local labels = vim.tbl_map(function(s)
    return s.url .. "  ::  " .. (s.root or "")
  end, servers)
  vim.ui.select(labels, { prompt = "Jupyter server:" }, function(_, idx)
    if idx then on_pick(servers[idx]) end
  end)
end

local function current_kernel_id()
  local ok, k = pcall(require, "jupyter.kernel")
  if not ok then return nil end
  return k._kernel_id
end

local function resize_window()
  if not (M._win and vim.api.nvim_win_is_valid(M._win)) then return end
  local h = #M._kernels + 6
  if h < 6 then h = 6 end
  if h > 20 then h = 20 end
  pcall(vim.api.nvim_win_set_height, M._win, h)
end

local function redraw()
  if not (M._buf and vim.api.nvim_buf_is_valid(M._buf)) then return end

  local lines = {}
  local server_line = "  Server: " .. (M._server_url or "<none>")
  table.insert(lines, server_line)
  table.insert(lines, "")

  local cur = current_kernel_id()
  local connected_row = nil

  for i, k in ipairs(M._kernels) do
    local marker = (cur and k.id == cur) and "*" or " "
    local short = k.id:sub(1, 8)
    local alias = M._aliases[k.id]
    local state_glyph = alias and "●" or "○"
    local idx = string.format("%2d", i)
    local row = string.format("%s%s  %s %-12s [%s]", marker, idx, state_glyph, k.name or "", short)
    if alias and alias ~= "" then
      row = row .. string.format("  %q", alias)
    end
    if cur and k.id == cur then
      connected_row = #lines
    end
    table.insert(lines, row)
  end

  table.insert(lines, "")
  table.insert(lines, "  [d]stop  [r]refresh  [R]restart  [i]interrupt  [s]switch")
  table.insert(lines, "  [n]new   [a]alias    [Enter]connect  [q]close")

  vim.api.nvim_buf_set_option(M._buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M._buf, "modifiable", false)

  local ns = vim.api.nvim_create_namespace("jupyter_manager")
  vim.api.nvim_buf_clear_namespace(M._buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(M._buf, ns, "JupyterManagerHeader", 0, 0, -1)
  if connected_row then
    vim.api.nvim_buf_add_highlight(M._buf, ns, "JupyterManagerHeader", connected_row, 0, -1)
  end
  local last = #lines - 1
  vim.api.nvim_buf_add_highlight(M._buf, ns, "JupyterManagerHelp", last - 1, 0, -1)
  vim.api.nvim_buf_add_highlight(M._buf, ns, "JupyterManagerHelp", last, 0, -1)

  resize_window()
end

local function refresh(cb)
  jkm_on_server({ "kernel", "list" }, function(ok, out, err)
    if ok then
      M._kernels = parse_kernel_list(out)
    else
      vim.notify("jkm kernel list failed: " .. table.concat(err, " "), vim.log.levels.ERROR)
    end
    redraw()
    if cb then cb() end
  end)
end

local function selected_kernel()
  if not (M._win and vim.api.nvim_win_is_valid(M._win)) then return nil end
  local row = vim.api.nvim_win_get_cursor(M._win)[1] - 1
  local idx = row - M._line_offset + 1
  if idx < 1 or idx > #M._kernels then return nil end
  return M._kernels[idx]
end

function M.close()
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    pcall(vim.api.nvim_win_close, M._win, true)
  end
  M._win = nil
  M._buf = nil
end

function M.is_open()
  return M._win ~= nil and vim.api.nvim_win_is_valid(M._win)
end

local function set_keymaps()
  local opts = { buffer = M._buf, nowait = true, silent = true, noremap = true }

  vim.keymap.set("n", "q", function() M.close() end, opts)
  vim.keymap.set("n", "<Esc>", function() M.close() end, opts)
  vim.keymap.set("n", "r", function() refresh() end, opts)

  vim.keymap.set("n", "s", function()
    jkm({ "server", "list" }, function(ok, out, err)
      if not ok then
        vim.schedule(function()
          vim.notify("jkm server list failed: " .. table.concat(err, " "), vim.log.levels.ERROR)
        end)
        return
      end
      local servers = parse_server_list(out)
      vim.schedule(function()
        pick_server(servers, function(s)
          M._server_url = s.url
          refresh()
        end)
      end)
    end)
  end, opts)

  vim.keymap.set("n", "d", function()
    local k = selected_kernel()
    if not k then return end
    jkm_on_server({ "kernel", "stop", k.id }, function(ok, _, err)
      if not ok then
        vim.notify("jkm kernel stop failed: " .. table.concat(err, " "), vim.log.levels.ERROR)
      else
        local cur = current_kernel_id()
        if cur and cur == k.id then
          local okk, kern = pcall(require, "jupyter.kernel")
          if okk and kern.stop then kern.stop() end
        end
      end
      refresh()
    end)
  end, opts)

  vim.keymap.set("n", "R", function()
    local k = selected_kernel()
    if not k then return end
    jkm_on_server({ "kernel", "restart", k.id }, function(ok, _, err)
      if ok then
        vim.notify("Jupyter: kernel restarted [" .. k.id:sub(1, 8) .. "]")
      else
        vim.notify("jkm kernel restart failed: " .. table.concat(err, " "), vim.log.levels.ERROR)
      end
      refresh()
    end)
  end, opts)

  vim.keymap.set("n", "i", function()
    local k = selected_kernel()
    if not k then return end
    jkm_on_server({ "kernel", "interrupt", k.id }, function(ok, _, err)
      if ok then
        vim.notify("Jupyter: interrupt sent [" .. k.id:sub(1, 8) .. "]")
      else
        vim.notify("jkm kernel interrupt failed: " .. table.concat(err, " "), vim.log.levels.ERROR)
      end
      refresh()
    end)
  end, opts)

  vim.keymap.set("n", "n", function()
    jkm_on_server({ "kernel", "start" }, function(ok, out, err)
      if ok then
        vim.notify("Jupyter: " .. (out[1] or "kernel started"))
      else
        vim.notify("jkm kernel start failed: " .. table.concat(err, " "), vim.log.levels.ERROR)
      end
      refresh()
    end)
  end, opts)

  vim.keymap.set("n", "a", function()
    local k = selected_kernel()
    if not k then return end
    vim.ui.input({ prompt = "Alias for " .. k.id:sub(1, 8) .. ": ", default = M._aliases[k.id] or "" }, function(input)
      if input == nil then return end
      if input == "" then
        M._aliases[k.id] = nil
      else
        M._aliases[k.id] = input
      end
      save_aliases(M._aliases)
      redraw()
    end)
  end, opts)

  vim.keymap.set("n", "<CR>", function()
    local k = selected_kernel()
    if not M._server_url or not k then return end
    M.close()
    require("jupyter").connect(M._server_url, k.id)
  end, opts)
end

local function create_window()
  M._buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M._buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(M._buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(M._buf, "modifiable", false)

  local width = 60
  local height = 6
  local ui = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }
  local row = math.floor((ui.height - height) / 2)
  local col = math.floor((ui.width - width) / 2)

  M._win = vim.api.nvim_open_win(M._buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Jupyter Kernels ",
    title_pos = "center",
  })

  vim.api.nvim_buf_set_option(M._buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, { "  Loading..." })
  vim.api.nvim_buf_set_option(M._buf, "modifiable", false)

  set_keymaps()

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = M._buf,
    once = true,
    callback = function() M.close() end,
  })

  refresh(function() resize_window() end)
end

function M.open()
  M._aliases = load_aliases()
  setup_highlights()

  if M._win and vim.api.nvim_win_is_valid(M._win) then
    vim.api.nvim_set_current_win(M._win)
    refresh()
    return
  end

  jkm({ "server", "list" }, function(ok, out, err)
    if not ok then
      vim.notify("jkm server list failed: " .. table.concat(err, " "), vim.log.levels.ERROR)
      return
    end
    local servers = parse_server_list(out)
    pick_server(servers, function(s)
      M._server_url = s.url
      create_window()
    end)
  end)
end

return M
