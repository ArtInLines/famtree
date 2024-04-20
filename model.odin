package famtree

import "base:runtime"
import "core:mem"
import "core:c"

// @Note: PersonHandle of 0 represents an invalid handle
PersonHandle :: distinct u32;

RelInternalID :: distinct u16
RelHandle :: struct {
	ph: PersonHandle,
	id: RelInternalID,
}

// @Note: year/month/day of 0 represent an unknown month/day
// @Note: to represent year 0, use -1 (all negative years are offset by -1)
Date :: struct {
	year: i16,
	month, day: u8,
}

// @Note: Treats unknown dates as 0
// @Note: date_is_before_simple(d, d) returns false
date_is_before_simple :: #force_inline proc(d1, d2: Date) -> bool {
	return d1.year < d2.year || d1.month < d2.month || d1.day < d2.month
}

// @Note: Treats two unknown dates as unequal
// @Note: date_is_before(d, d) returns false
date_is_before :: proc(d1, d2: Date) -> bool {
	return (d1.year  != 0 && d2.year  != 0 && d1.year  < d2.year)  ||
		   (d1.month != 0 && d2.month != 0 && d1.month < d2.month) ||
		   (d1.day   != 0 && d2.day   != 0 && d1.day   < d2.day)
}

// @Note: Treats two unknown dates as equal
date_eq_simple :: proc(d1, d2: Date) -> bool {
	return d1.year == d2.year && d1.month == d2.month && d1.day == d2.day
}

// @Note: Treats two unknown dates as unequal
date_eq :: proc(d1, d2: Date) -> bool {
	return d1.year  != 0 && d1.year  == d2.year  &&
		   d1.month	!= 0 && d1.month == d2.month &&
		   d1.day   != 0 && d1.day   == d1.day
}

Sex :: enum u8 {
	Unknown = 0,
	Female,
	Male,
	Inter,
}

RelType :: enum u8 {
	Parent,  // From Parent to child
	Married,
	Affair,
	Friend,
}

Rel :: struct {
	id:         RelInternalID,
	person:     PersonHandle,
	type:       RelType,
	is_over:    bool,
	start, end: Date,
}

Person :: struct {
	name: string,
	sex:  Sex,
	birth, death: Date,
}

PersonRels :: struct {
	next_id: RelInternalID,
	from: [dynamic]PersonHandle, // Persons, that have relations to this person
	rels: [RelType][dynamic]Rel, // Relations from this person to other persons
}

PersonEl :: union { Person, PersonHandle }

FullPerson :: struct {
	person: Person,
	rels:   PersonRels,
}

// @Implementation:
// Persons and relations are kept in parallel arrays
// both are dynamic arrays, that guarantuees indexes to stay stable forever
// This is achieved by storing a linked-list of previously removed indexes in the persons Array
// The array must always have at least 1 element
// The first element is always the head of the linked list
// The 0 index represents the end of the linked list
// A PersonHandle can thus simply be an index into this array and thus be guarantueed stable
// @Memory: rels doesn't track the freelist, but still keeps the 0th element free, thus wasting one element worth of memory
// This could be optimized by subtracting the PersonHandle by 1 each time we access the rels array (thus increasing code complexity for memory optimization)
PersonManager :: struct {
	persons: [dynamic]PersonEl,
	rels:    [dynamic]PersonRels,
}

person_manager_init :: proc(cap := 16, allocator := context.allocator) -> PersonManager {
	persons := make([dynamic]PersonEl,   1, max(cap, 16), allocator)
	rels    := make([dynamic]PersonRels, 1, max(cap, 16), allocator)
	pm := PersonManager { persons, rels }
	pm.persons[0] = PersonHandle(0)
	return pm
}

person_get :: #force_inline proc(pm: PersonManager, ph: PersonHandle) -> Person {
	return pm.persons[ph].(Person)
}

person_get_ptr :: #force_inline proc(pm: PersonManager, ph: PersonHandle) -> ^Person {
	return &pm.persons[ph].(Person)
}

