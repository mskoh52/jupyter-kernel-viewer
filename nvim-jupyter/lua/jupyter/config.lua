local M = {}

M.defaults = {
  python_path = "python3",
  mappings = {
    execute_prefix = "<leader>jx",  -- normal: operator prefix; <prefix><prefix> = line; visual: execute selection
    interrupt      = "<leader>ji",
    connect        = "<leader>jc",
    disconnect     = "<leader>jC",
    restart        = "<leader>jr",
  },
}

return M
