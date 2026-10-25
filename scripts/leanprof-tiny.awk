# Marks the functions of a Lean-generated C file that `--auto` leaves
# untimed (see scripts/leanprof-cc): a function that takes a nanosecond or
# two costs less than its probes, whose cost then is most of what is
# reported for it and for every function around it, and is a large part of
# the program's time. Such a function is straight-line code (no loop, no
# join point: no `goto`) that calls nothing but the O(1) operations of
# lean.h below and functions of the same file that are themselves tiny, and
# that frees nothing but boxed scalars (a `lean_dec` of anything else, or a
# `lean_ctor_release`, can free a whole structure). Natural-number
# arithmetic is not O(1): `lean_nat_add`, `lean_nat_sub` and `lean_nat_succ`
# fall back to big-number code, linear in the size of their operands, and
# are never tiny; a comparison is O(1) only when one side is a constant
# small number (`lean_box` or `lean_unsigned_to_nat` of a literal: a big
# number is larger than any small one, which is decided without reading its
# digits). It gets `no_instrument_function`, and its address goes in a table that a constructor hands to leanprof's runtime
# (leanprof_untimed_register), which the report lists by name. (A linker
# section read back with __start_/__stop_ symbols was dropped by Linux
# linkers that garbage-collect sections: the list came out empty there.)
#
# usage: awk -f leanprof-tiny.awk file.c > out.c
BEGIN {
    # lean.h operations that do a bounded amount of work
    split("lean_box lean_unbox lean_box_uint32 lean_unbox_uint32 lean_box_uint64 lean_unbox_uint64 " \
          "lean_box_usize lean_unbox_usize lean_box_float lean_unbox_float lean_box_float32 lean_unbox_float32 " \
          "lean_ctor_get lean_ctor_set lean_ctor_set_tag lean_ctor_num_objs lean_obj_tag lean_ptr_tag " \
          "lean_is_scalar lean_is_exclusive lean_is_shared lean_alloc_ctor " \
          "lean_inc lean_inc_n lean_inc_ref lean_inc_ref_n lean_mark_persistent " \
          "lean_unsigned_to_nat lean_usize_to_nat lean_uint64_to_nat " \
          "lean_array_size lean_array_get_size lean_array_fget lean_array_uget lean_array_get_core " \
          "lean_sarray_size lean_string_utf8_byte_size lean_string_byte_size", ok, " ")
    for (i in ok) allow[ok[i]] = 1
    # O(1) when one operand is a small number (see above)
    split("lean_nat_dec_eq lean_nat_dec_lt lean_nat_dec_le lean_nat_eq lean_nat_lt lean_nat_le lean_nat_ne", cmp, " ")
    for (i in cmp) natcmp[cmp[i]] = 1
    prefixes = "^(lean_ctor_get_|lean_ctor_set_|lean_uint8_|lean_uint16_|lean_uint32_|lean_uint64_|lean_usize_|" \
               "lean_int8_|lean_int16_|lean_int32_|lean_int64_|lean_isize_|lean_float_|lean_float32_|lean_bool_)"
    nf = 0
}

# One side of a comparison's arguments `a` (cut at the first `)`, so an
# argument `lean_box(0)` reads `lean_box(0`) is a constant small number.
function small(a,    p, n, j, x) {
    n = split(a, p, ",")
    for (j = 1; j <= n; j++) {
        x = p[j]
        gsub(/[ \t]/, "", x)
        if (x in lit || x ~ /^(lean_box|lean_unsigned_to_nat)\([0-9]+u?$/) return 1
    }
    return 0
}

function scan(k,    body, rest, name, a, j, args, v) {
    body = B[k]
    # labels other than the `_start:` every function has, and gotos, are loops or join points
    rest = body
    sub(/_start:/, "", rest)
    if (rest ~ /goto / || rest ~ /\n[A-Za-z_][A-Za-z0-9_]*:/) return 0
    # loops written any other way (Lean's C loops with goto, but be safe)
    if (rest ~ /(^|[^A-Za-z0-9_])(while|for|do)[ \t\n]*[({]/) return 0
    if (gsub(/;/, ";", rest) > 60) return 0
    # boxed scalars this function unboxes: freeing those is bounded
    delete boxed
    v = rest
    while (match(v, /lean_unbox[a-z0-9_]*\([A-Za-z_][A-Za-z0-9_]*\)/)) {
        a = substr(v, RSTART, RLENGTH)
        sub(/^[^(]*\(/, "", a); sub(/\)$/, "", a)
        boxed[a] = 1
        v = substr(v, RSTART + RLENGTH)
    }
    # variables set to a constant small number, for comparisons
    delete lit
    v = rest
    while (match(v, /[A-Za-z_][A-Za-z0-9_]* = (lean_box|lean_unsigned_to_nat)\([0-9]+u?\);/)) {
        a = substr(v, RSTART, RLENGTH)
        sub(/ =.*/, "", a)
        lit[a] = 1
        v = substr(v, RSTART + RLENGTH)
    }
    v = rest
    while (match(v, /[A-Za-z_][A-Za-z0-9_]*\(/)) {
        name = substr(v, RSTART, RLENGTH - 1)
        args = substr(v, RSTART + RLENGTH)
        v = args
        if (name == "if" || name == "return" || name == "sizeof" || name == "switch") continue
        if (name in allow || name ~ prefixes) continue
        if (name in natcmp) {
            a = args
            sub(/\).*/, "", a)
            if (small(a)) continue
            return 0
        }
        if (name ~ /^lean_dec(_ref)?$/) {
            a = args
            sub(/\).*/, "", a)
            if (a in boxed) continue
            return 0
        }
        if (name in tiny) continue
        return 0
    }
    return 1
}

{
    line[++nl] = $0
    if (cur == "" && $0 ~ /^(LEAN_EXPORT |static )+[A-Za-z_][A-Za-z0-9_]*\** *(l_|lp_)[A-Za-z0-9_]*\(.*\) ?\{$/) {
        n = $0
        sub(/\(.*/, "", n)
        sub(/.*[ *]/, "", n)
        cur = n; start[n] = nl; B[n] = ""; depth = 1; order[++nf] = n
        next
    }
    if (cur != "") {
        t = $0
        depth += gsub(/\{/, "{", t) - gsub(/\}/, "}", t)
        if (depth <= 0) cur = ""
        else B[cur] = B[cur] "\n" $0
    }
}

END {
    # a function is tiny once everything it calls is: repeat until nothing changes
    do {
        changed = 0
        for (i = 1; i <= nf; i++) {
            k = order[i]
            if (!(k in tiny) && scan(k)) { tiny[k] = 1; changed = 1 }
        }
    } while (changed)
    for (k in tiny) mark[start[k]] = 1
    for (i = 1; i <= nl; i++)
        print (i in mark ? "__attribute__((no_instrument_function)) " : "") line[i]
    m = 0
    for (k in tiny) m++
    if (m > 0) {
        s = "static void *const lpf_untimed_fns[] = {"
        for (k in tiny) s = s "(void *)" k ", "
        print s "};"
        print "void leanprof_untimed_register(void *const *fns, size_t n);"
        print "__attribute__((constructor, no_instrument_function)) static void lpf_untimed_init(void) {"
        print "    leanprof_untimed_register(lpf_untimed_fns, " m ");"
        print "}"
    }
}
