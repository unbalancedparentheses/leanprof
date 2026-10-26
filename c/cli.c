/* Signal handling for the `leanprof` command itself (not linked into the
 * programs it profiles).
 *
 * `leanprof run` replaces a project's compiled objects with instrumented
 * ones while the program runs and puts the normal ones back afterwards.
 * Killed by Ctrl-C, `kill` or a closed terminal before that, it left the
 * instrumented objects in .lake/build, and a later plain `lake build` kept
 * them. While a child runs, INT, TERM and HUP are caught instead: TERM and
 * HUP (and an INT sent by another process; the terminal's Ctrl-C already
 * reaches the child, which is in the same process group) are passed on to
 * the child, the command waits for it, puts the normal build back, and exits
 * as if killed by the signal (128 + its number). `measure` and
 * `measure-pair` register each program they run the same way. A second
 * signal while nothing runs ends the command at once. */
#include <lean/lean.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t lpc_child, lpc_caught;

static void lpc_handler(int sig, siginfo_t *info, void *ctx) {
    (void)ctx;
    if (lpc_child == 0 && lpc_caught != 0) {
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    lpc_caught = sig;
    /* a terminal's INT has no sending process and reached the child already */
    if (lpc_child > 0 && (sig != SIGINT || (info != NULL && info->si_pid != 0))) kill((pid_t)lpc_child, sig);
}

/* Catch INT, TERM and HUP from now on, passing them to `pid` (0: no child). */
LEAN_EXPORT lean_obj_res leanprof_cli_guard(uint32_t pid, lean_obj_arg w) {
    (void)w;
    lpc_child = (sig_atomic_t)pid;
    static int installed;
    if (!installed) {
        installed = 1;
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_sigaction = lpc_handler;
        sa.sa_flags = SA_SIGINFO | SA_RESTART;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGINT, &sa, NULL);
        sigaction(SIGTERM, &sa, NULL);
        sigaction(SIGHUP, &sa, NULL);
    }
    return lean_io_result_mk_ok(lean_box(0));
}

/* The signal caught so far (0 if none). */
LEAN_EXPORT lean_obj_res leanprof_cli_caught(lean_obj_arg w) {
    (void)w;
    return lean_io_result_mk_ok(lean_box_uint32((uint32_t)lpc_caught));
}

/* The 1-minute load average without spawning sysctl (measure-pair reads it
 * after every pair); negative when unavailable. */
LEAN_EXPORT lean_obj_res leanprof_cli_loadavg(lean_obj_arg w) {
    (void)w;
    double l[1];
    return lean_io_result_mk_ok(lean_box_float(getloadavg(l, 1) == 1 ? l[0] : -1.0));
}
