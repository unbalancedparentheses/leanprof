# Marks the functions of a Lean-generated C file that `--auto` leaves
# untimed (see scripts/leanprof-cc): a function that takes a nanosecond or
# two costs less than its probes, whose cost then is most of what is
# reported for it and for every function around it, and is a large part of
# the program's time. Such a function is straight-line code (no loop, no
# join point: no `goto`) that calls nothing but the O(1) operations of
# lean.h below and functions of the same file that are themselves tiny, and
# that frees nothing but boxed scalars (a `lean_dec` of anything else can
# free a whole structure). It gets `no_instrument_function`, and its address
# goes in a table (section lpf_untimed) that the report lists by name.
#
# usage: awk -f leanprof-tiny.awk file.c > out.c
BEGIN {
    # lean.h operations that do a bounded amount of work
    split("lean_box lean_unbox lean_box_uint32 lean_unbox_uint32 lean_box_uint64 lean_unbox_uint64 " \
          "lean_box_usize lean_unbox_usize lean_box_float lean_unbox_float lean_box_float32 lean_unbox_float32 " \
          "lean_ctor_get lean_ctor_set lean_ctor_set_tag lean_ctor_num_objs lean_obj_tag lean_ptr_tag " \
          "lean_is_scalar lean_is_exclusive lean_is_shared lean_alloc_ctor lean_ctor_release " \
          "lean_inc lean_inc_n lean_inc_ref lean_inc_ref_n lean_mark_persistent " \
          "lean_unsigned_to_nat lean_usize_to_nat lean_uint64_to_nat lean_nat_add lean_nat_sub lean_nat_succ " \
          "lean_nat_dec_eq lean_nat_dec_lt lean_nat_dec_le lean_nat_eq lean_nat_lt lean_nat_le " \
          "lean_array_size lean_array_get_size lean_array_fget lean_array_uget lean_array_get_core " \
          "lean_sarray_size lean_string_utf8_byte_size lean_string_byte_size", ok, " ")
    for (i in ok) allow[ok[i]] = 1
    prefixes = "^(lean_ctor_get_|lean_ctor_set_|lean_uint8_|lean_uint16_|lean_uint32_|lean_uint64_|lean_usize_|" \
               "lean_int8_|lean_int16_|lean_int32_|lean_int64_|lean_isize_|lean_float_|lean_float32_|lean_bool_)"
    nf = 0
}

function scan(k,    body, rest, name, a, j, args, v) {
    body = B[k]
    # labels other than the `_start:` every function has, and gotos, are loops or join points
    rest = body
    sub(/_start:/, "", rest)
    if (rest ~ /goto / || rest ~ /\n[A-Za-z_][A-Za-z0-9_]*:/) return 0
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
    v = rest
    while (match(v, /[A-Za-z_][A-Za-z0-9_]*\(/)) {
        name = substr(v, RSTART, RLENGTH - 1)
        args = substr(v, RSTART + RLENGTH)
        v = args
        if (name == "if" || name == "return" || name == "sizeof" || name == "switch" || name == "while") continue
        if (name in allow || name ~ prefixes) continue
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
        print "#ifdef __APPLE__"
        print "#define LPF_UNTIMED_SECTION \"__DATA,__lpf_untimed\""
        print "#else"
        print "#define LPF_UNTIMED_SECTION \"lpf_untimed\""
        print "#endif"
        s = "static void *const lpf_untimed_fns[] __attribute__((used, section(LPF_UNTIMED_SECTION), aligned(sizeof(void *)))) = {"
        for (k in tiny) s = s "(void *)" k ", "
        print s "};"
    }
}
