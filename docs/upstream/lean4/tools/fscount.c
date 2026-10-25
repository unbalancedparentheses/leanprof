// DYLD_INSERT_LIBRARIES interposer: counts file-system calls made through libc,
// prints totals at exit to $SYSC_OUT (appends one line per process).
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdatomic.h>
#include <spawn.h>
#define DYLD_INTERPOSE(_r, _o) __attribute__((used)) static struct { const void *r; const void *o; } _interpose_##_o __attribute__((section("__DATA,__interpose"))) = {(const void *)(unsigned long)&_r, (const void *)(unsigned long)&_o};
static _Atomic long c_fork, c_spawn, c_open, c_stat, c_lstat, c_fstat, c_read, c_close, c_access;
static int my_open(const char *p, int f, ...) { va_list a; va_start(a, f); int m = (f & O_CREAT) ? va_arg(a, int) : 0; va_end(a); c_open++; return open(p, f, m); }
static int my_stat(const char *p, struct stat *s) { c_stat++; return stat(p, s); }
static int my_lstat(const char *p, struct stat *s) { c_lstat++; return lstat(p, s); }
static int my_fstat(int fd, struct stat *s) { c_fstat++; return fstat(fd, s); }
static ssize_t my_read(int fd, void *b, size_t n) { c_read++; return read(fd, b, n); }
static int my_close(int fd) { c_close++; return close(fd); }
static int my_access(const char *p, int m) { c_access++; return access(p, m); }
static pid_t my_fork(void) { c_fork++; return fork(); }
static int my_spawnp(pid_t *p, const char *f, const posix_spawn_file_actions_t *a, const posix_spawnattr_t *at, char *const argv[], char *const envp[]) { c_spawn++; return posix_spawnp(p, f, a, at, argv, envp); }
DYLD_INTERPOSE(my_fork, fork)
DYLD_INTERPOSE(my_spawnp, posix_spawnp)
DYLD_INTERPOSE(my_open, open)
DYLD_INTERPOSE(my_stat, stat)
DYLD_INTERPOSE(my_lstat, lstat)
DYLD_INTERPOSE(my_fstat, fstat)
DYLD_INTERPOSE(my_read, read)
DYLD_INTERPOSE(my_close, close)
DYLD_INTERPOSE(my_access, access)
static void report(void);
static void my__exit(int c) { report(); _exit(c); }
DYLD_INTERPOSE(my__exit, _exit)
__attribute__((destructor)) static void report(void) {
  static int done; if (done) return; done = 1;
  const char *o = getenv("SYSC_OUT");
  if (!o) return;
  FILE *f = fopen(o, "a");
  if (!f) return;
  fprintf(f, "fork %ld posix_spawnp %ld open %ld stat %ld lstat %ld fstat %ld read %ld close %ld access %ld total %ld\n",
          c_fork, c_spawn, c_open, c_stat, c_lstat, c_fstat, c_read, c_close, c_access,
          c_open + c_stat + c_lstat + c_fstat + c_read + c_close + c_access);
  fclose(f);
}
