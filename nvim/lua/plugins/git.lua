return {
    {
        "lewis6991/gitsigns.nvim",
        event = "BufReadPre",
        opts = {
            on_attach = function(bufnr)
                local gs = require("gitsigns")
                local function map(mode, lhs, rhs, desc, extra)
                    local opts = vim.tbl_extend("force", { buffer = bufnr, desc = desc }, extra or {})
                    vim.keymap.set(mode, lhs, rhs, opts)
                end

                map("n", "]c", function()
                    if vim.wo.diff then
                        return "]c"
                    end
                    vim.schedule(function()
                        gs.nav_hunk("next")
                    end)
                    return "<Ignore>"
                end, "Next changed hunk", { expr = true })

                map("n", "[c", function()
                    if vim.wo.diff then
                        return "[c"
                    end
                    vim.schedule(function()
                        gs.nav_hunk("prev")
                    end)
                    return "<Ignore>"
                end, "Previous changed hunk", { expr = true })

                map("n", "<leader>hp", gs.preview_hunk, "Preview hunk diff")
                map("n", "<leader>hs", gs.stage_hunk, "Stage hunk")
                map("n", "<leader>hr", gs.reset_hunk, "Reset hunk")
                map("n", "<leader>hb", gs.blame_line, "Blame line")
                map("n", "<leader>hd", gs.diffthis, "Diff file against index")
            end,
        },
        config = function(_, opts)
            require("gitsigns").setup(opts)

            vim.keymap.set("n", "<LeftMouse>", function()
                local pos = vim.fn.getmousepos()
                if pos.winid == 0 or pos.line == 0 or pos.wincol > 2 then
                    return "<LeftMouse>"
                end
                vim.schedule(function()
                    vim.api.nvim_set_current_win(pos.winid)
                    vim.api.nvim_win_set_cursor(pos.winid, { pos.line, 0 })
                    require("gitsigns").preview_hunk()
                end)
                return "<Ignore>"
            end, { expr = true, desc = "Click gutter to preview hunk" })
        end,
    },
    {
        "tpope/vim-fugitive",
        cmd = {
            "G",
            "Git",
            "Gedit",
            "Gread",
            "Gwrite",
            "Gdiffsplit",
            "Gvdiffsplit",
            "Gblame",
            "Gbrowse",
        },
    },
}
