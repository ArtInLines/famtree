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
        y := f32(i32(i) - layout.coord_offset.y)*(ph + pp) + opts.offset.y
        for el in row.data {
            x := (el.x.(f32) - f32(layout.coord_offset.x))*(pw + pp) + opts.offset.x
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

    pm        := person_manager_init()
    rene      := person_add(&pm, Person{ name = "Rene",      birth = { year = 1974 }})
    katharina := person_add(&pm, Person{ name = "Katharina", birth = { year = 1975 }})
    samuel    := person_add(&pm, Person{ name = "Samuel",    birth = { year = 2000 }})
    val       := person_add(&pm, Person{ name = "Val",       birth = { year = 2003 }})
    annika    := person_add(&pm, Person{ name = "Annika",    birth = { year = 2007 }})
    rel_add(pm, rene, { person = katharina, type = RelType.Married })
    child_add(pm, samuel, rene, katharina)
    child_add(pm, val,    rene, katharina)
    child_add(pm, annika, rene, katharina)

    layout := layout_tree(pm, rene, LayoutOpts{ max_distance = 5, rels_to_show = {.Friend} })

    offset: [2]f32  = { 0, 0 }

    for !WindowShouldClose() {
        if IsWindowResized() {
            win_width  = GetScreenWidth()
            win_height = GetScreenHeight()
        }

        if IsMouseButtonDown(.LEFT) {
            offset += GetMouseDelta()
        }
        display_opts := DisplayOpts {
            screen = { f32(win_width), f32(win_height) },
            offset = offset,
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