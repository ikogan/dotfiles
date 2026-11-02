return {
    {
        "echasnovski/mini.nvim",
        version = false,
        event = "VeryLazy",
        config = function()
            require("mini.align").setup()
            require("mini.pairs").setup()
            require("mini.trailspace").setup()
        end,
    },
    {
        "editorconfig/editorconfig-vim",
        lazy = false,
        init = function()
            vim.g.EditorConfig_exclude_patterns = { "fugitive://.*" }
        end,
    },
    {
        "folke/persistence.nvim",
        lazy = false,
        opts = {},
        config = function(_, opts)
            require("persistence").setup(opts)
            vim.api.nvim_create_autocmd("VimEnter", {
                group = vim.api.nvim_create_augroup("dotfiles-persistence", { clear = true }),
                nested = true,
                callback = function()
                    if vim.fn.argc(-1) == 0 then
                        require("persistence").load()
                    end
                end,
            })
        end,
    },
}
