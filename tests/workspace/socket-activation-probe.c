/* Fixture consumer of the production listener adoption boundary. */
#define _GNU_SOURCE
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
int shikigami_workspace_systemd_socket(const char *path);
int main(int argc, char **argv) {
  if (argc != 3) return 64;
  int listener = shikigami_workspace_systemd_socket(argv[1]);
  if (listener < 0) return -listener;
  if (!(fcntl(listener, F_GETFD) & FD_CLOEXEC) ||
      !(fcntl(listener, F_GETFL) & O_NONBLOCK)) return 70;
  for (;;) {
    struct pollfd ready = { .fd=listener, .events=POLLIN };
    if (poll(&ready, 1, 1000) < 0) { if (errno == EINTR) continue; return 70; }
    int peer = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
    if (peer < 0) { if (errno == EAGAIN || errno == EINTR) continue; return 70; }
    struct ucred credentials;
    socklen_t size = sizeof(credentials);
    if (getsockopt(peer, SOL_SOCKET, SO_PEERCRED, &credentials, &size) ||
        size != sizeof(credentials) || credentials.uid != getuid()) return 77;
    struct timeval deadline = {.tv_sec=2};
    if (setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &deadline, sizeof(deadline))) return 70;
    char request;
    if (read(peer, &request, 1) == 1 && request == 'x') {
      int output = open(argv[2], O_WRONLY|O_APPEND|O_CREAT|O_NOFOLLOW|O_CLOEXEC, 0600);
      if (output < 0 || write(output, "1", 1) != 1 || fsync(output) || close(output)) return 70;
      if (write(peer, "ok", 2) != 2) return 70;
    }
    close(peer);
  }
}
