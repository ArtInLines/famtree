#define AIL_ALL_IMPL
#define AIL_ALLOC_IMPL
#define AIL_GUI_IMPL
#define AIL_SV_IMPL
#define AIL_HM_IMPL
#include "ail.h"
#include "ail_hm.h"
#include "ail_sv.h"
#include "ail_gui.h"
#include "ail_alloc.h"
#include "raylib.h"

#if !defined(_DEBUG) || defined(DEBUG)
#undef AIL_ASSERT
#define AIL_ASSERT(cond) do { if (0) !!cond; }
#endif

typedef u32 PersonIdx;
#define NULL_IDX UINT32_MAX
AIL_HM_INIT(PersonIdx, u8);


// For displaying

// Bitmask for coordinate that is known
typedef enum LayerKnowledge {
	KNOWN_X = 1,    // 0b01
	KNOWN_Y = 2,    // 0b10
	KNOWN_BOTH = 3, // 0b11
} LayerKnowledge;

typedef struct MinMax {
	i16 min;
	i16 max;
} MinMax;
AIL_DA_INIT(MinMax);

// The layer that a person is on in the family tree
// The starting character is always on 0,0
// Siblings are on the same y with a different x
// Parents are on a lower y, with x-1 and x+1 respectively (unless it's a single parent of course)
// `tag` indicates whether one of the coordinates is not yet known
typedef struct Layer {
	i16 y;
	i16 x;
	PersonIdx i;
	LayerKnowledge tag;
} Layer;
AIL_DA_INIT(Layer);

typedef struct Display {
	Vector2 offset;
	f32 zoom;
} Display;


// For modelling

typedef enum Sex {
	SEX_F,  // female
	SEX_M,  // male
	SEX_U,  // unknown
} Sex;

typedef enum RelType {
	REL_MARRIED,
	REL_PARENT,
} RelType;

typedef struct Rel {
	RelType type;
	PersonIdx from;
	PersonIdx to;
} Rel;
AIL_DA_INIT(Rel);

typedef struct Person {
	bool rm; // Indicates whether the person has been removed or not
	Sex sex;
	AIL_Str name;
	AIL_DA(Rel) rels;
} Person;

// PersonList is a dynamic array, that guarantuees indexes to stay correct forever
// It does so by storing a linked-list of previously removed indexes
// @Implementation:
// The linked-list is stored in the same memory as the Person structs
// The `rm` field of the Person indicates whetehr the person has been removed already
// The `name` field is re-interpreted as a PersonIdx and stores the index to the next free index
// or NULL_IDX at the end of the linked-list
typedef struct PersonList {
	Person *data;
	u32 len;
	u32 cap;
	PersonIdx free_head; // Free-list via indexes instead of pointers
	AIL_Allocator *allocator;
} PersonList;
// Global PersonList -> all Persons are allocated and managed in this list
static PersonList persons;

PersonIdx person_add(Person p)
{
	if (persons.free_head != NULL_IDX) {
		AIL_ASSERT(persons.data[persons.free_head].rm);
		PersonIdx idx  = persons.free_head;
		PersonIdx next = *(PersonIdx *)&(persons.data[idx].name);
		persons.data[idx] = p;
		persons.free_head = next;
		return idx;
	} else {
		ail_da_push(&persons, p);
		return persons.len - 1;
	}
}

void person_rm(PersonIdx idx)
{
	AIL_ASSERT(!persons.data[idx].rm);
	if (AIL_UNLIKELY(persons.data[idx].rm)) return;
	persons.data[idx].rm = true;
	*(PersonIdx *)&(persons.data[idx].name) = persons.free_head;
	persons.free_head = idx;
}

PersonList person_list_init(u32 cap, AIL_Allocator *allocator)
{
	return (PersonList) {
		.data = allocator->alloc(allocator->data, sizeof(Person) * cap),
		.len  = 0,
		.cap  = cap,
		.free_head = NULL_IDX,
		.allocator = allocator,
	};
}

Rel rel_add(PersonIdx from, PersonIdx to, RelType type)
{
	Rel rel = { .from = from, .to = to, .type = type };
	ail_da_push(&persons.data[from].rels, rel);
	ail_da_push(&persons.data[to].rels,   rel);
	return rel;
}

#define PERSON_WIDTH  150
#define PERSON_HEIGHT 100
#define PERSON_PAD    15
AIL_Gui_Style style_default;
AIL_HM(PersonIdx, u8) drawn_persons;
AIL_Allocator draw_arena;


void clear_drawn_persons(void)
{
	memset(drawn_persons.data, 0, drawn_persons.cap);
	drawn_persons.len = 0;
	drawn_persons.once_filled = 0;
}

// @Study: Is this a good hash for this specific context?
u32 idx_hash(PersonIdx idx)
{
	return idx;
}

bool idx_eq(PersonIdx a, PersonIdx b)
{
	return a == b;
}

void draw_person(Layer layer, Display display)
{
	Person p = persons.data[layer.i];
	AIL_ASSERT(!p.rm);
	Rectangle rect = { // @TODO (and remove this calc from draw_tree)a
		.x = layer.x
	};
	printf("Drawing Person '%s' at (%f, %f)\n", p.name.str, x, y);
	AIL_Gui_Label label = {
		.bounds       = (Rectangle) { x + display.offset.x, y + display.offset.y, w, h },
		.text         = ail_da_from_parts(char, p.name.str, p.name.len + 1, p.name.len + 1, NULL),
		.defaultStyle = style_default,
		.hovered      = style_default,
	};
	ail_gui_drawLabel(label);
}

void add_rels_from_layer(Layer l, AIL_DA(Layer) *layers)
{
	AIL_DA(Rel) rels = persons.data[l.i].rels;
	for (u32 j = 0; j < rels.len; j++) {
		Layer layer;
		Rel r = rels.data[j];
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
		ail_da_push(layers, layer);
	}
}

void draw_tree(PersonIdx start, u32 degrees, Display display)
{
	clear_drawn_persons();
	Person p = persons.data[start];
	AIL_ASSERT(!p.rm);

	ail_hm_put(&drawn_persons, start, 1);
	draw_person(0, 0, PERSON_WIDTH, PERSON_HEIGHT, p, display);

	// 0 is among the positive y layers
	MinMax *taken_y_range_per_pos_y = draw_arena.zero_alloc(draw_arena.data, degrees + 1, sizeof(MinMax));
	MinMax *taken_y_range_per_neg_y = draw_arena.zero_alloc(draw_arena.data, degrees, sizeof(MinMax));
	taken_y_range_per_pos_y[0] = (MinMax) { -1, 1 };

	AIL_DA(Layer) cur_stack  = ail_da_new_with_alloc(Layer, 32, &draw_arena);
	AIL_DA(Layer) next_stack = ail_da_new_with_alloc(Layer, 32, &draw_arena);
	add_rels_from_layer(((Layer) { .i = start, .tag = KNOWN_BOTH, .x = 0, .y = 0 }), &cur_stack);

	for (u32 i = 0; i < 3 + degrees; i++) {
		while (cur_stack.len) {
			Layer next = cur_stack.data[cur_stack.len--];
			AIL_ASSERT(!persons.data[next.i].rm);
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