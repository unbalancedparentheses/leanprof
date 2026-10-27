/* The memory of the running process, for `leanprof-elab-driver --memory`
   (per-command memory of a serial elaboration). Linked into the driver,
   compiled by the system's `cc` (Lean's `leanc` has no system headers).

   leanprof_mem_stat(which):
     0  resident set size now, in bytes
     1  peak resident set size so far
     2  private memory now: on macOS the physical footprint (what the system
        charges to the process: dirty and compressed pages, not clean pages of
        mapped files such as .olean files); on Linux RssAnon (anonymous
        resident pages)
     3  peak private memory so far: macOS only (the footprint's peak);
        on Linux 0, unknown
   Every value is 0 when it cannot be read. */
#include <lean/lean.h>
#include <stdint.h>
#ifdef __APPLE__
#include <mach/mach.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

#ifdef __APPLE__
static uint64_t lpf_mem_stat(uint32_t which) {
  task_vm_info_data_t vm;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) != KERN_SUCCESS) return 0;
  switch (which) {
  case 0: return vm.resident_size;
  case 1: return vm.resident_size_peak;
  case 2: return vm.phys_footprint;
  case 3: return count >= TASK_VM_INFO_REV1_COUNT ? (uint64_t)vm.ledger_phys_footprint_peak : 0;
  default: return 0;
  }
}
#else
/* a field of /proc/self/status in kB, as bytes */
static uint64_t lpf_status_field(const char *name) {
  static char text[8192];
  int fd = open("/proc/self/status", O_RDONLY);
  if (fd < 0) return 0;
  long len = 0, k;
  while (len < (long)sizeof text - 1 && (k = read(fd, text + len, sizeof text - 1 - (unsigned long)len)) > 0) len += k;
  close(fd);
  text[len] = 0;
  /* the line `NAME:   1234 kB` */
  for (char *line = text; *line;) {
    const char *a = name;
    char *b = line;
    while (*a && *a == *b) a++, b++;
    if (!*a && *b == ':') {
      uint64_t kb = 0;
      for (b++; *b == ' ' || *b == '\t'; b++) {}
      for (; *b >= '0' && *b <= '9'; b++) kb = kb * 10 + (uint64_t)(*b - '0');
      return kb * 1024;
    }
    while (*line && *line != '\n') line++;
    if (*line) line++;
  }
  return 0;
}

static uint64_t lpf_mem_stat(uint32_t which) {
  switch (which) {
  case 0: return lpf_status_field("VmRSS");
  case 1: return lpf_status_field("VmHWM");
  case 2: return lpf_status_field("RssAnon");
  default: return 0;
  }
}
#endif

LEAN_EXPORT lean_obj_res leanprof_mem_stat(uint32_t which, lean_obj_arg w) {
  (void)w;
  /* `IO Nat`: an IO action (not `BaseIO`, which newer Lean returns without the
     result object) returns a Nat in the same way on every supported Lean */
  return lean_io_result_mk_ok(lean_uint64_to_nat(lpf_mem_stat(which)));
}
