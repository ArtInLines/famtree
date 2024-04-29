package famtree

// @Note: Returns -1 if el is not in arr
index_of :: proc(arr: $T/[]$E, el: E) -> int {
    for x, i in arr {
        if x == el do return i
    }
    return -1
}

ordered_remove_elem :: #force_inline proc(arr: ^$T/[dynamic]$E, el: E, loc := #caller_location) {
    idx := index_of(arr[:], el)
    ordered_remove(arr, idx, loc = loc)
}

get_other_of_tuple :: #force_inline proc(tuple: $T/[2]$E, el: E) {
    if el == tuple[0] do return tuple[1]
    else do return tuple[0]
}