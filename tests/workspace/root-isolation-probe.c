/* Fixed Linux qualification payload, never an agent command or supervisor. */
#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/mount.h>
#include <sys/wait.h>
#include <sys/prctl.h>
#include <fcntl.h>
#include <sched.h>
#include <unistd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
static void require(int yes, const char *name) {
  if (!yes) { fprintf(stderr, "FAIL %s (errno=%d)\n", name, errno); exit(1); }
  printf("PASS %s\n", name); fflush(stdout);
}
static int write_file(const char *path) {
  int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
  if (fd < 0) return -1;
  int result = write(fd, "x", 1) == 1 ? 0 : -1;
  close(fd); return result;
}
int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "descendant")) {
    int ready[2];
    if (pipe(ready)) return 1;
    pid_t child = fork();
    if (child < 0) return 1;
    if (child) {
      close(ready[0]); close(ready[1]);
      int status;
      if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status)) return 2;
      if (write_file("/workspace/command-exited")) return 3;
      /* The namespace's PID 1 stays alive while an intermediate command exits.
       * Linux kills the whole namespace if PID 1 itself exits. */
      for (;;) pause();
    }
    pid_t writer = fork();
    if (writer < 0) return 4;
    if (writer) {
      close(ready[1]);
      char acknowledged;
      int result = read(ready[0], &acknowledged, 1) == 1 ? 0 : 5;
      close(ready[0]); return result;
    }
    close(ready[0]);
    if (setsid() < 0) return 2;
    signal(SIGTERM, SIG_IGN);
    if (write_file("/workspace/descendant") || write(ready[1], "x", 1) != 1) return 6;
    close(ready[1]);
    while (!write_file("/workspace/descendant")) usleep(100000);
    return 3;
  }
  require(geteuid() == 62001, "unprivileged workspace identity");
  require(getpid() == 1, "effective private PID namespace");
  require(prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) == 1, "new privileges disabled");
  require(!write_file("/workspace/allowed") && !write_file("/scratch/allowed"), "workspace and scratch writes");
  errno = 0;
  int denied = open("/etc/immutable", O_WRONLY | O_TRUNC);
  require(denied < 0 && errno == EROFS, "immutable root despite world-writable file mode");
  require(open("/var/lib/shikigami-root-probe/host-secret", O_RDONLY) < 0 &&
          open("/var/lib/shikigami-root-probe/sibling/secret", O_RDONLY) < 0,
          "host source and sibling files absent");
  require(socket(AF_INET, SOCK_STREAM, 0) < 0, "network sockets denied");
  require(mount("none", "/scratch", "tmpfs", 0, NULL) < 0 &&
          unshare(CLONE_NEWNS) < 0, "mount and namespace escape denied");
  FILE *status = fopen("/proc/self/status", "r");
  require(status != NULL, "private proc is available");
  char line[256]; int capabilities = 0, bounding = 0;
  while (fgets(line, sizeof(line), status)) {
    unsigned long long bits;
    if (sscanf(line, "CapEff: %llx", &bits) == 1) capabilities = bits == 0;
    if (sscanf(line, "CapBnd: %llx", &bits) == 1) bounding = bits == 0;
  }
  fclose(status);
  require(capabilities && bounding, "effective and bounding capabilities empty");
  return 0;
}
