package famtree

import "base:runtime"
import "core:mem"
import "core:c"

LayoutOpts :: struct {
	max_distance: u16,
	rels_to_show: []RelType, // Ordered by priority -> first relation-type will be displayed closest
	show_if_rel_over: bit_set[RelType],
	show_actual_parents: bool, // Indicates whether to show the actual or official parents
}

LayoutPersonEl :: struct {
	ph: PersonHandle,
	x:  i32,
}

LayoutRow :: struct {
	data: [dynamic]LayoutPersonEl,
	persons_cache: map[PersonHandle]bool,
}

Layout :: struct {
	rows: []LayoutRow,
	coord_offset: [2]i32,
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
add_person_to_row :: proc(person: LayoutPersonEl, row: ^LayoutRow, col: int) {
	inject_at(&row.data, col, person)
	row.persons_cache[person.ph] = true
}

add_related_to_layout :: proc(pm: PersonManager, start: PersonHandle, row: ^LayoutRow, start_col: ^int, opts: LayoutOpts) {
	assert(start != {})
	start_birth      := person_get(pm, start).birth
	rels_of_start_p  := person_get_rels(pm, start)
	#reverse for rel_type in opts.rels_to_show {
		rels := rels_of_start_p.rels[rel_type][:]
		from := rels_of_start_p.from[rel_type][:]
		rel  := iter_rels_from_merged(pm, &rels, &from)
		for rel != nil {
			if rel.?.person != {} && (!rel.?.is_over || rel_type in opts.show_if_rel_over) {
				next_birth  := person_get(pm, rel.?.person).birth
				place_left  := date_is_before_simple(next_birth, start_birth)
				next_col: int
				if place_left {
					next_col = start_col^
					start_col^ += 1
				} else {
					next_col = start_col^ + 1
				}
				add_person_to_row({ ph = rel.?.person }, row, next_col)
				next_opts := opts
				next_opts.max_distance -= 1
				if next_opts.max_distance > 0 && rel.?.person not_in	 row.persons_cache {
					add_related_to_layout(pm, rel.?.person, row, &next_col, next_opts)
					if place_left do start_col^ = next_col + 1
				}
			}
			rel = iter_rels_from_merged(pm, &rels, &from)
		}
	}
}

// @Todo: Add relatives of children/parents recursively too
add_children_to_layout :: proc() {}
add_parents_to_layout :: proc() {}

layout_tree :: proc(pm: PersonManager, start: PersonHandle, opts: LayoutOpts, allocator := context.allocator) -> (layout: Layout, err: runtime.Allocator_Error) #optional_allocator_error {
	center_row := opts.max_distance
	layout.rows = make([]LayoutRow, 2*opts.max_distance + 1, allocator)
	for _, i in layout.rows {
		layout.rows[i].data = make([dynamic]LayoutPersonEl, allocator)
	}
	start_col := 0
	add_person_to_row(LayoutPersonEl{ ph = start }, &layout.rows[center_row], start_col)

	// @Todo: Add children/parents recursively
	// @Todo: Layout edges somehow
	add_related_to_layout(pm, start, &layout.rows[center_row], &start_col, opts)
	// @Todo: Patch up coordinates

	return layout, err
}

