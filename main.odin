package famtree

import "core:mem"
import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

DEFAULT_PERSON_WIDTH  :: 150
DEFAULT_PERSON_HEIGHT :: 30
DEFAULT_PERSON_MARGIN :: 20
DEFAULT_PERSON_PAD    :: 5

DisplayOpts :: struct {
    screen: [2]f32,
    offset: [2]f32,
    zoom: f32,
}

draw_layout :: proc(pm: PersonManager, layout: Layout, opts: DisplayOpts) {
    using rl
    width   := opts.zoom*DEFAULT_PERSON_WIDTH
    height  := opts.zoom*DEFAULT_PERSON_HEIGHT
    margin  := opts.zoom*DEFAULT_PERSON_MARGIN
    padding := opts.zoom*DEFAULT_PERSON_PAD
    total_height := f32(len(layout.rows))*(height + margin) - margin

    min_x: f32 =  1000000
    max_x: f32 = -1000000
    for row in layout.rows {
        for el in row.data {
            if el.x.(f32) < min_x do min_x = el.x.(f32)
            if el.x.(f32) > max_x do max_x = el.x.(f32)
        }
    }
    total_width := (max_x - min_x)*(width + margin) - margin

    for row, i in layout.rows {
        y := f32(i32(i) - layout.coord_offset.y)*(height + margin) + opts.offset.y + (opts.screen.y - total_height)/2
        for el in row.data {
            x := (el.x.(f32) - f32(layout.coord_offset.x))*(width + margin) + opts.offset.x + (opts.screen.x - total_width)/2
            DrawRectangleV({ x, y }, { width, height }, GRAY)
            DrawText(strings.clone_to_cstring(person_get(pm, el.ph).name), i32(x + padding), i32(y + padding), i32(height - 2*padding), WHITE)
        }
    }
}

get_default_offset :: proc(screen: [2]f32, zoom: f32, max_layout_distance: f32) -> (offset: [2]f32) {
    offset.x = f32(screen.x - zoom*DEFAULT_PERSON_WIDTH)/2
    offset.y = f32(screen.y - zoom*DEFAULT_PERSON_HEIGHT)/2 - f32(max_layout_distance * zoom * (DEFAULT_PERSON_HEIGHT + DEFAULT_PERSON_MARGIN))
    return offset
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

    layout_opts := LayoutOpts{ max_distance = 5, rels_to_show = {.Friend, .Married, .Affair} }
    layout := layout_tree(pm, rene, layout_opts)

    display_opts := DisplayOpts {
        screen = { f32(win_width), f32(win_height) },
        zoom   = 1,
    }
    display_opts.offset = get_default_offset(display_opts.screen, display_opts.zoom, f32(layout_opts.max_distance))

    for !WindowShouldClose() {
        if IsWindowResized() {
            win_width  = GetScreenWidth()
            win_height = GetScreenHeight()

            new_screen: [2]f32 = { f32(win_width), f32(win_height) }
            display_opts.offset += (new_screen - display_opts.screen)/2
            display_opts.screen = new_screen
        }

        if IsMouseButtonDown(.LEFT) {
            display_opts.offset += GetMouseDelta()
        }

        display_opts.zoom += GetMouseWheelMove()*0.1

        BeginDrawing()
            ClearBackground(BLACK)
            draw_layout(pm, layout, display_opts)
            DrawFPS(10, 10)
        EndDrawing()
    }

    CloseWindow()
}