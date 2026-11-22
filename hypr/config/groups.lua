local mainMod = "SUPER"

hl.config({
    group = {
        insert_after_current = true,
        drag_into_group = 2,
        groupbar = {
            enabled = true,
            blur = true,
            scrolling = false,
            font_size = 10,
            font_weight_active = 700,
            font_weight_inactive = 400,
            gradients = true,
            height = 14,
            render_titles = true,
            text_padding = 4,

            rounding = 8,
            rounding_power = 2.0,
            round_only_edges = true,

            indicator_height = 0,
            indicator_gap = 0,
            gaps_in = 0,
            gaps_out = 0,
            keep_upper_gap = false,
        },
    },
})

hl.bind(mainMod .. " + G", function()
    hl.dispatch(hl.dsp.group.toggle())
end)

hl.bind(mainMod .. " + SHIFT + G", function()
    hl.dispatch(hl.dsp.window.move({ out_of_group = true }))
end)

