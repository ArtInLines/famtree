package famtree

import "base:runtime"
import "core:math"
import "core:mem"
import "core:c"
import "core:fmt" // @Cleanup

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
}

LayoutRow :: struct {
    data: [dynamic]LayoutPersonEl,
    rels: map[PersonHandle][dynamic]PersonHandle, // can also be used to quickly check if a person is already in this row
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
iter_rels_from_merged :: proc(pm: PersonManager, rels: ^[]Rel, from: ^[]RelHandle) -> (res: Maybe(Rel), is_of_rels_arr: bool) {
    is_of_rels_arr = false
    if len(rels) == 0 {
        if len(from) == 0 do res = nil
        else {
            res = rel_get(pm, from[0])
            from^ = from[1:]
        }
    } else if len(from) == 0 {
        is_of_rels_arr = true
        res = rels[0]
        rels^ = rels[1:]
    } else {
        r := rels[0]
        f := rel_get(pm, from[0])
        if date_is_before_simple(r.start, f.start) {
            is_of_rels_arr = true
            rels^ = rels[1:]
            res = r
        } else {
            from^ = from[1:]
            res = f
        }
    }
    return res, is_of_rels_arr
}

@(private="file")
inject_person_in_row :: proc(person: LayoutPersonEl, row: ^LayoutRow, col: int, allocator := context.allocator) {
    assert(col >= 0)
    if person.ph in row.rels do return
    assert(person.ph not_in row.rels)
    inject_at(&row.data, col, person)

    i := col - 1
    for i > 0 && row.data[i].x < row.data[i+1].x - 1 {
        row.data[i].x = row.data[i+1].x - 1
        i -= 1
    }
    i = col + 1
    for i < len(row.data) && row.data[i-1].x + 1 > row.data[i].x {
        row.data[i].x = row.data[i-1].x + 1
        i += 1
    }
    row.rels[person.ph] = make([dynamic]PersonHandle, allocator=allocator)
}

add_all_related_of_person :: proc(pm: PersonManager, cur_person_el: LayoutPersonEl, cur_row: u16, cur_col: int, layout: ^Layout, opts: LayoutOpts, allocator: mem.Allocator) -> (left, right: i32, next_col: int, any_placed: bool) {
    next_col   = cur_col
    next_opts := opts
    next_opts.max_distance -= 1
    any_placed = next_opts.max_distance > 0
    if any_placed {
        add_descendants_to_layout(pm, cur_person_el, cur_row + 1, layout, next_opts, allocator)
        add_ancestors_to_layout()
        left, right := add_non_family_related(pm, cur_row, &next_col, layout, next_opts, allocator)
    }
    return left, right, next_col, any_placed
}

add_non_family_related :: proc(pm: PersonManager, cur_row: u16, rel_to_col: ^int, layout: ^Layout, opts: LayoutOpts, allocator := context.allocator) -> (left, right: i32) {
    row := &layout.rows[cur_row]
    assert((rel_to_col^ >= 0) && (rel_to_col^ < len(row.data)))
    rel_to := row.data[rel_to_col^]
    // fmt.println("relative to: ", person_get(pm, rel_to.ph).name, "max_distance: ", opts.max_distance)
    birth  := person_get(pm, rel_to.ph).birth
    #reverse for rel_type in opts.rels_to_show {
        rels := person_get_rels(pm, rel_to.ph).rels[rel_type][:]
        from := person_get_rels(pm, rel_to.ph).from[rel_type][:]

        next_rel, is_of_rels_arr := iter_rels_from_merged(pm, &rels, &from)
        for next_rel != nil {
            rel := next_rel.?
            next_person := is_of_rels_arr ? rel.to : rel.from
            if next_person != {} && (!rel.is_over || rel_type in opts.show_if_rel_over) {
                next_birth := person_get(pm, next_person).birth
                place_left := date_is_before_simple(next_birth, birth)
                col: int
                next_x: LayoutXCoord
                if place_left {
                    next_x = rel_to.x
                    col    = rel_to_col^
                    rel_to_col^ += 1
                } else {
                    next_x = rel_to.x   + 1
                    col    = rel_to_col^ + 1
                }
                next_person_el := LayoutPersonEl{ ph = next_person, x = next_x }
                inject_person_in_row(next_person_el, row, col)
                if is_of_rels_arr do append(&row.rels[rel_to.ph],   next_person)
                else              do append(&row.rels[next_person], rel_to.ph)
                next_left, next_right, next_col, any_placed := add_all_related_of_person(pm, next_person_el, cur_row, col, layout, opts, allocator)
                if any_placed {
                    if place_left {
                        rel_to_col^ = next_col + 1
                        left += next_left + next_right
                    } else {
                        right += next_left + next_right
                    }
                }
            }
            next_rel, is_of_rels_arr = iter_rels_from_merged(pm, &rels, &from)
        }
    }
    return left, right
}

