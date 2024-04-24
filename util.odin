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