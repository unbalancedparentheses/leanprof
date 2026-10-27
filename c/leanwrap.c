/* leanprof-lean-wrap: stands in for `lean` in a Lake build and records what
   each `lean` process cost.

   `leanprof build-memory` gives Lake a copy of the Lean installation whose
   `bin/lean` is this program (LEAN_SYSROOT with LAKE_OVERRIDE_LEAN). For every
   `lean` that Lake starts, it runs the real one (LEANPROF_REAL_LEAN) with the
   same arguments and environment, waits for it, and appends one JSON line to
   LEANPROF_BUILD_LOG:

     start_us, end_us   wall clock (microseconds since the epoch)
     user_us, sys_us    CPU time of the process (and of its children, if any)
     maxrss             peak resident set size, in bytes (wait4's ru_maxrss:
                        bytes on macOS, KiB on Linux, converted here)
     footprint_peak     macOS only: the peak physical footprint, the memory
                        the system charges to the process (dirty and
                        compressed pages; not clean pages of mapped files
                        such as .olean files). -1 elsewhere.
     exit, signal       how it ended
     cwd, args          what ran (args without argv[0])
     lean_path          LEAN_PATH as the process saw it

   It is the same process tree as an unwrapped build, with one small extra
   process per `lean` (this one); the child's numbers are its own, not this
   wrapper's. LEANPROF_CHILD_NUM_THREADS, when set, is put back as
   LEAN_NUM_THREADS for the child (empty: unset), so that limiting Lake's
   parallelism does not limit each `lean`'s threads.

   Plain C and POSIX, so it is built by `cc` wherever leanprof runs. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __APPLE__
#include <libproc.h>
#endif

static pid_t child = -1;

static void forward(int sig) {
  if (child > 0) kill(child, sig);
}

static long long now_us(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (long long)tv.tv_sec * 1000000LL + tv.tv_usec;
}

/* A growing buffer for the JSON line. */
typedef struct { char *p; size_t n, cap; } buf;

static void put(buf *b, const char *s, size_t n) {
  if (b->n + n + 1 > b->cap) {
    size_t cap = (b->cap ? b->cap * 2 : 4096);
    while (cap < b->n + n + 1) cap *= 2;
    char *q = realloc(b->p, cap);
    if (!q) return;
    b->p = q;
    b->cap = cap;
  }
  memcpy(b->p + b->n, s, n);
  b->n += n;
  b->p[b->n] = 0;
}

static void puts_(buf *b, const char *s) { put(b, s, strlen(s)); }

static void putf(buf *b, const char *fmt, long long v) {
  char tmp[64];
  int n = snprintf(tmp, sizeof tmp, fmt, v);
  if (n > 0) put(b, tmp, (size_t)n);
}

static void put_str(buf *b, const char *s) {
  puts_(b, "\"");
  for (const unsigned char *c = (const unsigned char *)s; c && *c; c++) {
    if (*c == '"' || *c == '\\') {
      char e[2] = {'\\', (char)*c};
      put(b, e, 2);
    } else if (*c < 0x20) {
      char e[8];
      snprintf(e, sizeof e, "\\u%04x", *c);
      puts_(b, e);
    } else {
      put(b, (const char *)c, 1);
    }
  }
  puts_(b, "\"");
}

int main(int argc, char **argv) {
  const char *real = getenv("LEANPROF_REAL_LEAN");
  const char *log = getenv("LEANPROF_BUILD_LOG");
  if (!real || !*real) {
    fprintf(stderr, "leanprof-lean-wrap: LEANPROF_REAL_LEAN is not set\n");
    return 127;
  }
  /* what the child runs as */
  char **cargv = calloc((size_t)argc + 1, sizeof(char *));
  if (!cargv) return 127;
  cargv[0] = (char *)real;
  for (int i = 1; i < argc; i++) cargv[i] = argv[i];
  const char *threads = getenv("LEANPROF_CHILD_NUM_THREADS");
  if (threads) {
    if (*threads) setenv("LEAN_NUM_THREADS", threads, 1);
    else unsetenv("LEAN_NUM_THREADS");
  }
  if (!log || !*log) {
    execv(real, cargv);
    perror("leanprof-lean-wrap: exec");
    return 127;
  }
  long long start = now_us();
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = forward;
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGHUP, &sa, NULL);
  child = fork();
  if (child < 0) {
    perror("leanprof-lean-wrap: fork");
    return 127;
  }
  if (child == 0) {
    execv(real, cargv);
    perror("leanprof-lean-wrap: exec");
    _exit(127);
  }
  long long footprint = -1;
#ifdef __APPLE__
  /* the child's footprint can be read until it is reaped: wait without reaping */
  {
    siginfo_t si;
    int r;
    do r = waitid(P_PID, (id_t)child, &si, WEXITED | WNOWAIT);
    while (r < 0 && errno == EINTR);
    struct rusage_info_v4 ri;
    if (r == 0 && proc_pid_rusage(child, RUSAGE_INFO_V4, (rusage_info_t *)&ri) == 0)
      footprint = (long long)ri.ri_lifetime_max_phys_footprint;
  }
#endif
  int status = 0;
  struct rusage ru;
  memset(&ru, 0, sizeof ru);
  pid_t w;
  do w = wait4(child, &status, 0, &ru);
  while (w < 0 && errno == EINTR);
  long long end = now_us();
#ifdef __APPLE__
  long long maxrss = (long long)ru.ru_maxrss;
#else
  long long maxrss = (long long)ru.ru_maxrss * 1024LL;
#endif
  buf b = {0};
  putf(&b, "{\"pid\":%lld", (long long)child);
  putf(&b, ",\"start_us\":%lld", start);
  putf(&b, ",\"end_us\":%lld", end);
  putf(&b, ",\"user_us\":%lld", (long long)ru.ru_utime.tv_sec * 1000000LL + ru.ru_utime.tv_usec);
  putf(&b, ",\"sys_us\":%lld", (long long)ru.ru_stime.tv_sec * 1000000LL + ru.ru_stime.tv_usec);
  putf(&b, ",\"maxrss\":%lld", maxrss);
  putf(&b, ",\"footprint_peak\":%lld", footprint);
  putf(&b, ",\"exit\":%lld", (long long)(WIFEXITED(status) ? WEXITSTATUS(status) : -1));
  putf(&b, ",\"signal\":%lld", (long long)(WIFSIGNALED(status) ? WTERMSIG(status) : 0));
  char cwd[4096];
  puts_(&b, ",\"cwd\":");
  put_str(&b, getcwd(cwd, sizeof cwd) ? cwd : "");
  puts_(&b, ",\"lean_path\":");
  put_str(&b, getenv("LEAN_PATH") ? getenv("LEAN_PATH") : "");
  puts_(&b, ",\"args\":[");
  for (int i = 1; i < argc; i++) {
    if (i > 1) puts_(&b, ",");
    put_str(&b, argv[i]);
  }
  puts_(&b, "]}\n");
  /* one write with O_APPEND: lines of concurrent processes do not interleave */
  int fd = open(log, O_WRONLY | O_APPEND | O_CREAT, 0644);
  if (fd >= 0 && b.p) {
    ssize_t off = 0;
    while (off < (ssize_t)b.n) {
      ssize_t k = write(fd, b.p + off, b.n - (size_t)off);
      if (k <= 0) break;
      off += k;
    }
    close(fd);
  }
  if (WIFSIGNALED(status)) {
    signal(WTERMSIG(status), SIG_DFL);
    kill(getpid(), WTERMSIG(status));
    return 128 + WTERMSIG(status);
  }
  return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
