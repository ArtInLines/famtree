package main

import "core:mem"
import "core:fmt"
import "core:c"
import rl "vendor:raylib"

PersonIdx :: distinct u32;
NULL_IDX  : PersonIdx : c.UINT32_MAX

// For displaying

// Bitmask for coordinate that is known
LayerKnowledge :: enum u8 {
	KNOWN_X    = 1, // 0b01
	KNOWN_Y    = 2, // 0b10
	KNOWN_BOTH = 3, // 0b11
}

MinMax :: struct {
	min, max: i16
}

// The layer that a person is on in the family tree
// The starting character is always on 0,0
// Siblings are on the same y with a different x
// Parents are on a lower y, with x-1 and x+1 respectively (unless it's a single parent of course)
// `tag` indicates whether one of the coordinates is not yet known
Layer :: struct {
	x, y: i16,
	i: PersonIdx,
	tag: LayerKnowledge
}

Display :: struct {
	offset: rl.Vector2,
	zoom: f32,
}


// For modelling

Sex :: enum u8 {
	SEX_F,  // female
	SEX_M,  // male
	SEX_U,  // unknown
}

RelType :: enum u8 {
	REL_MARRIED,
	REL_PARENT,
}

Rel :: struct {
	type: RelType,
	from, to: PersonIdx,
}

Person :: struct {
	rm: bool, // Indicates whether the person has been removed or not
	sex: Sex,
	name: string,
	rels: [dynamic]Rel,
}

// PersonList is a dynamic array, that guarantuees indexes to stay correct forever
// It does so by storing a linked-list of previously removed indexes
// @Implementation:
// The linked-list is stored in the same memory as the Person structs
// The `rm` field of the Person indicates whetehr the person has been removed already
// The `name` field is re-interpreted as a PersonIdx and stores the index to the next free index
// or NULL_IDX at the end of the linked-list
PersonList :: struct {
	data: ^Person,
	len: u32,
	cap: u32,
	free_head: PersonIdx, // Free-list via indexes instead of pointers
	allocator: mem.Allocator,
}
// Global PersonList -> all Persons are allocated and managed in this list
persons: PersonList;

person_add :: proc(p: Person) -> PersonIdx {
	if (persons.free_head != NULL_IDX) {
		assert(persons.data[persons.free_head].rm);
		idx  := persons.free_head
		next := transmute(PersonIdx)(persons.data[idx].name)
		persons.data[idx] = p;
		persons.free_head = next;
		return idx;
	} else {
		ail_da_push(&persons, p);
		return persons.len - 1;
	}
}

person_rm :: proc(idx: PersonIdx) {
	assert(!persons.data[idx].rm);
	if persons.data[idx].rm do return
	persons.data[idx].rm = true;
	^(^PersonIdx)&(persons.data[idx].name) = persons.free_head;
	persons.free_head = idx;
}

person_list_init :: proc(cap: u32, allocator: mem.Allocator) -> PersonList {
	return (PersonList) {
		.data = allocator->alloc(allocator->data, sizeof(Person) * cap),
		.len  = 0,
		.cap  = cap,
		.free_head = NULL_IDX,
		.allocator = allocator,
	};
}

rel_add :: proc(from, to: PersonIdx, type: RelType) -> Rel {
	rel := Rel{ from = from, to = to, type = type }
	append(&persons.data[from].rels, rel)
	append(&persons.data[to].rels,   rel)
	return rel
}

PERSON_WIDTH  :: 150
PERSON_HEIGHT :: 100
PERSON_PAD    :: 15
drawn_persons: map[PersonIdx]u8
draw_arena: mem.Allocator


clear_drawn_persons :: proc(void) {
	memset(drawn_persons.data, 0, drawn_persons.cap);
	drawn_persons.len = 0;
	drawn_persons.once_filled = 0;
}

// @Study: Is this a good hash for this specific context?
idx_hash :: proc(idx: PersonIdx) -> u32 {
	return idx
}

