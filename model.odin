package famtree

import "base:runtime"
import "core:mem"
import "core:fmt" // @Cleanup
import "core:c"

// @Note: PersonHandle of 0 represents an invalid handle
// @Impl: A PersonHandle is an index into the array of all persons (stored in the PersonManager struct).
// @Impl: The 0th element stores the head for a freelist and is thus used to represent unknown/missing persons
PersonHandle  :: distinct u32;

// @Note: ParentsHandle is a unique handle for a person's parents, whether they have 0, 1 or 2 stored parents
// @Note: A ParentsHandle of 0 represents that the person has no parents
// @Impl: It stores both PersonHandles of the parents packed as a single number, with the higher number in the upper 4 bytes
// @Impl: If only one or no parents exist, 0 is used as a PersonHandle for them, thus naturally creating 0 as a Handle for when no parents are stored
ParentsHandle :: distinct u64;

@(private="file")
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
    Married,
    Affair,
    Friend,
}

Rel :: struct {
    id:         RelInternalID,
    to:         PersonHandle,
    from:       PersonHandle,
    type:       RelType,
    is_over:    bool,
    start, end: Date, // @Note: Only change start through `rel_set_start`
}

// @TODO: Store births in a seperate array, because they are often accessed in layouting without requiring the rest of the person-data
Person :: struct {
    name: string,
    sex:  Sex,
    birth, death: Date, // @Note: Only change birth through `person_set_birth`
}

// @Note: rels/from are sorted by start date (oldest relation first)
// @Note: children are sorted by birth (oldest child first)
// @Note: children contain both official & actual children -> check the child's parents to see whether they are only officially or actually a parent
// @Note: actual_parents only holds data if its different to official_parents
RelsOfPerson :: struct {
    next_id: RelInternalID,
    official_parents: [2]PersonHandle, // handle is 0, if parent is unknown
    actual_parents:   [2]PersonHandle, // parallel to official_parents; handle is 0 if its the same as in official_parents
    children: [dynamic]PersonHandle,   // other parent can be found via the children's RelsOfPerson object
    rels: [RelType][dynamic]Rel,       // Relations from this person to other persons
    from: [RelType][dynamic]RelHandle, // Relations from other persons to this person
}

FullPerson :: struct {
    person: Person,
    rels:   RelsOfPerson,
}

@(private="file")
PersonManagerInternalEl :: union { Person, PersonHandle }

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
    persons: [dynamic]PersonManagerInternalEl,
    rels:    [dynamic]RelsOfPerson,
}

person_manager_init :: proc(cap := 16, allocator := context.allocator) -> PersonManager {
    persons := make([dynamic]PersonManagerInternalEl, 1, max(cap, 16), allocator)
    rels    := make([dynamic]RelsOfPerson,            1, max(cap, 16), allocator)
    pm := PersonManager { persons, rels }
    pm.persons[0] = PersonHandle(0)
    return pm
}

person_get :: #force_inline proc(pm: PersonManager, ph: PersonHandle) -> Person {
    assert(ph != {})
    return pm.persons[ph].(Person)
}

person_get_ptr :: #force_inline proc(pm: PersonManager, ph: PersonHandle) -> ^Person {
    assert(ph != {})
    return &pm.persons[ph].(Person)
}

person_get_rels :: #force_inline proc(pm: PersonManager, ph: PersonHandle) -> RelsOfPerson {
    assert(ph != {})
    return pm.rels[ph]
}

person_get_rels_ptr :: #force_inline proc(pm: PersonManager, ph: PersonHandle) -> ^RelsOfPerson {
    assert(ph != {})
    return &pm.rels[ph]
}

person_get_full :: #force_inline proc(pm: PersonManager, ph: PersonHandle) -> FullPerson {
    assert(ph != {})
    return FullPerson {
        person = person_get(pm, ph),
        rels   = person_get_rels(pm, ph),
    }
}

@(private="file")
sort_children :: proc(pm: PersonManager, children: ^[dynamic]PersonHandle) {
    children_count := len(children)
    for i in 1..<children_count {
        cur_birth := person_get(pm, children[i]).birth
        for j := i; j > 0 && date_is_before_simple(cur_birth, person_get(pm, children[j - 1]).birth); j -= 1 {
            children[j], children[j-1] = children[j-1], children[j]
        }
    }
}

person_set_birth :: #force_inline proc(pm: PersonManager, ph: PersonHandle, new_birth: Date) {
    person_get_ptr(pm, ph).birth = new_birth
    for parent in person_get_rels_ptr(pm, ph).official_parents {
        if parent != {} do sort_children(pm, &person_get_rels_ptr(pm, parent).children)
    }
    for parent in person_get_rels_ptr(pm, ph).actual_parents {
        if parent != {} do sort_children(pm, &person_get_rels_ptr(pm, parent).children)
    }
}

