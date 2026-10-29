/* The manager retains intake across restart. Adopt only the configured Unix
 * stream listener, once, before application threads mutate environment. */
#ifdef __linux__
#include <systemd/sd-daemon.h>
#include <sys/socket.h>
#include <fcntl.h>
int shikigami_workspace_systemd_socket(const char *path) {
  if (!path || path[0] != '/') return -64;
  if (sd_listen_fds(1) != 1) return -78;
  int fd = SD_LISTEN_FDS_START;
  if (sd_is_socket_unix(fd, SOCK_STREAM, 1, path, 0) != 1) return -64;
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK)) return -70;
  return fd;
}
#else
int shikigami_workspace_systemd_socket(const char *path) { (void)path; return -78; }
#endif
