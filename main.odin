package famtree

import "core:mem"
import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

DEFAULT_PERSON_WIDTH  :: 80
DEFAULT_PERSON_HEIGHT :: 30
DEFAULT_PERSON_PAD    :: 5

DisplayOpts :: struct {
    screen: [2]f32,
    offset: [2]f32,
    zoom: f32,
}

draw_layout :: proc(pm: PersonManager, layout: Layout, opts: DisplayOpts) {
    using rl
    pw := opts.zoom*DEFAULT_PERSON_WIDTH
    ph := opts.zoom*DEFAULT_PERSON_HEIGHT
    pp := opts.zoom*DEFAULT_PERSON_PAD
    for row, i in layout.rows {
        y := f32(i32(i) - layout.coord_offset.y)*(ph + pp)
        for el in row.data {
            x := (el.x.(f32) - f32(layout.coord_offset.x))*(pw + pp)
            DrawRectangleV({ x, y }, { pw, ph }, GRAY)
            DrawText(strings.clone_to_cstring(person_get(pm, el.ph).name), i32(x + pp), i32(y + pp), i32(ph - 2*pp), WHITE)
        }
    }
}

main :: proc() {
    using rl
    win_width  : i32 = 800
    win_height : i32 = 600
    SetConfigFlags({.WINDOW_RESIZABLE})
    InitWindow(win_width, win_height, "Family Tree Maker")
    SetTargetFPS(60)

    font := GetFontDefault()

    pm := person_manager_init()
    samuel := person_add(&pm, Person{ name = "Samuel", birth = { year = 2000 }})
    val    := person_add(&pm, Person{ name = "Val",    birth = { year = 2003 }})
    annika := person_add(&pm, Person{ name = "Annika", birth = { year = 2007 }})
    rel_add(&pm, val,    Rel{ person = samuel, type = .Friend })
    rel_add(&pm, val,    Rel{ person = annika, type = .Friend })
    rel_add(&pm, samuel, Rel{ person = annika, type = .Friend })

    layout := layout_tree(pm, val, LayoutOpts{ max_distance = 5, rels_to_show = {.Friend} })
    fmt.println(layout)

    for !WindowShouldClose() {
        if IsWindowResized() {
            win_width  = GetScreenWidth()
            win_height = GetScreenHeight()
        }
        display_opts := DisplayOpts {
            screen = { f32(win_width), f32(win_height) },
            offset = { 0, 0 },
            zoom   = 1,
        }

        BeginDrawing()
            ClearBackground(BLACK)
            draw_layout(pm, layout, display_opts)
            DrawFPS(10, 10)

        EndDrawing()
    }

    CloseWindow()
}