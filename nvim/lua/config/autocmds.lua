local group = vim.api.nvim_create_augroup("dotfiles", { clear = true })

vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
    group = group,
    command = "checktime",
})

local function is_empty_unnamed(buf)
    return vim.api.nvim_buf_get_name(buf) == ""
        and vim.bo[buf].buftype == ""
        and not vim.bo[buf].modified
        and vim.api.nvim_buf_line_count(buf) == 1
        and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(ev)
        for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
            if info.bufnr ~= ev.buf and is_empty_unnamed(info.bufnr) then
                pcall(vim.api.nvim_buf_delete, info.bufnr, {})
            end
        end
    end,
})

vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "text",
    callback = function()
        vim.opt_local.wrap = true
        vim.opt_local.textwidth = 79
    end,
})

local function has_editorconfig(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    return name ~= "" and #vim.fs.find(".editorconfig", { upward = true, path = vim.fs.dirname(name) }) > 0
end

-- Language indentation defaults. An .editorconfig in the project takes precedence.
vim.api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(ev)
        if has_editorconfig(ev.buf) then
            return
        end

        local ft = ev.match
        if ft == "make" or ft == "go" then
            vim.bo[ev.buf].expandtab = false
        elseif ft == "yaml" or ft == "helm" then
            vim.bo[ev.buf].tabstop = 2
            vim.bo[ev.buf].softtabstop = 2
            vim.bo[ev.buf].shiftwidth = 2
        elseif ft == "python" then
            vim.wo.colorcolumn = "79"
        end
    end,
})
