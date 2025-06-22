package famtree

import "core:mem"
import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

DEFAULT_PERSON_WIDTH    :: 200
DEFAULT_PERSON_HEIGHT   :: 40
DEFAULT_PERSON_MARGIN   :: 30
DEFAULT_PERSON_PAD      :: 5
MOUSE_WHEEL_ZOOM_FACTOR :: 0.2
DEFAULT_REL_THICKNESS   :: 2
DEFAULT_REL_PAD         :: 2
DEFAULT_REL_COLOR       :: rl.BLUE

cursor: rl.MouseCursor

DisplayOpts :: struct {
    screen: [2]f32,
    offset: [2]f32,
    zoom: f32,
}

draw_layout_get_person_x_coord :: #force_inline proc(el: LayoutPersonEl, layout: Layout, width, margin, offset_x: f32) -> f32 {
    return (el.x + f32(layout.coord_offset.x))*(width + margin) + offset_x
}

draw_layout_get_y_coord :: #force_inline proc(i: f32, layout: Layout, height, margin, offset_y: f32) -> f32 {
    return (i - layout.coord_offset.y)*(height + margin) + offset_y
}

draw_layout :: proc(pm: PersonManager, layout: Layout, root_ph: PersonHandle, opts: DisplayOpts) -> (selected_person: PersonHandle, selected_coords: [2]f32) {
    using rl
    // @Note: These variables are used to track how many frames a person was pressed, to prevent dragging to count as pressing.
    // @TODO: A better method would probably be to only count it as a press, if the mouse didn't move too much
    @(static) last_selected_person: PersonHandle = 0
    @(static) selected_frame_count: u32 = 0
    pressed_person: PersonHandle = 0

    width   := max(opts.zoom*DEFAULT_PERSON_WIDTH, 1)
    height  := max(opts.zoom*DEFAULT_PERSON_HEIGHT, 1)
    margin  := max(opts.zoom*DEFAULT_PERSON_MARGIN, 6)
    padding := opts.zoom*DEFAULT_PERSON_PAD
    rel_thickness := max(opts.zoom*DEFAULT_REL_THICKNESS, 1)
    rel_pad       := opts.zoom*DEFAULT_PERSON_PAD
    rel_color     := DEFAULT_REL_COLOR

    person_to_idx := make(map[PersonHandle]int, allocator=context.temp_allocator)

    for row, i in layout.rows {
        clear(&person_to_idx)
        y := draw_layout_get_y_coord(f32(i), layout, height, margin, opts.offset.y)

        //    -----------    -----------
        //    | ParentA |    | ParentB |
        //    -----a-----    -----b-----
        //         |              |
        //         c------d-------e
        //                |
        // t0--------t1---f----t2-------t3
        // |          |        |         |
        // p0        p1        p2       p3
        for parent_handle, children in row.parents {
            assert(len(children) >= 1)
            parents := get_parents_from_handle(parent_handle)
            if (parents[0] == {}) do continue;
            // fmt.println("-----")
            // fmt.println(layout.rows[i].data)
            // for parent_handle, children in layout.rows[i].parents do fmt.printf("[%x, %x] => %v\n", get_parents_from_handle(parent_handle)[0], get_parents_from_handle(parent_handle)[1], children)
            // fmt.println(layout.rows[i-1].data)
            // for parent_handle, children in layout.rows[i-1].parents do fmt.printf("[%x, %x] => %v\n", get_parents_from_handle(parent_handle)[0], get_parents_from_handle(parent_handle)[1], children)
            p0_row_idx := index_of_person(layout.rows[i-1].data[:], parents[0]);
            if (p0_row_idx < 0) do continue; // @Nocheckin
            assert(p0_row_idx >= 0);
            dy := draw_layout_get_y_coord(f32(i) - 0.333, layout, height, margin, opts.offset.y)
            d, f: Vector2
            if parents[1] == {} { // 1 parent - Draw single line from parents[0] to point d
                ax := width/2 + draw_layout_get_person_x_coord(layout.rows[i-1].data[p0_row_idx], layout, width, margin, opts.offset.x) + width/2
                ay := draw_layout_get_y_coord(f32(i-1), layout, height, margin, opts.offset.y) + height
                a  := Vector2{ ax, ay }
                d   = Vector2{ ax, dy }
                f   = d
                DrawLineEx(a, d, rel_thickness, rel_color)
            } else { // 2 parents - Draw lines from a, b to c and d
                p1_row_idx := index_of_person(layout.rows[i-1].data[:], parents[1])
                assert(p1_row_idx != -1)
                ax := draw_layout_get_person_x_coord(layout.rows[i-1].data[p0_row_idx], layout, width, margin, opts.offset.x) + width/2
                bx := draw_layout_get_person_x_coord(layout.rows[i-1].data[p1_row_idx], layout, width, margin, opts.offset.x) + width/2
                parent_y := draw_layout_get_y_coord(f32(i-1), layout, height, margin, opts.offset.y) + height
                dx := min(ax, bx) + abs(ax - bx)/2
                fy := draw_layout_get_y_coord(f32(i) - 0.666, layout, height, margin, opts.offset.y) + height
                a  := Vector2{ ax, parent_y }
                b  := Vector2{ bx, parent_y }
                c  := Vector2{ ax, dy }
                d   = Vector2{ dx, dy }
                e  := Vector2{ bx, dy }
                f   = Vector2{ dx, fy }
                DrawLineEx(a, c, rel_thickness, rel_color)
                DrawLineEx(b, e, rel_thickness, rel_color)
                DrawLineEx(c, d, rel_thickness, rel_color)
                DrawLineEx(e, d, rel_thickness, rel_color)
            }

            if len(children) == 1 {
                x := draw_layout_get_person_x_coord(layout_el_of_person(row.data[:], children[0]), layout, width, margin, opts.offset.x) + width/2
                t := Vector2{ x, d.y }
                p := Vector2{ x, y }
                DrawLineEx(d, t, rel_thickness, rel_color)
                DrawLineEx(t, p, rel_thickness, rel_color)
            } else {
                if d != f {
                    DrawLineEx(d, f, rel_thickness, rel_color)
                }
                // Draw lines from f to children
                for child in children {
                    x := draw_layout_get_person_x_coord(layout_el_of_person(row.data[:], child), layout, width, margin, opts.offset.x) + width/2
                    t := Vector2{ x, f.y }
                    p := Vector2{ x, y  }
                    DrawLineEx(t, f, rel_thickness, rel_color)
                    DrawLineEx(t, p, rel_thickness, rel_color)
                }
            }
        }

        for el, j in row.data {
            x := draw_layout_get_person_x_coord(el, layout, width, margin, opts.offset.x)
            DrawRectangleV({ x, y }, { width, height }, GRAY)
            if el.ph == root_ph do DrawRectangleLinesEx({x, y, width, height}, padding/2, BLUE)
            DrawText(strings.clone_to_cstring(person_get(pm, el.ph).name), i32(x + padding), i32(y + padding), i32(height - 2*padding), WHITE)
            person_to_idx[el.ph] = j

            if CheckCollisionPointRec(GetMousePosition(), { x, y, width, height }) {
                cursor = MouseCursor.POINTING_HAND
                if IsMouseButtonDown(.LEFT) do pressed_person = el.ph
                // @Cleanup: Replace magic number with configurable variable
                if IsMouseButtonReleased(.LEFT) && selected_frame_count <= 10 {
                    selected_person = el.ph
                    selected_coords = {el.x, f32(len(layout.rows)/2 - i)}
                }
            }
        }

        for from, rels in row.rels {
            from_el := row.data[person_to_idx[from]]
            for to in rels {
                to_el     := row.data[person_to_idx[to]]
                is_left   := person_to_idx[from] < person_to_idx[to]
                left      := is_left ? from : to
                right     := is_left ? to   : from
                left_el   := row.data[person_to_idx[left]]
                right_el  := row.data[person_to_idx[right]]
                left_pos  := Vector2{ draw_layout_get_person_x_coord(left_el,  layout, width, margin, opts.offset.x) + width, y + height/2 }
                right_pos := Vector2{ draw_layout_get_person_x_coord(right_el, layout, width, margin, opts.offset.x),         y + height/2 }

                if person_to_idx[right] - person_to_idx[left] == 1 {
                    DrawLineEx(left_pos, right_pos, rel_thickness, rel_color)
                } else {
                    a := left_pos + {(margin - rel_pad)/2, 0}
                    b := a + {0, -(height + rel_thickness + margin)/2}

                    c := b + {(right_el.x - left_el.x)*(width + margin) - width - margin, 0}
                    d := c + {0, (height + rel_thickness + margin)/2}
                    DrawLineEx(left_pos, a, rel_thickness, rel_color)
                    DrawLineEx(a, b, rel_thickness, rel_color)
                    DrawLineEx(b, c, rel_thickness, rel_color)
                    DrawLineEx(c, d, rel_thickness, rel_color)
                    DrawLineEx(d, right_pos, rel_thickness, rel_color)
                }
            }
        }
    }
    if pressed_person == last_selected_person do selected_frame_count += 1
    else                                      do selected_frame_count = 0
    last_selected_person = pressed_person
    return selected_person, selected_coords
}

