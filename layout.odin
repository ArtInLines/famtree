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

add_descendants_to_layout :: proc(pm: PersonManager, parent: LayoutPersonEl, children_row: int, layout: ^Layout, opts: LayoutOpts, allocator := context.allocator) {
    children_per_parent := make(map[PersonHandle][dynamic]PersonHandle, allocator=allocator)
    for child in person_get_rels(pm, parent.ph).children {
        if child in row.persons_cache do continue
        if !(LayoutFlags.Dead_Persons in opts.flags || person_get(pm, child).death == {}) do continue

        if LayoutFlags.Actual_Parents in opts.flags {
            if is_actual_parent(pm, child, parent) {
                other_parent := get_other_of_tuple(person_get_rels(pm, child).actual_parents, parent)
                if other_parent not_in children_per_parent do children_per_parent[other_parent] := make([dynamic]PersonHandle, allocator=allocator)
                append(&children_per_parent[other_parent], child)
            }
        } else if is_official_parent(pm, child, parent) {
                other_parent := get_other_of_tuple(person_get_rels(pm, child).official_parents, parent)
                if other_parent not_in children_per_parent do children_per_parent[other_parent] := make([dynamic]PersonHandle, allocator=allocator)
                append(&children_per_parent[other_parent], child)
        }
    }

    // @TODO: Parents should probably be sorted in some way
    for _, children in children_per_parent {

    }
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
    add_descendants_to_layout(pm, start_el, int(center_row + 1), &layout, opts, allocator)
    add_related_to_layout(pm, &layout.rows[center_row], &start_col, opts)

    return layout, err
}