handle_of_rel :: #force_inline proc(rel: Rel) -> RelHandle {
    return RelHandle {
        ph = rel.from,
        id = rel.id,
    }
}

is_official_parent :: #force_inline proc(pm: PersonManager, child, parent: PersonHandle) -> bool {
    child_rels := person_get_rels(pm, child)
    return index_of(child_rels.official_parents[:], parent) >= 0
}

is_actual_parent :: #force_inline proc(pm: PersonManager, child, parent: PersonHandle) -> bool {
    child_rels := person_get_rels(pm, child)
    idx := index_of(child_rels.official_parents[:], parent)
    return (idx >= 0 && child_rels.actual_parents[idx] == {}) || (idx < 0 && child_rels.actual_parents[idx] != {})
}

// @TODO: Names "handle_of_parents" and "get_parents_handle" are kinda confusing and could be more clear
handle_of_parents :: #force_inline proc(parent1, parent2: PersonHandle) -> ParentsHandle {
    upper, lower: ParentsHandle
    if parent1 >= parent2 do upper, lower = ParentsHandle(parent1), ParentsHandle(parent2)
    else                  do upper, lower = ParentsHandle(parent2), ParentsHandle(parent1)
    res := ParentsHandle((upper << 32) | (lower << 0))
    // fmt.printf("handle_of_parents(0x%x, 0x%x) => 0x%x\n", parent1, parent2, res)
    return res
}

get_parents_handle :: #force_inline proc(pm: PersonManager, child: PersonHandle, actual_parents: bool) -> ParentsHandle {
    rels := person_get_rels(pm, child)
    parents := actual_parents ? rels.actual_parents : rels.official_parents
    return handle_of_parents(parents[0], parents[1])
}

// @Note: Guarantuees that if there's only one parent, it will be the first element in the output array
// @Note: To check whether there's only one parent, simply check `parents[1] == {}`
get_parents_from_handle :: #force_inline proc(parents: ParentsHandle) -> [2]PersonHandle {
    res: [2]PersonHandle = { PersonHandle((parents >> 32) & 0xff), PersonHandle(parents & 0xff) }
    // fmt.printf("person_handle(0x%x) => [0x%x, 0x%x]\n", parents, res[0], res[1]);
    return res;
}

rel_get_fast :: #force_inline proc(pm: PersonManager, rh: RelHandle, rel_type: RelType) -> Rel {
    assert(rh.ph != {})
    for rel in pm.rels[rh.ph].rels[rel_type] {
        if rel.id == rh.id do return rel
    }
    return {}
}

rel_get :: #force_inline proc(pm: PersonManager, rh: RelHandle) -> Rel {
    assert(rh.ph != {})
    for rels in pm.rels[rh.ph].rels {
        for rel in rels {
            if rel.id == rh.id do return rel
        }
    }
    return {}
}

rel_get_ptr_fast :: #force_inline proc(pm: PersonManager, rh: RelHandle, rel_type: RelType) -> ^Rel {
    assert(rh.ph != {})
    for _, i in pm.rels[rh.ph].rels[rel_type] {
        if pm.rels[rh.ph].rels[rel_type][i].id == rh.id do return &pm.rels[rh.ph].rels[rel_type][i]
    }
    return nil
}

rel_get_ptr :: #force_inline proc(pm: PersonManager, rh: RelHandle) -> ^Rel {
    assert(rh.ph != {})
    for _, type in pm.rels[rh.ph].rels {
        for _, i in pm.rels[rh.ph].rels[type] {
            if pm.rels[rh.ph].rels[type][i].id == rh.id do return &pm.rels[rh.ph].rels[type][i]
        }
    }
    return nil
}

@(private="file")
sort_rels :: proc(pm: PersonManager, rels: ^[dynamic]Rel) {
    count := len(rels)
    for i in 1..<count {
        cur_start := rels[i].start
        for j := i; j > 0 && date_is_before_simple(cur_start, rels[j-1].start); j -= 1 {
            rels[j], rels[j-1] = rels[j-1], rels[j]
        }
    }
}

@(private="file")
sort_from_rels :: proc(pm: PersonManager, from: ^[dynamic]RelHandle, rel_type: RelType) {
    count := len(from)
    for i in 1..<count {
        cur_start := rel_get_fast(pm, from[i], rel_type).start
        for j := i; j > 0 && date_is_before_simple(cur_start, rel_get_fast(pm, from[j - 1], rel_type).start); j -= 1 {
            from[j], from[j-1] = from[j-1], from[j]
        }
    }
}

@(private="file")
rel_insert_sorted :: proc(rels: ^[dynamic]Rel, rel: Rel) -> (err: runtime.Allocator_Error) {
    count := len(rels)
    for i in 0..<count {
        if date_is_before_simple(rel.start, rels[i].start) {
            _, err = inject_at(rels, i, rel)
            return err
        }
    }
    _, err = append_elem(rels, rel)
    return err
}

