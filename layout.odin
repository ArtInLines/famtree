package famtree

import "base:runtime"
import "core:math"
import "core:mem"
import "core:c"
import "core:fmt" // @nocheckin

LayoutFlags :: enum {
    Actual_Parents,
    Dead_Persons,
}

LayoutOpts :: struct {
    max_distance: u16,
    rels_to_show: []RelType, // Ordered by priority -> first relation-type will be displayed closest
    show_if_rel_over: bit_set[RelType],
    flags: bit_set[LayoutFlags],
}

UNKNOWN_X_COORD :: c.INT32_MIN

// @Note: X-coordinates are always i32s until the function `patch_coordinates` is called
LayoutXCoord :: f32

LayoutPersonEl :: struct {
    ph: PersonHandle,
    x:  LayoutXCoord,
    // additional_x_offset: i32,

}

LayoutRow :: struct {
    data: [dynamic]LayoutPersonEl,
    persons_cache: map[PersonHandle]bool,
}

Layout :: struct {
    rows: []LayoutRow,
    coord_offset: [2]f32,
}

index_of_person :: proc(arr: []LayoutPersonEl, ph: PersonHandle) -> int {
    for x, i in arr {
        if x.ph == ph do return i
    }
    return -1
}

@(private="file") // @Note: updates rels & from
iter_rels_from_merged :: proc(pm: PersonManager, rels: ^[]Rel, from: ^[]RelHandle) -> Maybe(Rel) {
    if len(rels) == 0 {
        if len(from) == 0 do return nil
        else {
            res  := rel_get(pm, from[0])
            from^ = from[1:]
            return res
        }
    } else if len(from) == 0 {
        res := rels[0]
        rels^ = rels[1:]
        return res
    } else {
        r := rels[0]
        f := rel_get(pm, from[0])
        if date_is_before_simple(r.start, f.start) {
            rels^ = rels[1:]
            return r
        } else {
            from^ = from[1:]
            return f
        }
    }
}

@(private="file")
inject_person_in_row :: proc(person: LayoutPersonEl, row: ^LayoutRow, col: int, placed_left: bool) {
    assert(col >= 0)
    inject_at(&row.data, col, person)
    fmt.println(col, person)
    fmt.println(row.data)
    if placed_left {
        i := col - 1
        for i > 0 && row.data[i].x < row.data[i+1].x - 1 {
            row.data[i].x = row.data[i+1].x - 1
            i -= 1
        }
    } else {
        i := col + 1
        for i < len(row.data) && row.data[i-1].x + 1 > row.data[i].x {
            row.data[i].x = row.data[i-1].x + 1
            i += 1
        }
    }
    row.persons_cache[person.ph] = true
}

add_related_to_layout :: proc(pm: PersonManager, row: ^LayoutRow, rel_to_col: ^int, opts: LayoutOpts) -> (left, right: i32) {
    assert((rel_to_col^ >= 0) && (rel_to_col^ < len(row.data)))
    rel_to := row.data[rel_to_col^]
    birth  := person_get(pm, rel_to.ph).birth
    #reverse for rel_type in opts.rels_to_show {
        rels := person_get_rels(pm, rel_to.ph).rels[rel_type][:]
        from := person_get_rels(pm, rel_to.ph).from[rel_type][:]
        next_rel := iter_rels_from_merged(pm, &rels, &from)
        for next_rel != nil {
            rel := next_rel.?
            if rel.person != {} && (!rel.is_over || rel_type in opts.show_if_rel_over) {
                next_birth := person_get(pm, rel.person).birth
                place_left := date_is_before_simple(next_birth, birth)
                next_col: int
                next_x: LayoutXCoord
                if place_left {
                    next_x   = rel_to.x
                    next_col = rel_to_col^
                    rel_to_col^ += 1
                } else {
                    next_x   = rel_to.x   + 1
                    next_col = rel_to_col^ + 1
                }
                inject_person_in_row({ ph = rel.person, x = next_x }, row, next_col, place_left)
                next_opts := opts
                next_opts.max_distance -= 1
                if next_opts.max_distance > 0 && rel.person not_in row.persons_cache {
                    next_left, next_right := add_related_to_layout(pm, row, &next_col, next_opts)
                    if place_left {
                        rel_to_col^ = next_col + 1
                        left += next_left + next_right
                    } else {
                        right += next_left + next_right
                    }
                }
            }
            next_rel = iter_rels_from_merged(pm, &rels, &from)
        }
    }
    return left, right
}

should_display_child :: proc(pm: PersonManager, parent, child: PersonHandle, row: LayoutRow, opts: LayoutOpts) -> bool {
    return ((LayoutFlags.Actual_Parents in opts.flags && is_actual_parent(pm, child, parent)) || is_official_parent(pm, child, parent)) &&
           (LayoutFlags.Dead_Persons    in opts.flags || person_get(pm, child).death == {})      && child not_in row.persons_cache
}

add_descendants_to_layout :: proc(pm: PersonManager, parent: LayoutPersonEl, children_row: int, layout: ^Layout, opts: LayoutOpts) {
    // @Todo: Patch potentially duplicate x coordinates (by moving ancestors around) (return value by which parent was moved to the right, so that it can be offset again (either in patch_coordinates or when rendering))
    // if opts.max_distance == 0 do return
    // count := i32(0)
    // for child in person_get_rels(pm, parent.ph).children {
    //     if should_display_child(pm, parent.ph, child, layout.rows[children_row], opts) do count += 1
    // }
    // mid       := count/2
    // next_opts := opts
    // next_opts.max_distance -= 1
    // i: i32 = 0
    // for child in person_get_rels(pm, parent.ph).children {
    //     if should_display_child(pm, parent.ph, child, layout.rows[children_row], opts) {
    //         child := LayoutPersonEl { ph = child, x = parent.x + i - mid }
    //         fmt.println("child:", child, ", ", person_get(pm, child.ph))
    //         append_person_to_row(child, &layout.rows[children_row])
    //         if opts.max_distance > 0 {
    //             child_col := len(layout.rows[children_row].data) - int(i)
    //             add_descendants_to_layout(pm, child, children_row + 1, layout, next_opts)
    //             add_related_to_layout(pm, child.ph, &layout.rows[children_row], &child_col, next_opts)
    //         }
    //         i += 1
    //     }
    // }
}

add_ancestors_to_layout :: proc() {

}

layout_tree :: proc(pm: PersonManager, start_person: PersonHandle, opts: LayoutOpts, allocator := context.allocator) -> (layout: Layout, err: runtime.Allocator_Error) #optional_allocator_error {
    center_row := opts.max_distance
    layout.rows = make([]LayoutRow, 2*opts.max_distance + 1, allocator)
    for _, i in layout.rows {
        layout.rows[i] = {
            data          = make([dynamic]LayoutPersonEl, allocator=allocator),
            persons_cache = make(map[PersonHandle]bool,   allocator=allocator),
        }
    }
    start_col := 0
    start_el  := LayoutPersonEl{ ph = start_person, x = 0 }
    inject_person_in_row(start_el, &layout.rows[center_row], start_col, false)

    // @Todo: Layout edges somehow
    add_ancestors_to_layout()
    add_descendants_to_layout(pm, start_el, int(center_row + 1), &layout, opts)
    add_related_to_layout(pm, &layout.rows[center_row], &start_col, opts)

    return layout, err
}

