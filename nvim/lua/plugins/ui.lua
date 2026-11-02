return {
    {
        "tomasr/molokai",
        lazy = false,
        priority = 1000,
        config = function()
            vim.cmd.colorscheme("molokai")
        end,
    },
    { "nvim-tree/nvim-web-devicons", lazy = true },
    {
        "nvim-lualine/lualine.nvim",
        event = "VeryLazy",
        dependencies = { "nvim-tree/nvim-web-devicons" },
        opts = {
            options = { theme = "molokai", globalstatus = true },
        },
    },
    {
        "akinsho/bufferline.nvim",
        version = "*",
        event = "VeryLazy",
        dependencies = { "nvim-tree/nvim-web-devicons" },
        opts = {
            options = {
                mode = "buffer",
                separator_style = "thin",
                offsets = {
                    { filetype = "neo-tree", text = "Files", highlight = "Directory", text_align = "left" },
                },
            },
        },
    },
    {
        "nvim-neo-tree/neo-tree.nvim",
        branch = "v3.x",
        lazy = false,
        dependencies = {
            "nvim-lua/plenary.nvim",
            "MunifTanjim/nui.nvim",
            "nvim-tree/nvim-web-devicons",
        },
        keys = {
            { "<leader>n", "<cmd>Neotree toggle<cr>", desc = "File tree" },
        },
        opts = {
            filesystem = {
                follow_current_file = { enabled = true },
                hijack_netrw_behavior = "disabled",
            },
        },
        config = function(_, opts)
            require("neo-tree").setup(opts)

            local min_columns = 120

            local function tree_open()
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "neo-tree" then
                        return true
                    end
                end
                return false
            end

            local function sync_tree()
                local wide = vim.o.columns >= min_columns
                if wide and not tree_open() then
                    vim.cmd("Neotree show")
                elseif not wide and tree_open() then
                    vim.cmd("Neotree close")
                end
            end

            local function open_directory_argument()
                if vim.fn.argc() ~= 1 then
                    return nil
                end
                local dir = vim.fn.fnamemodify(vim.fn.argv(0), ":p")
                if vim.fn.isdirectory(dir) ~= 1 then
                    return nil
                end
                local placeholder = vim.api.nvim_get_current_buf()
                if vim.fn.isdirectory(vim.api.nvim_buf_get_name(placeholder)) ~= 1 then
                    return nil
                end
                vim.cmd.cd(vim.fn.fnameescape(dir))
                return placeholder
            end

            local group = vim.api.nvim_create_augroup("dotfiles-tree-width", { clear = true })
            vim.api.nvim_create_autocmd("VimEnter", {
                group = group,
                callback = function()
                    local placeholder = open_directory_argument()
                    sync_tree()
                    if placeholder and vim.api.nvim_buf_is_valid(placeholder) then
                        pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
                    end
                end,
            })
            vim.api.nvim_create_autocmd("VimResized", {
                group = group,
                callback = sync_tree,
            })
            vim.api.nvim_create_autocmd("QuitPre", {
                group = group,
                callback = function()
                    local current = vim.api.nvim_get_current_win()
                    local others = vim.tbl_filter(function(win)
                        return win ~= current
                    end, vim.api.nvim_list_wins())
                    local has_editor = vim.iter(others):any(function(win)
                        return vim.bo[vim.api.nvim_win_get_buf(win)].filetype ~= "neo-tree"
                    end)
                    if not has_editor then
                        for _, win in ipairs(others) do
                            pcall(vim.api.nvim_win_close, win, true)
                        end
                    end
                end,
            })
        end,
    },
    {
        "folke/which-key.nvim",
        event = "VeryLazy",
        opts = {
            spec = {
                { "<leader>f", group = "find" },
                { "<leader>h", group = "hunks" },
                { "<leader>d", group = "diagnostics" },
                { "<leader>c", group = "code" },
            },
        },
    },
    {
        "lukas-reineke/indent-blankline.nvim",
        main = "ibl",
        event = "BufReadPost",
        opts = {},
        keys = {
            { "<leader>ig", "<cmd>IBLToggle<cr>", desc = "Toggle indent guides" },
        },
    },
    {
        "HiPhish/rainbow-delimiters.nvim",
        event = "BufReadPost",
    },
}
