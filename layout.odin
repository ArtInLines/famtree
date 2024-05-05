package famtree

import "base:runtime"
import "core:slice"
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

LayoutPersonEl :: struct {
    ph: PersonHandle,
    x:  f32,
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
inject_person_in_row :: proc(person: LayoutPersonEl, row: ^LayoutRow, col: int, allocator: mem.Allocator) {
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

// @TODO: Add parameter to skip adding ancestors
add_all_related_of_person :: proc(pm: PersonManager, cur_person_el: LayoutPersonEl, cur_row: u16, cur_col: int, layout: ^Layout, opts: LayoutOpts, allocator: mem.Allocator) -> (left, right: i32, next_col: int, any_placed: bool) {
    next_col   = cur_col
    next_opts := opts
    next_opts.max_distance -= 1
    any_placed = next_opts.max_distance > 0
    if any_placed {
        // left, right := add_non_family_related(pm, cur_row, &next_col, layout, next_opts, allocator)
        add_descendants_to_layout(pm, cur_person_el, cur_row + 1, layout, next_opts, allocator)
        add_ancestors_to_layout(pm, cur_person_el, cur_row - 1, layout, next_opts, allocator)
    }
    return left, right, next_col, any_placed
}

add_non_family_related :: proc(pm: PersonManager, cur_row: u16, rel_to_col: ^int, layout: ^Layout, opts: LayoutOpts, allocator: mem.Allocator) -> (left, right: i32) {
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
                next_x: f32
                if place_left {
                    next_x = rel_to.x
                    col    = rel_to_col^
                    rel_to_col^ += 1
                } else {
                    next_x = rel_to.x   + 1
                    col    = rel_to_col^ + 1
                }
                next_person_el := LayoutPersonEl{ ph = next_person, x = next_x }
                inject_person_in_row(next_person_el, row, col, allocator)
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

ChildrenPerParent :: struct {
    parent: PersonHandle,
    already_placed_children: [dynamic]PersonHandle,
    not_yet_placed_children: [dynamic]PersonHandle
}
ChildrenParentMap :: [dynamic]ChildrenPerParent

add_child_to_children_parent_map :: proc(cpmap: ^ChildrenParentMap, parent, child: PersonHandle, is_already_placed: bool, allocator: mem.Allocator) {
    i := 0
    for i < len(cpmap) && cpmap[i].parent != parent do i += 1
    if i == len(cpmap) {
        cpp := ChildrenPerParent {
            parent = parent,
            already_placed_children = make([dynamic]PersonHandle, allocator),
            not_yet_placed_children = make([dynamic]PersonHandle, allocator),
        }
        append(is_already_placed ? &cpp.already_placed_children : &cpp.not_yet_placed_children, child)
        append(cpmap, cpp)
    } else {
        append(is_already_placed ? &cpmap[i].already_placed_children : &cpmap[i].not_yet_placed_children, child)
    }
}

get_min_date :: proc(a, b: Date) -> Date {
    if date_is_before(a, b) do return a
    else do return b
}

get_min_date_of_children_per_parent :: proc(pm: PersonManager, cpp: ChildrenPerParent) -> Date {
    if      len(cpp.already_placed_children) == 0 do return person_get(pm, cpp.not_yet_placed_children[0]).birth
    else if len(cpp.not_yet_placed_children) == 0 do return person_get(pm, cpp.already_placed_children[0]).birth
    else do return get_min_date(person_get(pm, cpp.already_placed_children[0]).birth, person_get(pm, cpp.not_yet_placed_children[0]).birth)
}

add_descendants_to_layout :: proc(pm: PersonManager, parent: LayoutPersonEl, children_row: u16, layout: ^Layout, opts: LayoutOpts, allocator: mem.Allocator) {
    // Map all children to the corresponding the parents, filtering out any children, that shouldn't be drawn
    row := &layout.rows[children_row]
    children_count := 0
    cpmap := make(ChildrenParentMap, allocator=allocator)
    for child in person_get_rels(pm, parent.ph).children {
        if !(LayoutFlags.Dead_Persons in opts.flags || person_get(pm, child).death == {}) do continue
        is_already_placed := child in row.rels
        if LayoutFlags.Actual_Parents in opts.flags {
            if is_actual_parent(pm, child, parent.ph) {
                other_parent := get_other_of_tuple(person_get_rels(pm, child).actual_parents, parent.ph)
                add_child_to_children_parent_map(&cpmap, other_parent, child, is_already_placed, allocator)
            }
        } else if is_official_parent(pm, child, parent.ph) {
                other_parent := get_other_of_tuple(person_get_rels(pm, child).official_parents, parent.ph)
                add_child_to_children_parent_map(&cpmap, other_parent, child, is_already_placed, allocator)
        }
    }

    // Sort parents
    for i in 0..<len(cpmap)-1 {
        min_idx := i
        min_birth := get_min_date_of_children_per_parent(pm, cpmap[min_idx])
        for j in i+1..<len(cpmap) {
            cur_birth := get_min_date_of_children_per_parent(pm, cpmap[j])
            if date_is_before(min_birth, cur_birth) {
                min_idx   = j
                min_birth = cur_birth
            }
        }
        tmp := cpmap[min_idx]
        cpmap[min_idx] = cpmap[i]
        cpmap[i] = tmp
    }

    children_to_place_in_middle_count := 0
    for cpp in cpmap {
        if len(cpp.already_placed_children) == 0 do children_to_place_in_middle_count += len(cpp.not_yet_placed_children)
    }

    col := 0
    for col < len(row.data) && parent.x < row.data[col].x do col += 1
    children_placed_in_middle_count := 0
    for cpp in cpmap {
        // @TODO: Add other parent here already (correctly centered over the children) and add flag to add_all_related_of_person to prevent adding ancestors
        // @TODO: Maybe add alignment to LayoutPersonEls to potentially have them stick with their left/right partner when another person is injected between them
        // @TODO: Maybe add functionality for moving LayoutPersonEls after they've already been placed, to allow recentering parents over children for example
        if len(cpp.already_placed_children) == 0 {
            for c in cpp.not_yet_placed_children {
                child := LayoutPersonEl{ ph = c, x = children_placed_in_middle_count > children_to_place_in_middle_count/2 ? parent.x : parent.x + 1 }
                inject_person_in_row(child, row, col, allocator)
                l, r, _, any_placed := add_all_related_of_person(pm, child, children_row, col, layout, opts, allocator)
                if any_placed do col += int(r)
                else          do col += 1
                children_placed_in_middle_count += 1
            }
        } else {
            already_placed_xs     := make([]f32,  len(cpp.already_placed_children), allocator)
            already_placed_births := make([]Date, len(cpp.already_placed_children), allocator)
            for c, i in cpp.already_placed_children {
                already_placed_xs[i]     = row.data[index_of_person(row.data[:], c)].x
                already_placed_births[i] = person_get(pm, c).birth
            }
            for i in 0..<len(already_placed_xs)-1 {
                min := i
                for j in i+1..<len(already_placed_xs) {
                    if already_placed_xs[j] < already_placed_xs[min] do min = j
                }
                slice.swap(already_placed_xs, i, min)
                slice.swap(already_placed_births, i, min)
                slice.swap(cpp.already_placed_children[:], i, min)
            }
            for c in cpp.not_yet_placed_children {
                cur_birth := person_get(pm, c).birth
                i := 0
                for i < len(already_placed_births) && date_is_before(already_placed_births[i], cur_birth) do i += 1
                cx: f32
                col: int
                if i < len(already_placed_xs) {
                    cx  = already_placed_xs[i]
                    col = index_of_person(row.data[:], cpp.already_placed_children[i])
                } else {
                    j  := len(already_placed_xs) - 1
                    cx  = already_placed_xs[j] + 1
                    col = index_of_person(row.data[:], cpp.already_placed_children[j]) + 1
                }
                child := LayoutPersonEl{ ph = c, x = cx }
                inject_person_in_row(child, row, col, allocator)
                add_all_related_of_person(pm, child, children_row, col, layout, opts, allocator)
            }
            delete(already_placed_births)
            delete(already_placed_xs)
        }
    }
}

add_ancestors_to_layout :: proc(pm: PersonManager, child: LayoutPersonEl, parents_row: u16, layout: ^Layout, opts: LayoutOpts, allocator: mem.Allocator) {
    row        := &layout.rows[parents_row]
    child_rels := person_get_rels(pm, child.ph)
    parents    := (LayoutFlags.Actual_Parents in opts.flags) ? child_rels.actual_parents : child_rels.official_parents

    parents_to_add_count := 0
    parent_col := 0
    for parent_col < len(row.data) && row.data[parent_col].x < child.x do parent_col += 1
    for parent in parents {
        if parent != {} && parent not_in row.rels do parents_to_add_count += 1
    }
    parent_x := parents_to_add_count == 2 ? child.x - 0.5 : child.x
    for parent in parents {
        if parent != {} && parent not_in row.rels {
            parent_el := LayoutPersonEl{ ph = parent, x = parent_x }
            inject_person_in_row(parent_el, row, parent_col, allocator)
            l, r, _, any_placed := add_all_related_of_person(pm, parent_el, parents_row, parent_col, layout, opts, allocator)
            if any_placed do parent_col += int(r)
            else          do parent_col += 1
            parent_x += 1
        }
    }
}

layout_tree :: proc(pm: PersonManager, start_person: PersonHandle, opts: LayoutOpts, allocator := context.allocator) -> (layout: Layout, err: runtime.Allocator_Error) #optional_allocator_error {
    center_row := opts.max_distance
    layout.rows = make([]LayoutRow, 2*opts.max_distance + 1, allocator)
    for _, i in layout.rows {
        layout.rows[i] = {
            data = make([dynamic]LayoutPersonEl, allocator=allocator),
            rels = make(map[PersonHandle][dynamic]PersonHandle, allocator=allocator),
        }
    }
    start_col := 0
    start_el  := LayoutPersonEl{ ph = start_person, x = 0 }
    inject_person_in_row(start_el, &layout.rows[center_row], start_col, allocator)

    // @Todo: Layout edges somehow
    add_all_related_of_person(pm, start_el, center_row, start_col, &layout, opts, allocator)
    return layout, err
}