get_default_offset :: proc(screen: [2]f32, zoom: f32, max_layout_distance: f32) -> (offset: [2]f32) {
    offset.x = f32(screen.x - zoom*DEFAULT_PERSON_WIDTH)/2
    offset.y = f32(screen.y - zoom*DEFAULT_PERSON_HEIGHT)/2 - f32(max_layout_distance * zoom * (DEFAULT_PERSON_HEIGHT + DEFAULT_PERSON_MARGIN))
    return offset
}

main :: proc() {
    using rl
    win_width  : i32 = 1600
    win_height : i32 = 800
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
    rel_add(pm, { from = Raymun, to = Clarice, type = RelType.Married, end = { year = 276 } })
    rel_add(pm, { from = Raymun, to = Bethany, type = RelType.Married, end = { year = 263 } })
    rel_add(pm, { from = Raymun, to = Lanna,   type = RelType.Married })
    rel_add(pm, { from = Aleyne, to = Falia,   type = RelType.Affair  })
    rel_add(pm, { from = Aleyne, to = Harlen,  type = RelType.Married })
    rel_add(pm, { from = Erren,  to = Desmera, type = RelType.Married })
    child_add(pm, Bethanys1,   Raymun, Bethany)
    child_add(pm, Bethanys2,   Raymun, Bethany)
    child_add(pm, Reynard,     Raymun, Clarice)
    child_add(pm, Aleyne,      Raymun, Clarice)
    child_add(pm, Erren,       Raymun, Clarice)
    child_add(pm, SonOfAleyne, Aleyne, Harlen)


    root_ph := Raymun
    layout_opts := LayoutOpts{ max_distance = 5, rels_to_show = {.Friend, .Married, .Affair}, show_if_rel_over = {.Friend, .Married, .Affair}, flags = { .Dead_Persons } }
    layout := layout_tree(pm, root_ph, layout_opts)
    // fmt.println(layout)

    display_opts := DisplayOpts {
        screen = { f32(win_width), f32(win_height) },
        zoom   = 1,
    }
    display_opts.offset = get_default_offset(display_opts.screen, display_opts.zoom, f32(layout_opts.max_distance))

    for !WindowShouldClose() {
        cursor = MouseCursor.DEFAULT
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
            selected_person, selected_coords := draw_layout(pm, layout, root_ph, display_opts)
            if selected_person != {} {
                root_ph = selected_person
                old_coord_offset := layout.coord_offset
                layout  = layout_tree(pm, root_ph, layout_opts)
                layout.coord_offset = selected_coords + old_coord_offset - layout.coord_offset
            }

            DrawFPS(10, 10)
            SetMouseCursor(cursor)
        EndDrawing()
    }

    CloseWindow()
}