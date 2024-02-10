#define AIL_ALL_IMPL
#define AIL_ALLOC_IMPL
#define AIL_GUI_IMPL
#define AIL_SV_IMPL
#include "ail.h"
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


int main(void)
{
	AIL_Allocator ail_gui_allocator = ail_alloc_arena_new(2*AIL_ALLOC_PAGE_SIZE, &ail_alloc_pager);
	AIL_Allocator rel_pool    = ail_alloc_pool_new(2*AIL_ALLOC_PAGE_SIZE, sizeof(Rel),    &ail_alloc_pager);
	AIL_Allocator person_pool = ail_alloc_pool_new(2*AIL_ALLOC_PAGE_SIZE, sizeof(Person), &ail_alloc_pager);
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

	Font font = GetFontDefault();
	AIL_Gui_Style style_default = {
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
			u32 person_width  = 150;
			u32 person_height = 200;
			u32 person_pad    = 15;
			for (u32 i = 0; i < persons.len; i++) {
				if (AIL_LIKELY(!persons.data[i].rm)) {
					Person p = persons.data[i];
					AIL_Gui_Label label = {
						.bounds       = (Rectangle) {
							.x = i*(person_width + person_pad) + person_pad,
							.y = 20,
							.width  = person_width,
							.height = person_height,
						},
						.defaultStyle = style_default,
						.hovered      = style_default,
						.text         = ail_da_from_parts(char, p.name.str, p.name.len + 1, p.name.len + 1, NULL),
					};
					ail_gui_drawLabel(label);
				}
			}

		EndDrawing();
		ail_gui_allocator.free_all(ail_gui_allocator.data);
	}
	CloseWindow();
	return 0;
}