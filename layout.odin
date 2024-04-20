package famtree

import "base:runtime"
import "core:mem"
import "core:c"

LayoutOpts :: struct {
	max_distance: u16,
	rels_to_show: []RelType, // Ordered by priority
	show_if_rel_over: bit_set[RelType],
}

LayoutPersonEl :: struct {
	ph: PersonHandle,
	x:  i32,
}

Layout :: struct {
	rows: [dynamic][dynamic]LayoutPersonEl,
	coord_offset: [2]i32,
}

add_related_to_layout :: proc(pm: PersonManager, start: PersonHandle, opts: LayoutOpts, cur_row: u16, layout: ^Layout) {
	// @Todo: Potential issue:
	// Assume spouse relation has higher priority than friend relation
	// If a spouse relation is in `from` it will be added after the friend relation regardless
	start_birth := person_get(pm, start).birth
	for rel_type in opts.rels_to_show {
		for rel in person_get_rels(pm, start).rels[rel_type] {
			switch rel_type {
				case .Parent:
					// layout.rows[cur_row + 1] // @Todo
				case .Affair, .Friend, .Married:
					if !rel.is_over || rel_type in opts.show_if_rel_over {
						next_person := LayoutPersonEl{ ph = rel.person }
						next_birth  := person_get(pm, rel.person).birth
						place_left  := date_is_before_simple(start_birth, next_birth)
						if place_left {
							inject_at_elem(&layout.rows[cur_row], 0, next_person)
						} else {
							append_elem(&layout.rows[cur_row], next_person)
						}
					}
			}

		}
	}
}

layout_tree :: proc(pm: PersonManager, start: PersonHandle, opts: LayoutOpts, allocator := context.allocator) -> (layout: Layout, err: runtime.Allocator_Error) #optional_allocator_error {
	center_row := opts.max_distance
	layout.rows = make([dynamic][dynamic]LayoutPersonEl, 2*opts.max_distance + 1, allocator)
	for _, i in layout.rows {
		layout.rows[i] = make([dynamic]LayoutPersonEl, allocator)
	}
	append_elem(&layout.rows[center_row], LayoutPersonEl{ ph = start })

	// @Todo: Layout edges somehow
	add_related_to_layout(pm, start, opts, center_row, &layout)
	// @Todo: Patch up coordinates

	return layout, err
}