idx_eq :: proc(a, b: PersonIdx) -> bool {
	return a == b
}

draw_person :: proc(layer: Layer, display: Display) {
	p: Person = persons.data[layer.i];
	assert(!p.rm);
	rect := rl.Rectangle{ // @TODO (and remove this calc from draw_tree)
		x = layer.x,
		y = 0,
		width = 0,
		height = 0,
	}
	fmt.printf("Drawing Person '%s' at (%f, %f)\n", p.name.str, x, y);
	bounds := rl.Rectangle{
		x = x + display.offset.x,
		y = y + display.offset.y,
		width = w,
		height = h,
	}
	// @TODO: Get rid of hardcoded values here
	rl.DrawRectangle(bounds.x, bounds.y, bounds.w, bounds.h, rl.GRAY)
	rl.DrawText(p.name, bounds.x, bounds.y, 20, rl.WHITE)
}

add_rels_from_layer :: proc(l: Layer, layers: ^[dynamic]Layer) {
	rels := persons.data[l.i].rels;
	for j: u32 = 0; j < rels.len; j += 1 {
		layer: Layer;
		r := rels.data[j];
		switch (r.type) {
			case REL_PARENT: {
				if (l.i == r.from) {
					layer = (Layer) {
						.i   = r.to,
						.tag = KNOWN_Y,
						.y   = l.y - 1,
						.x   = l.x,
					};
				} else {
					layer = (Layer) {
						.i   = r.from,
						.tag = KNOWN_Y,
						.y   = l.y + 1,
						.x   = l.x,
					};
				}
			} break;
			case REL_MARRIED: {
				layer = (Layer) {
					.i   = r.from == l.i ? r.to : r.from,
					.tag = KNOWN_BOTH,
					.x   = l.x + 1,
					.y   = l.y,
				};
			} break;
		}
		append(layers, layer);
	}
}

draw_tree :: proc(start: PersonIdx, degrees: u32, display: Display) {
	clear_drawn_persons();
	p := persons.data[start];
	assert(!p.rm);


	drawn_persons[start] = 1
	draw_person(0, 0, PERSON_WIDTH, PERSON_HEIGHT, p, display);

	// 0 is among the positive y layers
	taken_y_range_per_pos_y := draw_arena.zero_alloc(draw_arena.data, degrees + 1, sizeof(MinMax));
	taken_y_range_per_neg_y := draw_arena.zero_alloc(draw_arena.data, degrees, sizeof(MinMax));
	taken_y_range_per_pos_y[0] = (MinMax) { -1, 1 };

	AIL_DA(Layer) cur_stack  = ail_da_new_with_alloc(Layer, 32, &draw_arena);
	AIL_DA(Layer) next_stack = ail_da_new_with_alloc(Layer, 32, &draw_arena);
	add_rels_from_layer(((Layer) { .i = start, .tag = KNOWN_BOTH, .x = 0, .y = 0 }), &cur_stack);

	for (u32 i = 0; i < 3 + degrees; i++) {
		while (cur_stack.len) {
			Layer next = cur_stack.data[cur_stack.len--];
			assert(!persons.data[next.i].rm);
			u32 drawn_persons_idx; AIL_UNUSED(drawn_persons_idx);
			bool found;
			ail_hm_get_idx(&drawn_persons, next.i, drawn_persons_idx, found);
			if (!found) {
				ail_hm_put(&drawn_persons, next.i, 1);
				if (next.y > (i32)degrees || -next.y > (i32)degrees) continue;
				MinMax mm;
				if (next.y < 0) mm = taken_y_range_per_neg_y[-next.y + 1];
				else            mm = taken_y_range_per_pos_y[next.y];
				if (mm.min < next.x && next.x < mm.max) {
					if (next.x - mm.min > mm.max - next.x) next.x = mm.max++;
					else next.x = mm.min--;
				} else if (next.x < mm.min) mm.min = next.x - 1;
				else                        mm.max = next.x + 1;

				f32 xpos = next.x*(PERSON_WIDTH  + PERSON_PAD) + PERSON_PAD;
				f32 ypos = next.y*(PERSON_HEIGHT + PERSON_PAD) + PERSON_PAD;
				draw_person(xpos, ypos, PERSON_WIDTH, PERSON_HEIGHT, persons.data[next.i], display);

				add_rels_from_layer(next, &next_stack);
			}
		}
		AIL_SWAP_PORTABLE(AIL_DA(Layer), cur_stack, next_stack);
	}
	draw_arena.free_all(draw_arena.data);
}


