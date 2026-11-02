vim.filetype.add({
    extension = {
        gotmpl = "gotmpl",
        tmpl = "gotmpl",
        j2 = "jinja",
        jinja = "jinja",
        jinja2 = "jinja",
    },
    pattern = {
        [".*/templates/.*%.ya?ml"] = function(path)
            if vim.fs.root(path, { "Chart.yaml" }) then
                return "helm"
            end
        end,
        [".*/templates/.*%.tpl"] = function(path)
            if vim.fs.root(path, { "Chart.yaml" }) then
                return "helm"
            end
        end,
    },
})