@(private="file")
from_insert_sorted :: proc(pm: PersonManager, from: ^[dynamic]RelHandle, rh: RelHandle) -> (err: runtime.Allocator_Error) {
    count := len(from)
    rel   := rel_get(pm, rh)
    for i in 0..<count {
        if date_is_before_simple(rel.start, rel_get_fast(pm, from[i], rel.type).start) {
            _, err = inject_at(from, i, rh)
            return err
        }
    }
    _, err = append_elem(from, rh)
    return err
}

rel_set_start :: #force_inline proc(pm: PersonManager, rh: RelHandle, new_start: Date) {
    assert(rh.ph != {})
    for _, type in pm.rels[rh.ph].rels {
        for _, i in pm.rels[rh.ph].rels[type] {
            rels := &pm.rels[rh.ph].rels[type]
            if rels[i].id == rh.id {
                rels[i].start = new_start
                sort_from_rels(pm, &person_get_rels_ptr(pm, rels[i].to).from[type], type)
                sort_rels(pm, rels)
            }
        }
    }
}

person_add :: proc(pm: ^PersonManager, p: Person) -> (ph: PersonHandle, err: runtime.Allocator_Error) #optional_allocator_error {
    ph = pm.persons[0].(PersonHandle)
    if (ph == {}) {
        ph  = PersonHandle(len(pm.persons))
        _, err   = append_elem(&pm.persons, PersonManagerInternalEl{})
        _, err2 := append_elem(&pm.rels,    RelsOfPerson{})
        if err == nil do err = err2
    } else {
        pm.persons[0] = pm.persons[ph]
    }
    allocator := ((^runtime.Raw_Dynamic_Array)(&pm.persons)).allocator
    pm.persons[ph] = p
    pm.rels[ph]    = {} // Set to zero
    return ph, err
}

@(private="file")
rm_rel_ref_in_from_list :: proc(pm: PersonManager, rel: Rel) {
    from := &person_get_rels_ptr(pm, rel.to).from[rel.type]
    for _, i in from {
        if from[i] == handle_of_rel(rel) {
            ordered_remove(from, i)
            return
        }
    }
}

person_rm :: proc(pm: ^PersonManager, ph: PersonHandle) {
    // Remove from pool of persons stored in PersonManager
    rels_of_ph    := person_get_rels_ptr(pm^, ph)
    pm.persons[ph] = pm.persons[0].(PersonHandle)
    pm.persons[0]  = ph

    // Remove from children arrays of parents
    for parent in rels_of_ph.actual_parents {
        if parent != {} do ordered_remove_elem(&person_get_rels_ptr(pm^, parent).children, ph)
    }
    for parent in rels_of_ph.official_parents {
        if parent != {} do ordered_remove_elem(&person_get_rels_ptr(pm^, parent).children, ph)
    }

    // Remove each reference in `from`s to relations by this person and free memory
    for rels in rels_of_ph.rels {
        for rel in rels {
            rm_rel_ref_in_from_list(pm^, rel)
        }
        delete(rels)
    }

    // Remove each relation to this person and free memory
    for rhs in rels_of_ph.from {
        for rh in rhs {
            rel_rm(pm^, rh)
        }
        delete(rhs)
    }
}

rel_add :: proc(pm: PersonManager, rel: Rel) -> (val: RelHandle, err: runtime.Allocator_Error) #optional_allocator_error {
    r := rel
    r.id = pm.rels[rel.from].next_id
    pm.rels[rel.from].next_id += 1
    val   = handle_of_rel(r)
    err   = rel_insert_sorted(&pm.rels[rel.from].rels[rel.type], r)
    err2 := from_insert_sorted(pm, &pm.rels[rel.to].from[rel.type], val)
    if err == nil do err = err2
    return val, err
}

rel_rm :: proc(pm: PersonManager, rh: RelHandle) {
    for _, type in pm.rels[rh.ph].rels {
        for _, i in pm.rels[rh.ph].rels[type] {
            rel := pm.rels[rh.ph].rels[type][i]
            if rel.id == rh.id {
                rm_rel_ref_in_from_list(pm, rel)
                ordered_remove(&pm.rels[rh.ph].rels[type], i)
                return
            }
        }
    }
}

child_add :: proc(pm: PersonManager, child, officialParent1: PersonHandle, officialParent2: PersonHandle = 0, actualParent1: PersonHandle = 0, actualParent2: PersonHandle = 0) {
    person_get_rels_ptr(pm, child).official_parents = {officialParent1, officialParent2}
    person_get_rels_ptr(pm, child).actual_parents   = {actualParent1,   actualParent2}
    parents: []PersonHandle = {officialParent1, officialParent2, actualParent1, actualParent2}
    for p in parents {
        if p != 0 {
            children := &person_get_rels_ptr(pm, p).children
            append(children, child)
            sort_children(pm, children)
        }
    }
}

// @TODO: child_rm
