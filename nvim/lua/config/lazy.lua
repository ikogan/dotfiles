local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"

if not vim.uv.fs_stat(lazypath) then
    local out = vim.fn.system({
        "git",
        "clone",
        "--filter=blob:none",
        "--branch=stable",
        "https://github.com/folke/lazy.nvim.git",
        lazypath,
    })
    if vim.v.shell_error ~= 0 then
        error("Failed to clone lazy.nvim:\n" .. out)
    end
end

vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
    spec = { { import = "plugins" } },
    install = { missing = false, colorscheme = { "molokai" } },
    checker = { enabled = false },
    change_detection = { notify = false },
})

local in_container = vim.fn.filereadable("/.dockerenv") == 1

if not in_container then
    vim.api.nvim_create_autocmd("VimEnter", {
        once = true,
        callback = function()
            if #vim.api.nvim_list_uis() == 0 then
                return
            end

            local config = require("lazy.core.config")

            local missing = 0
            for _, plugin in pairs(config.plugins) do
                if not plugin._.installed then
                    missing = missing + 1
                end
            end
            if missing > 0 then
                local choice = vim.fn.confirm(
                    missing .. " Neovim plugin(s) are not installed. Install them now?",
                    "&Yes\n&No",
                    1
                )
                if choice == 1 then
                    vim.cmd("Lazy! install")
                end
                return
            end

            require("lazy.manage").check({ show = false, clear = false }):wait(function()
                require("lazy.manage.checker").fast_check({ report = false })
                local updates = 0
                for _, plugin in pairs(config.plugins) do
                    if plugin._.updates then
                        updates = updates + 1
                    end
                end
                if updates > 0 then
                    local choice = vim.fn.confirm(
                        updates .. " Neovim plugin update(s) available. Update now?",
                        "&Yes\n&No",
                        2
                    )
                    if choice == 1 then
                        vim.cmd("Lazy! update")
                    end
                end
            end)
        end,
    })
end
