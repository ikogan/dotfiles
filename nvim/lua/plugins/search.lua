return {
    {
        "ibhagwan/fzf-lua",
        cmd = "FzfLua",
        dependencies = { "nvim-tree/nvim-web-devicons" },
        keys = {
            { "<leader>ff", "<cmd>FzfLua files<cr>", desc = "Find files" },
            { "<leader>fg", "<cmd>FzfLua live_grep<cr>", desc = "Live grep" },
            { "<leader>fb", "<cmd>FzfLua buffers<cr>", desc = "Buffers" },
            { "<leader>fr", "<cmd>FzfLua oldfiles<cr>", desc = "Recent files" },
            { "<leader>fh", "<cmd>FzfLua help_tags<cr>", desc = "Help" },
        },
    },
    {
        "folke/flash.nvim",
        event = "VeryLazy",
        opts = {},
        keys = {
            {
                "s",
                function()
                    require("flash").jump()
                end,
                mode = { "n", "x", "o" },
                desc = "Flash jump",
            },
        },
    },
}
