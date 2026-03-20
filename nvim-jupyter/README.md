# nvim-jupyter

Send code to a Jupyter kernel from Neovim using ZeroMQ.

## Requirements

```bash
pip install jupyter_client pyzmq
```

## Installation

**lazy.nvim:**
```lua
{
  dir = "/path/to/nvim-jupyter",
  config = function()
    require("jupyter").setup()
  end,
}
```

**Manual:**
```lua
vim.opt.rtp:prepend("/path/to/nvim-jupyter")
require("jupyter").setup()
```

## Connecting

`:JupyterConnect` with no argument prompts you to enter a server URL or connection file path.

**Existing kernel via connection file:**
```
:JupyterConnect /path/to/kernel-abc123.json
```
Connection files live in `$(jupyter --runtime-dir)`.

**Running Jupyter server with token auth:**
```
:JupyterConnect http://localhost:8888?token=yourtoken
```
If only one kernel is running it connects automatically. If there are multiple, a picker appears to select one.

## Keymaps

All execute bindings use a single prefix key (`<leader>jx` by default).

| Key | Mode | Action |
|---|---|---|
| `<leader>jxx` | normal | Execute current line |
| `<leader>jx` + motion | normal | Execute over motion or text object |
| `<leader>jx` | visual | Execute selection |
| `<leader>ji` | normal | Interrupt kernel |
| `<leader>jc` | normal | Connect to kernel |
| `<leader>jC` | normal | Disconnect from kernel |

### Motion examples

```
<leader>jxip        execute inner paragraph
<leader>jx3j        execute next 3 lines
<leader>jxaj        execute a cell (requires a cell text object plugin)
```

## Commands

| Command | Description |
|---|---|
| `:JupyterConnect [arg]` | Connect (URL or connection file; prompts if no arg given) |
| `:JupyterDisconnect` | Disconnect and stop the bridge |
| `:JupyterExecuteLine` | Execute current line |
| `:JupyterExecuteVisual` | Execute visual selection |
| `:JupyterInterrupt` | Interrupt the running kernel |

## Configuration

```lua
require("jupyter").setup({
  python_path = "python3",  -- or an absolute path, e.g. "/path/to/.venv/bin/python"
  mappings = {
    execute_prefix = "<leader>jx",  -- <prefix>x=line, <prefix><motion>=motion, <prefix> in visual=selection
    interrupt      = "<leader>ji",
  },
})
```

The last character of execute_prefix is used as the trigger key to run JupyterExecuteLine.

Set `execute_prefix = false` to disable all execute keymaps and use only the commands.

## Statusline

`require("jupyter").statusline()` returns `"♃ <kernel-id>"` when connected, or `""` when disconnected. Add it to your statusline provider:

**lualine:**
```lua
lualine_x = { require("jupyter").statusline }
```

**Raw statusline:**
```lua
vim.o.statusline = vim.o.statusline .. " %{v:lua.require('jupyter').statusline()}"
```