person_get_rels :: #force_inline proc(pm: PersonManager, ph: PersonHandle) -> PersonRels {
	return pm.rels[ph]
}

person_get_rels_ptr :: #force_inline proc(pm: PersonManager, ph: PersonHandle) -> ^PersonRels {
	return &pm.rels[ph]
}

person_get_full :: #force_inline proc(pm: PersonManager, ph: PersonHandle) -> FullPerson {
	return FullPerson {
		person = person_get(pm, ph),
		rels   = person_get_rels(pm, ph),
	}
}

rel_get :: #force_inline proc(pm: PersonManager, rh: RelHandle) -> Rel {
	for rels in pm.rels[rh.ph].rels {
		for rel in rels {
			if rel.id == rh.id do return rel
		}
	}
	return {}
}

rel_get_ptr :: #force_inline proc(pm: PersonManager, rh: RelHandle) -> ^Rel {
	for _, i in pm.rels[rh.ph].rels {
		for _, j in pm.rels[rh.ph].rels[i] {
			if pm.rels[rh.ph].rels[i][j].id == rh.id do return &pm.rels[rh.ph].rels[i][j]
		}
	}
	return {}
}

person_add :: proc(pm: ^PersonManager, p: Person) -> (ph: PersonHandle, err: runtime.Allocator_Error) #optional_allocator_error {
	ph = pm.persons[0].(PersonHandle)
	if (ph == {}) {
		ph  = PersonHandle(len(pm.persons))
		_, err  = append_elem(&pm.persons, PersonEl{})
		_, err2 := append_elem(&pm.rels, PersonRels{})
		if err == nil do err = err2
	} else {
		pm.persons[0] = pm.persons[ph]
	}
	allocator := ((^runtime.Raw_Dynamic_Array)(&pm.persons)).allocator
	pm.persons[ph] = p
	pm.rels[ph]    = {} // Set to zero
	return ph, err
}

person_rm :: proc(pm: ^PersonManager, ph: PersonHandle) {
	pm.persons[ph] = pm.persons[0].(PersonHandle)
	pm.persons[0]  = ph
	for i in pm.rels[ph].from {
		for _, j in pm.rels[i].rels {
			xs := &pm.rels[i].rels[j]
			k  := 0
			for k < len(xs) {
				if xs[k].person == ph do unordered_remove(xs, k)
				else do k += 1
			}
		}
	}
	for rels in pm.rels[ph].rels {
		for rel in rels {
			from := &pm.rels[rel.person].from
			j := 0
			for j < len(from) {
				if from[j] == ph do unordered_remove(from, j)
				else do j += 1
			}
		}
		delete(rels)
	}
	delete(pm.rels[ph].from)
}

rel_add :: proc(pm: ^PersonManager, from: PersonHandle, rel: Rel) -> (val: RelHandle, err: runtime.Allocator_Error) #optional_allocator_error {
	r := rel
	r.id = pm.rels[from].next_id
	pm.rels[from].next_id += 1
	_, err   = append_elem(&pm.rels[from].rels[rel.type], r)
	_, err2 := append_elem(&pm.rels[rel.person].from, from)
	if err == nil do err = err2
	val = RelHandle {
		ph = from,
		id = r.id,
	}
	return val, err
}

rel_rm :: proc(pm: ^PersonManager, rh: RelHandle) {
	for _, i in pm.rels[rh.ph].rels {
		for _, j in pm.rels[rh.ph].rels[i] {
			rel := pm.rels[rh.ph].rels[i][j]
			if rel.id == rh.id {
				rm_ref: for _, k in pm.rels[rel.person].from {
					if pm.rels[rel.person].from[k] == rh.ph {
						unordered_remove(&pm.rels[rel.person].from, k)
						break rm_ref
					}
				}
				unordered_remove(&pm.rels[rh.ph].rels[i], j)
				return
			}
		}
	}
}
