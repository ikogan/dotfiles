return {
    {
        "zbirenbaum/copilot.lua",
        cmd = "Copilot",
        event = "InsertEnter",
        opts = {
            suggestion = {
                enabled = true,
                auto_trigger = true,
                keymap = {
                    accept = false,
                    next = "<M-]>",
                    prev = "<M-[>",
                    dismiss = "<C-]>",
                },
            },
            panel = { enabled = false },
        },
        config = function(_, opts)
            require("copilot").setup(opts)

            vim.keymap.set("i", "<Tab>", function()
                local suggestion = require("copilot.suggestion")
                if suggestion.is_visible() then
                    suggestion.accept()
                else
                    vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "n", false)
                end
            end, { silent = true, desc = "Accept Copilot suggestion or insert tab" })
        end,
    },
    {
        "saghen/blink.cmp",
        version = "1.*",
        event = "InsertEnter",
        opts = {
            keymap = { preset = "default" },
            sources = {
                default = { "path", "snippets", "buffer" },
            },
        },
    },
}