int main(void)
{
	ail_gui_allocator = ail_alloc_arena_new(2*AIL_ALLOC_PAGE_SIZE, &ail_alloc_pager);
	draw_arena        = ail_alloc_arena_new(2*AIL_ALLOC_PAGE_SIZE, &ail_alloc_pager);
	AIL_Allocator rel_pool    = ail_alloc_pool_new(2*AIL_ALLOC_PAGE_SIZE, sizeof(Rel),    &ail_alloc_pager);
	AIL_Allocator person_pool = ail_alloc_pool_new(2*AIL_ALLOC_PAGE_SIZE, sizeof(Person), &ail_alloc_pager);
	drawn_persons = ail_hm_new_with_alloc(PersonIdx, u8, 2048, &idx_hash, &idx_eq, &ail_alloc_std);
	persons = person_list_init(2048, &person_pool);

	person_add((Person) { .name = ail_str_from_cstr("Rene"),      .sex = SEX_M, .rels = ail_da_new_with_alloc(Rel, 16, &rel_pool) });
	person_add((Person) { .name = ail_str_from_cstr("Katharina"), .sex = SEX_F, .rels = ail_da_new_with_alloc(Rel, 16, &rel_pool) });
	person_add((Person) { .name = ail_str_from_cstr("Samuel"),    .sex = SEX_M, .rels = ail_da_new_with_alloc(Rel, 16, &rel_pool) });
	person_add((Person) { .name = ail_str_from_cstr("Val"),       .sex = SEX_F, .rels = ail_da_new_with_alloc(Rel, 16, &rel_pool) });
	person_add((Person) { .name = ail_str_from_cstr("Annika"),    .sex = SEX_F, .rels = ail_da_new_with_alloc(Rel, 16, &rel_pool) });
	rel_add(0, 1, REL_MARRIED);
	rel_add(0, 2, REL_PARENT);
	rel_add(0, 3, REL_PARENT);
	rel_add(0, 4, REL_PARENT);
	rel_add(1, 2, REL_PARENT);
	rel_add(1, 3, REL_PARENT);
	rel_add(1, 4, REL_PARENT);

	int win_width  = 800;
	int win_height = 600;
	SetConfigFlags(FLAG_WINDOW_RESIZABLE);
	InitWindow(win_width, win_height, "Family Tree Make");

	Display display;
	display.offset = (Vector2) {
		.x = -win_width/2,
		.y = -win_height/2,
	};
	display.zoom = 1.0f;

	Font font = GetFontDefault();
	style_default = (AIL_Gui_Style) {
		.bg           = GRAY,
		.border_color = BLANK,
		.border_width = 0,
		.color        = WHITE,
		.font         = font,
		.font_size    = 25,
		.cSpacing     = 2,
		.lSpacing     = 5,
		.hAlign       = AIL_GUI_ALIGN_C,
		.vAlign       = AIL_GUI_ALIGN_C,
		.pad          = 10,
	};

	while (!WindowShouldClose()) {
		if (IsWindowResized()) {
			win_width  = GetScreenWidth();
			win_height = GetScreenHeight();
		}

		BeginDrawing();
			ClearBackground(BLACK);
			draw_tree(3, 2, display);
			DrawFPS(10, 10);
		EndDrawing();
		ail_gui_allocator.free_all(ail_gui_allocator.data);
	}
	CloseWindow();
	return 0;
}