return {
    {
        "nvim-treesitter/nvim-treesitter",
        branch = "main",
        lazy = false,
        build = ":TSUpdate",
        config = function()
            require("nvim-treesitter").install({
                "bash",
                "gotmpl",
                "helm",
                "jinja",
                "jinja_inline",
                "lua",
                "markdown",
                "markdown_inline",
                "python",
                "query",
                "vim",
                "vimdoc",
                "yaml",
            })

            vim.api.nvim_create_autocmd("FileType", {
                group = vim.api.nvim_create_augroup("dotfiles-treesitter", { clear = true }),
                callback = function(ev)
                    pcall(vim.treesitter.start, ev.buf)
                end,
            })
        end,
    },
    {
        "mfussenegger/nvim-lint",
        event = { "BufReadPost", "BufNewFile" },
        config = function()
            local lint = require("lint")

            local candidates = {
                bash = { "shellcheck" },
                sh = { "shellcheck" },
                python = { "ruff" },
                lua = { "luacheck" },
                dockerfile = { "hadolint" },
            }

            for ft, linters in pairs(candidates) do
                lint.linters_by_ft[ft] = vim.tbl_filter(function(name)
                    return vim.fn.executable(name) == 1
                end, linters)
            end

            vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "InsertLeave" }, {
                group = vim.api.nvim_create_augroup("dotfiles-lint", { clear = true }),
                callback = function()
                    lint.try_lint()
                end,
            })

            vim.keymap.set("n", "<leader>dd", vim.diagnostic.open_float, { desc = "Show diagnostic" })
            vim.keymap.set("n", "<leader>dl", vim.diagnostic.setloclist, { desc = "Diagnostics list" })
        end,
    },
    {
        "stevearc/conform.nvim",
        event = "BufWritePre",
        cmd = { "ConformInfo", "FormatToggle" },
        keys = {
            {
                "<leader>cf",
                function()
                    require("conform").format({ async = true })
                end,
                desc = "Format buffer",
            },
        },
        opts = {
            formatters_by_ft = {
                bash = { "shfmt" },
                jinja = { "djlint" },
                lua = { "stylua" },
                python = { "ruff_format" },
                sh = { "shfmt" },
                yaml = { "yamlfmt" },
            },
            formatters = {
                shfmt = { prepend_args = { "-i", "4" } },
            },
            format_on_save = function(bufnr)
                if vim.g.disable_autoformat or vim.b[bufnr].disable_autoformat then
                    return
                end
                return { timeout_ms = 500 }
            end,
        },
        config = function(_, opts)
            require("conform").setup(opts)

            vim.api.nvim_create_user_command("FormatToggle", function()
                vim.g.disable_autoformat = not vim.g.disable_autoformat
                vim.notify("Format on save " .. (vim.g.disable_autoformat and "disabled" or "enabled"))
            end, { desc = "Toggle format on save" })
        end,
    },
}
