/* Fixture payload only. The production deadline init owns this process and its
 * descendants; this executable cannot see the provider's host namespace. */
#define _GNU_SOURCE
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/ptrace.h>
#include <sys/socket.h>
#include <sys/timerfd.h>
#include <poll.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#ifndef HOST_SECRET_PATH
#define HOST_SECRET_PATH "/var/lib/shikigami-prototype-unmounted/host-secret"
#endif
static void stamp(const char *phase) {
  struct timespec real, monotonic, boot;
  if (clock_gettime(CLOCK_REALTIME, &real) || clock_gettime(CLOCK_MONOTONIC, &monotonic) || clock_gettime(CLOCK_BOOTTIME, &boot)) return;
  int fd = open("/workspace/src/clock-evidence", O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
  if (fd < 0) return;
  char line[256];
  int size = snprintf(line, sizeof(line), "%s %lld.%09ld %lld.%09ld %lld.%09ld\n", phase, (long long)real.tv_sec, real.tv_nsec, (long long)monotonic.tv_sec, monotonic.tv_nsec, (long long)boot.tv_sec, boot.tv_nsec);
  if (size > 0 && (size_t)size < sizeof(line)) (void)write(fd, line, (size_t)size);
  close(fd);
}
/* Apple's VM agent steps realtime every thirty seconds. Observe that boundary
 * before a short fixture command; the production deadline guard stays enabled.
 * This helper neither changes clocks nor grants command authority. */
static int await_clock_step(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_REALTIME, &now)) return 1;
  int fd = timerfd_create(CLOCK_REALTIME, TFD_CLOEXEC | TFD_NONBLOCK);
  if (fd < 0) return 1;
  struct itimerspec deadline = {.it_value = {.tv_sec = now.tv_sec + 3600, .tv_nsec = now.tv_nsec}};
  if (timerfd_settime(fd, TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET, &deadline, NULL)) { close(fd); return 1; }
  struct pollfd watched = {.fd = fd, .events = POLLIN};
  int ready;
  do { ready = poll(&watched, 1, 35000); } while (ready < 0 && errno == EINTR);
  uint64_t ticks;
  int stepped = ready > 0 && read(fd, &ticks, sizeof(ticks)) < 0 && errno == ECANCELED;
  close(fd);
  if (stepped) puts("Observed disposable guest clock step before command admission");
  return stepped ? 0 : 1;
}
#ifndef SIBLING_SECRET_PATH
#define SIBLING_SECRET_PATH "/var/lib/shikigami-prototype-unmounted/sibling/secret"
#endif
static int write_marker(const char *path, const char *value, int append) {
  int fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC | (append ? O_APPEND : O_TRUNC), 0600);
  if (fd < 0) return -1;
  size_t size = strlen(value);
  int result = write(fd, value, size) != (ssize_t)size;
  if (fsync(fd) || close(fd)) result = 1;
  return result ? -1 : 0;
}
static int inaccessible(const char *path) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return 1;
  close(fd); return 0;
}
static int denials(void) {
  if (!getuid() || getpid() == 1 || getppid() != 1 || prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) != 1) return 20;
  if (!inaccessible(HOST_SECRET_PATH) || !inaccessible(SIBLING_SECRET_PATH) || !inaccessible("/workspace/.git/config") || !inaccessible("/provider/profile-provision.json")) return 21;
  int fd = open("/etc/probe-immutable", O_WRONLY | O_CLOEXEC);
  if (fd >= 0) { close(fd); return 22; }
  fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd >= 0) { close(fd); return 23; }
  if (mount("none", "/tmp", "tmpfs", 0, NULL) == 0) return 24;
  fd = open("/proc/1/mem", O_RDWR | O_CLOEXEC);
  if (fd >= 0) { close(fd); return 25; }
  if (ptrace(PTRACE_ATTACH, 1, NULL, NULL) != -1) return 26;
  for (int i = 3; i < 64; ++i) if (fcntl(i, F_GETFD) != -1 || errno != EBADF) return 27;
  FILE *status = fopen("/proc/self/status", "r");
  if (!status) return 28;
  char line[512]; int empty = 0;
  while (fgets(line, sizeof(line), status)) {
    if (!strncmp(line, "CapEff:", 7)) {
      unsigned long long capabilities = 1;
      if (sscanf(line + 7, "%llx", &capabilities) == 1 && !capabilities) empty = 1;
    }
  }
  fclose(status);
  if (!empty || write_marker("/scratch/write-proof", "1", 0) || write_marker("/workspace/src/denials-ok", "1", 0)) return 29;
  return 0;
}
int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--await-clock-step")) return await_clock_step();
  if (argc != 2 || strcmp(argv[1], "validate")) return 64;
  FILE *input = fopen("/workspace/src/mode", "r");
  char mode[32] = {0};
  if (!input || !fgets(mode, sizeof(mode), input)) return 65;
  fclose(input);
  mode[strcspn(mode, "\n")] = 0;
  /* Upgrade validation must leave the captured tree unchanged. Process recovery
   * modes below deliberately retain control markers for the separate matrix. */
  if (!strcmp(mode, "complete")) {
    input = fopen("/workspace/src/dependency.txt", "r");
    char dependency[32] = {0};
    if (!input || !fgets(dependency, sizeof(dependency), input)) return 73;
    int extra = fgetc(input);
    fclose(input);
    if (strcmp(dependency, "new dependency\n") || extra != EOF) return 74;
    puts("validated upgrade");
    return 0;
  }
  stamp("begin");
  if (write_marker("/workspace/src/launch-count", "1", 1)) return 66;
  stamp("count-saved");
  if (write_marker("/workspace/src/command-ready", "1", 0)) return 66;
  stamp("ready-saved");
  if (!strcmp(mode, "denials")) return denials();
  if (!strcmp(mode, "orphan")) {
    pid_t child = fork();
    if (child < 0) return 67;
    if (child) return 0;
    if (setsid() < 0) return 68;
    signal(SIGTERM, SIG_IGN);
    for (;;) {
      if (write_marker("/workspace/src/orphan", "1", 1)) return 69;
      usleep(50000);
    }
  }
  stamp("wait-begin");
  if (!strcmp(mode, "slow")) {
    while (access("/workspace/src/release-command", F_OK)) {
      if (errno != ENOENT) return 72;
      usleep(10000);
    }
  }
  else if (strcmp(mode, "complete")) return 70;
  stamp("output-begin");
  char output[8192]; memset(output, 'x', sizeof(output));
  for (int i = 0; i < 16; ++i) if (write(1, output, sizeof(output)) < 0 || write(2, output, sizeof(output)) < 0) return 71;
  stamp("done");
  return 0;
}
