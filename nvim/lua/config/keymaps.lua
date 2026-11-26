local map = vim.keymap.set

-- Splits
map("n", "<leader>h", "<cmd>split<cr>", { desc = "Split horizontally" })
map("n", "<leader>v", "<cmd>vsplit<cr>", { desc = "Split vertically" })

-- Window navigation
map("n", "<C-h>", "<C-w>h", { desc = "Window left" })
map("n", "<C-j>", "<C-w>j", { desc = "Window down" })
map("n", "<C-k>", "<C-w>k", { desc = "Window up" })
map("n", "<C-l>", "<C-w>l", { desc = "Window right" })

-- Buffer tabs (bufferline)
map("n", "<Tab>", "<cmd>BufferLineCycleNext<cr>", { desc = "Next buffer tab" })
map("n", "<S-Tab>", "<cmd>BufferLineCyclePrev<cr>", { desc = "Previous buffer tab" })
map("n", "<S-t>", "<cmd>enew<cr>", { desc = "New buffer tab" })
map("n", "<leader>z", "<cmd>bprevious<cr>", { desc = "Previous buffer" })
map("n", "<leader>q", "<cmd>bprevious<cr>", { desc = "Previous buffer" })
map("n", "<leader>x", "<cmd>bnext<cr>", { desc = "Next buffer" })
map("n", "<leader>w", "<cmd>bnext<cr>", { desc = "Next buffer" })
map("n", "<leader>c", function()
    require("mini.bufremove").delete(0, false)
end, { desc = "Close buffer" })

map("n", "<leader>R", function()
    vim.cmd("checktime")
    if package.loaded["gitsigns"] then
        require("gitsigns").refresh()
    end
    if package.loaded["neo-tree"] then
        require("neo-tree.sources.manager").refresh("filesystem")
    end
    if package.loaded["diffview"] then
        vim.cmd("DiffviewRefresh")
    end
end, { desc = "Reload files and refresh tree and git views" })

-- Paths
map("n", "<leader>.", "<cmd>lcd %:p:h<cr>", { desc = "cd to file directory" })
map("n", "<leader>e", ":e <C-r>=expand('%:p:h') . '/'<cr>", { desc = "Open relative to current file" })

-- Search and terminal
map("n", "<leader><space>", "<cmd>nohlsearch<cr>", { desc = "Clear search highlight" })
map("n", "<leader>sh", "<cmd>terminal<cr>", { desc = "Open terminal" })
map("t", "<Esc><Esc>", "<C-\\><C-n>", { desc = "Leave terminal mode" })

-- Visual mode
map("v", "<", "<gv", { desc = "Outdent and keep selection" })
map("v", ">", ">gv", { desc = "Indent and keep selection" })
map("v", "J", ":m '>+1<cr>gv=gv", { silent = true, desc = "Move selection down" })
map("v", "K", ":m '<-2<cr>gv=gv", { silent = true, desc = "Move selection up" })

vim.cmd([[
  cnoreabbrev W! w!
  cnoreabbrev Q! q!
  cnoreabbrev Qall! qall!
  cnoreabbrev Wq wq
  cnoreabbrev Wa wa
  cnoreabbrev wQ wq
  cnoreabbrev WQ wq
  cnoreabbrev W w
  cnoreabbrev Q q
  cnoreabbrev Qall qall
]])
