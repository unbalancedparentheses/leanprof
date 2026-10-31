# Compile out chosen `profile!` scopes on pure terms (`leanprof run --retime`).
#
#   awk -v list=UNTIMED -f leanprof-untimed.awk FILE.c FILE.c > OUT.c
#
# UNTIMED has one scope per line, its name and position separated by a tab
# (`tinyB<TAB>Main.lean:35`, as the report's `name` and `pos`). The C file is
# read twice. The first pass finds the string constants that are those
# scopes' labels (`NAME\037POS`, or `NAME\x1f./POS` before Lean 4.31): a
# static `lean_string_object` (`X_value`), or a variable set from
# `lean_mk_string_unchecked` in the module initializer before Lean 4.31.
# The second pass copies the file and, after the last declaration of a
# `leanprof_*_pure` function, defines macros over them:
#
#   leanprof_enter_pure(s, k)   the label's constant? drop `s`, token 2 : call
#   leanprof_exit_pure*(t, v)   a constant token 2? `v` : call
#
# The C compiler folds both for a label it knows: the scope's two calls are
# gone, as if the program had no `profile!` there. Where it cannot fold
# (a label initialized at run time), the comparisons run, and the runtime's
# exit returns at once for token 2. A file with none of the labels is
# printed unchanged; a label written differently (escapes) stays timed.

function cstr(s,    out, i, c) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" || c == "\"") out = out "\\" c
        else out = out c
    }
    return out
}

BEGIN {
    n = 0
    while ((getline line < list) > 0) {
        t = index(line, "\t")
        if (t == 0) continue
        name = cstr(substr(line, 1, t - 1))
        pos = cstr(substr(line, t + 1))
        lits[++n] = "\"" name "\\037" pos "\""
        lits[++n] = "\"" name "\\x1f./" pos "\""
    }
    close(list)
    nkeys = 0
    lastproto = 0
}

# first pass
FNR == NR {
    if ($0 ~ /^(LEAN_EXPORT )?[A-Za-z_0-9* ]+ leanprof_(enter|exit)_pure[a-z0-9_]*\(.*\);[ \t]*$/)
        lastproto = FNR
    if (match($0, /^static lean_object\* _init_[A-Za-z_0-9]+\(/)) {
        init = substr($0, RSTART + 26, RLENGTH - 27)
    } else if ($0 ~ /^(LEAN_EXPORT |static |lean_object\* |uint)/ && $0 ~ /\(/ && $0 !~ /=/) {
        init = ""
    }
    for (i = 1; i <= n; i++) {
        if (index($0, lits[i]) == 0) continue
        if (match($0, /lean_string_object [A-Za-z_0-9]+_value *=/)) {
            obj = substr($0, RSTART + 19, RLENGTH - 19)
            sub(/ *=$/, "", obj)
            keys[++nkeys] = "(const void *)&" obj
        } else if (match($0, /[A-Za-z_0-9]+ *= *lean_mk_string_unchecked\(/)) {
            # inside `_init_X()` the constant is X (set from it at module
            # initialization); else the variable assigned
            obj = substr($0, RSTART, RLENGTH)
            sub(/ *=.*$/, "", obj)
            if (init != "") obj = init
            keys[++nkeys] = "(const void *)" obj
        }
        break
    }
    next
}

# second pass
{
    print
    if (FNR == lastproto && nkeys > 0) {
        printf "/* leanprof run --retime: %d scope(s) compiled out (scripts/leanprof-untimed.awk) */\n", nkeys
        printf "#define LEANPROF_COMPILED_OUT(k) (0"
        for (i = 1; i <= nkeys; i++) printf " || (const void *)(k) == %s", keys[i]
        printf ")\n"
        print "#define leanprof_enter_pure(s, k) (LEANPROF_COMPILED_OUT(k) ? (lean_dec(s), (uint64_t)2) : (leanprof_enter_pure)(s, k))"
        split("leanprof_exit_pure leanprof_exit_pure_u8 leanprof_exit_pure_u16 leanprof_exit_pure_u32 leanprof_exit_pure_u64 leanprof_exit_pure_usize leanprof_exit_pure_f64 leanprof_exit_pure_f32", fs, " ")
        for (i = 1; i <= 8; i++)
            printf "#define %s(t, v) (__builtin_constant_p(t) && (t) == 2 ? (v) : (%s)(t, v))\n", fs[i], fs[i]
    }
}
