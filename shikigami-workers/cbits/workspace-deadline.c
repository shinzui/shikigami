/* Immutable PID-namespace init. This launch guard is not a receipt or cgroup
 * settlement authority; the independent collector must still prove both. */
#define _GNU_SOURCE
#ifdef __linux__
#include <sys/timerfd.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <limits.h>
#include <unistd.h>
#include <time.h>
#include <string.h>
#include <errno.h>
#define SECOND INT64_C(1000000000)
static volatile sig_atomic_t interrupted;
static void stop_requested(int signal) { interrupted = signal; }
static int64_t clock_ns(clockid_t clock) {
  struct timespec value;
  if (clock_gettime(clock, &value) || value.tv_sec < 0 || value.tv_sec > INT64_MAX / SECOND) return -1;
  return (int64_t)value.tv_sec * SECOND + value.tv_nsec;
}
static int parse_deadline(const char *text, int64_t *value) {
  size_t size = strlen(text);
  if (!size || size > 19) return -1;
  int64_t result = 0;
  for (size_t i = 0; i < size; i++) {
    if (text[i] < '0' || text[i] > '9') return -1;
    int digit = text[i] - '0';
    if (result > (INT64_MAX - digit) / 10) return -1;
    result = result * 10 + digit;
  }
  *value = result;
  return result > 0 ? 0 : -1;
}
static int timer(clockid_t clock, int64_t end, int flags) {
  int fd = timerfd_create(clock, TFD_CLOEXEC | TFD_NONBLOCK);
  if (fd < 0) return -1;
  struct itimerspec value = { .it_value = {.tv_sec = end / SECOND, .tv_nsec = end % SECOND} };
  if (timerfd_settime(fd, TFD_TIMER_ABSTIME | flags, &value, NULL)) { close(fd); return -1; }
  return fd;
}
static int stop_namespace(int status) {
  /* Linux excludes this PID 1 from kill(-1). A private PID namespace is
   * required before fork; host/sibling processes cannot be signalled. */
  (void)kill(-1, SIGKILL);
  int64_t end = clock_ns(CLOCK_BOOTTIME);
  if (end < 0) return status;
  end += SECOND;
  for (;;) {
    for (int turn = 0; turn < 128; turn++) {
      pid_t waited = waitpid(-1, NULL, WNOHANG);
      if (waited < 0 && errno == ECHILD) return status;
      if (waited <= 0) break;
    }
    int64_t now = clock_ns(CLOCK_BOOTTIME);
    if (now < 0 || now >= end) return status;
    (void)poll(NULL, 0, 10);
  }
}
int main(int argc, char **argv) {
  int64_t deadline;
  if (argc < 5 || argc > 90 || strcmp(argv[1], "1") || strcmp(argv[3], "--") || argv[4][0] != '/' || parse_deadline(argv[2], &deadline)) return 64;
  if (getpid() != 1 || getuid() == 0 || getuid() != geteuid() || prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) != 1) return 78;
  /* Same-UID repository code must not write its trusted parent's proc memory.
   * The service also denies ptrace/process-vm syscalls. */
  if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0)) return 78;
  struct sigaction handler = {.sa_handler=stop_requested};
  sigemptyset(&handler.sa_mask);
  if (sigaction(SIGTERM, &handler, NULL) || sigaction(SIGINT, &handler, NULL) || sigaction(SIGHUP, &handler, NULL)) return 78;
  sigset_t empty;
  sigemptyset(&empty);
  if (sigprocmask(SIG_SETMASK, &empty, NULL)) return 78;
  /* Sample the nonsettable suspend-aware clock first, so sampling never
   * extends the duration. Realtime clock discontinuity expires the guard. */
  int64_t boot = clock_ns(CLOCK_BOOTTIME), now = clock_ns(CLOCK_REALTIME);
  if (boot < 0 || now < 0) return 78;
  if (deadline <= now || deadline - now > 3600 * SECOND || boot > INT64_MAX - (deadline - now)) return 125;
  int real_timer = timer(CLOCK_REALTIME, deadline, TFD_TIMER_CANCEL_ON_SET);
  int boot_timer = timer(CLOCK_BOOTTIME, boot + deadline - now, 0);
  if (real_timer < 0 || boot_timer < 0) return 78;
  struct pollfd timers[2] = {{.fd=real_timer,.events=POLLIN}, {.fd=boot_timer,.events=POLLIN}};
  pid_t child = fork();
  if (child < 0) return 70;
  if (!child) {
    close(real_timer); close(boot_timer);
    handler.sa_handler = SIG_DFL;
    if (sigaction(SIGTERM, &handler, NULL) || sigaction(SIGINT, &handler, NULL) || sigaction(SIGHUP, &handler, NULL)) _exit(126);
    now = clock_ns(CLOCK_REALTIME);
    if (now < 0 || now >= deadline) _exit(125);
    execv(argv[4], &argv[4]);
    _exit(126);
  }
  int main_seen = 0, main_status = 70;
  for (;;) {
    if (interrupted) return stop_namespace(128 + interrupted);
    int ready = poll(timers, 2, 10);
    if (ready < 0) { if (errno == EINTR) continue; return stop_namespace(70); }
    if (timers[0].revents || timers[1].revents) return stop_namespace(124);
    for (int turn = 0; turn < 128; turn++) {
      int status;
      pid_t waited = waitpid(-1, &status, WNOHANG);
      if (waited == child) {
        main_seen = 1;
        main_status = WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 70);
      } else if (waited < 0) {
        if (errno == EINTR) continue;
        if (errno == ECHILD) return main_seen ? main_status : 70;
        return stop_namespace(70);
      } else if (!waited) break;
    }
  }
}
#else
int main(void) { return 78; }
#endif