add_descendants_to_layout :: proc(pm: PersonManager, parent: LayoutPersonEl, children_row: u16, layout: ^Layout, opts: LayoutOpts, allocator := context.allocator) {
    row := &layout.rows[children_row]
    children_count := 0
    children_per_parent := make(map[PersonHandle][dynamic]PersonHandle, allocator=allocator)
    for child in person_get_rels(pm, parent.ph).children {
        if child in row.rels do continue
        if !(LayoutFlags.Dead_Persons in opts.flags || person_get(pm, child).death == {}) do continue

        if LayoutFlags.Actual_Parents in opts.flags {
            if is_actual_parent(pm, child, parent.ph) {
                other_parent := get_other_of_tuple(person_get_rels(pm, child).actual_parents, parent.ph)
                if other_parent not_in children_per_parent do children_per_parent[other_parent] = make([dynamic]PersonHandle, allocator=allocator)
                append(&children_per_parent[other_parent], child)
                children_count += 1
            }
        } else if is_official_parent(pm, child, parent.ph) {
                other_parent := get_other_of_tuple(person_get_rels(pm, child).official_parents, parent.ph)
                if other_parent not_in children_per_parent do children_per_parent[other_parent] = make([dynamic]PersonHandle, allocator=allocator)
                append(&children_per_parent[other_parent], child)
                children_count += 1
        }
    }

    // @TODO: Parents should probably be sorted in some way
    idx := 0
    all_children := make([]PersonHandle, children_count, allocator)
    for _, children in children_per_parent {
        for c in children {
            all_children[idx] = c
            idx += 1
        }
    }

    mid     := f32(children_count) / 2
    start_x := parent.x - mid
    col     := 0
    for col < len(row.data) && start_x < row.data[col].x do col += 1

    for c, i in all_children {
        child := LayoutPersonEl{ ph = c, x = parent.x + f32(i) - mid }
        inject_person_in_row(child, row, col)
        l, r, _, any_placed := add_all_related_of_person(pm, child, children_row, col, layout, opts, allocator)
        if any_placed do col += int(r)
        else          do col += 1
    }
}

add_ancestors_to_layout :: proc() {

}

layout_tree :: proc(pm: PersonManager, start_person: PersonHandle, opts: LayoutOpts, allocator := context.allocator) -> (layout: Layout, err: runtime.Allocator_Error) #optional_allocator_error {
    center_row := opts.max_distance
    layout.rows = make([]LayoutRow, 2*opts.max_distance + 1, allocator)
    for _, i in layout.rows {
        layout.rows[i] = {
            data = make([dynamic]LayoutPersonEl, allocator=allocator),
            rels = make(map[PersonHandle][dynamic]PersonHandle,   allocator=allocator),
        }
    }
    start_col := 0
    start_el  := LayoutPersonEl{ ph = start_person, x = 0 }
    inject_person_in_row(start_el, &layout.rows[center_row], start_col)

    // @Todo: Layout edges somehow
    add_all_related_of_person(pm, start_el, center_row, start_col, &layout, opts, allocator)
    return layout, err
}

