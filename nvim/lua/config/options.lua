vim.g.mapleader = ","
vim.g.maplocalleader = ","

vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

local opt = vim.opt

opt.encoding = "utf-8"
opt.fileencoding = "utf-8"
opt.fileformats = { "unix", "dos", "mac" }

opt.number = true
opt.cursorline = true
opt.scrolloff = 3
opt.signcolumn = "yes"
opt.termguicolors = true
opt.splitright = true
opt.splitbelow = true
opt.title = true
opt.titlestring = "%f"

opt.ignorecase = true
opt.smartcase = true
opt.hlsearch = true
opt.incsearch = true

opt.expandtab = true
opt.tabstop = 4
opt.softtabstop = 4
opt.shiftwidth = 4

opt.mouse = "a"
opt.clipboard = "unnamedplus"

opt.autoread = true
opt.swapfile = false
opt.backup = false
opt.undofile = true
opt.updatetime = 250
