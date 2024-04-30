package famtree

import "core:mem"
import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

DEFAULT_PERSON_WIDTH  :: 150
DEFAULT_PERSON_HEIGHT :: 30
DEFAULT_PERSON_MARGIN :: 20
DEFAULT_PERSON_PAD    :: 5
MOUSE_WHEEL_ZOOM_FACTOR :: 0.2

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
    for row, i in layout.rows {
        y := (f32(i) - layout.coord_offset.y)*(height + margin) + opts.offset.y
        for el in row.data {
            // fmt.println("Drawing:", person_get(pm, el.ph))
            x := (el.x - f32(layout.coord_offset.x))*(width + margin) + opts.offset.x
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

    pm          := person_manager_init()
    Raymun      := person_add(&pm, Person{ name = "Raymun",  birth = { year = 216 }})
    Clarice     := person_add(&pm, Person{ name = "Clarice", birth = { year = 250 }})
    Bethany     := person_add(&pm, Person{ name = "Bethany", birth = { year = 219 }})
    Lanna       := person_add(&pm, Person{ name = "Lanna",   birth = { year = 270 }})
    Reynard     := person_add(&pm, Person{ name = "Reynard", birth = { year = 272 }})
    Falia       := person_add(&pm, Person{ name = "Falia",   birth = { year = 275 }})
    Aleyne      := person_add(&pm, Person{ name = "Aleyne",  birth = { year = 274 }})
    Harlen      := person_add(&pm, Person{ name = "Harlen",  birth = { year = 270 }})
    Desmera     := person_add(&pm, Person{ name = "Desmera", birth = { year = 278 }})
    Erren       := person_add(&pm, Person{ name = "Erren",   birth = { year = 276 }})
    SonOfAleyne := person_add(&pm, Person{ name = "SonOfAleyne", birth = { year = 291 }, death = { year = 292 }})
    Bethanys1   := person_add(&pm, Person{ name = "Bethanys1",   birth = { year = 242 }, death = { year = 243 }})
    Bethanys2   := person_add(&pm, Person{ name = "Bethanys2",   birth = { year = 248 }, death = { year = 249 }})
    rel_add(pm, Raymun, { person = Clarice, type = RelType.Married, end = { year = 276 } })
    rel_add(pm, Raymun, { person = Bethany, type = RelType.Married, end = { year = 263 } })
    rel_add(pm, Raymun, { person = Lanna,   type = RelType.Married })
    rel_add(pm, Aleyne, { person = Falia,   type = RelType.Affair })
    rel_add(pm, Aleyne, { person = Harlen,  type = RelType.Married })
    rel_add(pm, Erren,  { person = Desmera, type = RelType.Married })
    child_add(pm, Bethanys1,   Raymun, Bethany)
    child_add(pm, Bethanys2,   Raymun, Bethany)
    child_add(pm, Reynard,     Raymun, Clarice)
    child_add(pm, Aleyne,      Raymun, Clarice)
    child_add(pm, Erren,       Raymun, Clarice)
    child_add(pm, SonOfAleyne, Aleyne, Harlen)


    layout_opts := LayoutOpts{ max_distance = 5, rels_to_show = {.Friend, .Married, .Affair}, show_if_rel_over = {.Friend, .Married, .Affair}, flags = { .Dead_Persons } }
    layout := layout_tree(pm, Raymun, layout_opts)
    fmt.println(layout)

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


        display_opts.offset += f32(int(IsMouseButtonDown(.LEFT))) * GetMouseDelta()

        zoom_delta := GetMouseWheelMove()*MOUSE_WHEEL_ZOOM_FACTOR
        display_opts.zoom     += zoom_delta
        // display_opts.offset.x += zoom_delta*(GetMousePosition().x - display_opts.screen.x)

        BeginDrawing()
            ClearBackground(BLACK)
            draw_layout(pm, layout, display_opts)
            DrawFPS(10, 10)
        EndDrawing()
    }

    CloseWindow()
}