package famtree

import "base:runtime"
import "core:math"
import "core:mem"
import "core:c"

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
LayoutXCoord :: union {i32, f32}

LayoutPersonEl :: struct {
	ph: PersonHandle,
	x:  LayoutXCoord,
}

LayoutRow :: struct {
	data: [dynamic]LayoutPersonEl,
	persons_cache: map[PersonHandle]bool,
	min_x, max_x: i32,
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
update_row_min_max_xs :: proc(row: ^LayoutRow, x: i32) {
	if x != UNKNOWN_X_COORD {
		if row.min_x == UNKNOWN_X_COORD || x < row.min_x {
			row.min_x = x
		}
		if row.max_x == UNKNOWN_X_COORD || x > row.max_x {
			row.max_x = x
		}
	}
}

@(private="file")
inject_person_in_row :: proc(person: LayoutPersonEl, row: ^LayoutRow, col: int) {
	inject_at(&row.data, col, person)
	row.persons_cache[person.ph] = true
	update_row_min_max_xs(row, person.x.(i32))
}

@(private="file")
append_person_to_row :: proc(person: LayoutPersonEl, row: ^LayoutRow) {
	append(&row.data, person)
	row.persons_cache[person.ph] = true
	update_row_min_max_xs(row, person.x.(i32))
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
				inject_person_in_row({ ph = rel.?.person, x = UNKNOWN_X_COORD }, row, next_col)
				next_opts := opts
				next_opts.max_distance -= 1
				if next_opts.max_distance > 0 && rel.?.person not_in row.persons_cache {
					add_related_to_layout(pm, rel.?.person, row, &next_col, next_opts)
					if place_left do start_col^ = next_col + 1
				}
			}
			rel = iter_rels_from_merged(pm, &rels, &from)
		}
	}
}

add_descendants_to_layout :: proc(pm: PersonManager, parent: LayoutPersonEl, children_row: int, layout: ^Layout, opts: LayoutOpts) {
	// @Todo: Patch potentially duplicate x coordinates (by moving ancestors around?)
	count := i32(0)
	for child in person_get_rels(pm, parent.ph).children {
		if ((LayoutFlags.Actual_Parents in opts.flags && is_actual_parent(pm, child, parent.ph)) || is_official_parent(pm, child, parent.ph)) &&
		   (LayoutFlags.Dead_Persons    in opts.flags || person_get(pm, child).death == {})      && child not_in layout.rows[children_row].persons_cache {
			append_person_to_row({ ph = child, x = parent.x.(i32) + count }, &layout.rows[children_row])
			count += 1
		}
	}
	mid       := count/2
	row_len   := i32(len(layout.rows[children_row].data))
	next_opts := opts
	next_opts.max_distance -= 1
	for i in 1..=count {
		child := &layout.rows[children_row].data[row_len - i]
		child.x = child.x.(i32) - mid
		if opts.max_distance > 0 {
			child_col := int(row_len - i)
			add_descendants_to_layout(pm, child^, children_row + 1, layout, next_opts)
			add_related_to_layout(pm, child.ph, &layout.rows[children_row], &child_col, next_opts)
		}
	}
}

add_ancestors_to_layout :: proc() {

}

patch_coordinates :: proc(pm: PersonManager, start_person: PersonHandle, layout: ^Layout, allocator := context.allocator) {
	min_x: i32 = 0
	max_x: i32 = 0
	for row in layout.rows {
		if row.min_x != UNKNOWN_X_COORD do min_x = min(min_x, row.min_x)
		if row.max_x != UNKNOWN_X_COORD do max_x = max(max_x, row.max_x)
	}

	coord_map_idx_offset := min_x
	coord_map := make([]i32, max_x - min_x, allocator=allocator)
	for row in layout.rows {
		count      := 0
		last_coord := UNKNOWN_X_COORD
		for el in row.data {
			if el.x.(i32) == UNKNOWN_X_COORD {
				count += 1
			} else {
				if last_coord == UNKNOWN_X_COORD do last_coord = min_x
				unfilled_coords_count  := el.x.(i32) - last_coord
				persons_per_prev_coord := unfilled_coords_count == 0 ? 0 : i32(math.ceil(f32(count) / f32(unfilled_coords_count)))
				for i in coord_map_idx_offset + last_coord ..< coord_map_idx_offset + el.x.(i32) {
					coord_map[i] = max(coord_map[i], persons_per_prev_coord)
				}
				last_coord = el.x.(i32)
				count = 0
			}
		}

		unfilled_coords_count  := max_x - row.max_x
		persons_per_prev_coord := unfilled_coords_count == 0 ? 0 : i32(math.ceil(f32(count) / f32(unfilled_coords_count)))
		for i in coord_map_idx_offset + row.max_x ..< coord_map_idx_offset + max_x {
			coord_map[i] = max(coord_map[i], persons_per_prev_coord)
		}
	}

	for &row in layout.rows {

		for &el in row.data {

		}
	}
}

layout_tree :: proc(pm: PersonManager, start_person: PersonHandle, opts: LayoutOpts, allocator := context.allocator) -> (layout: Layout, err: runtime.Allocator_Error) #optional_allocator_error {
	center_row := opts.max_distance
	layout.rows = make([]LayoutRow, 2*opts.max_distance + 1, allocator)
	for _, i in layout.rows {
		layout.rows[i] = {
			data          = make([dynamic]LayoutPersonEl, allocator=allocator),
			persons_cache = make(map[PersonHandle]bool,   allocator=allocator),
			min_x = UNKNOWN_X_COORD,
			max_x = UNKNOWN_X_COORD,
		}
	}
	start_col := 0
	start_el  := LayoutPersonEl{ ph = start_person, x = 0 }
	inject_person_in_row(start_el, &layout.rows[center_row], start_col)
	layout.rows[center_row].min_x = start_el.x.(i32)
	layout.rows[center_row].max_x = start_el.x.(i32)

	// @Todo: Layout edges somehow
	add_ancestors_to_layout()
	add_descendants_to_layout(pm, start_el, int(center_row + 1), &layout, opts)
	add_related_to_layout(pm, start_person, &layout.rows[center_row], &start_col, opts)
	patch_coordinates(pm, start_person, &layout, allocator)

	return layout, err
}
