/* Independent bounded capture. Never executes repository commands or grants
 * authority. The controller creates a private operation directory and launches
 * this collector as a separate system service before the validation service. */
#ifdef __linux__
#define _GNU_SOURCE
#endif
#include "workspace-systemd-profile.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
const char *shikigami_workspace_systemd_profile(void) {
  return SHIKIGAMI_WORKSPACE_SYSTEMD_PROFILE;
}
#ifdef __linux__
#include <systemd/sd-bus.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <time.h>

#define DEST "org.freedesktop.systemd1"
#define MANAGER "/org/freedesktop/systemd1"
#define UNIT "org.freedesktop.systemd1.Unit"
#define SERVICE "org.freedesktop.systemd1.Service"
struct observation {
  char invocation[33], description[256], state[32], substate[32];
  char result[64], group[256];
  uint32_t pid; int32_t code, status;
};
static int hex_id(const char *s, size_t n) {
  if (strlen(s) != n) return 0;
  int nonzero = 0;
  for (size_t i = 0; i < n; ++i) {
    if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
    nonzero |= s[i] != '0';
  }
  return nonzero;
}
static int valid_unit(const char *s) {
  const char *prefix = "shikigami-workspace-";
  if (strlen(s) != strlen(prefix) + 64 + 8 || strncmp(s, prefix, strlen(prefix)) ||
      strcmp(s + strlen(prefix) + 64, ".service")) return 0;
  char id[65]; memcpy(id, s + strlen(prefix), 64); id[64] = 0;
  return hex_id(id, 64);
}
static int write_all(int fd, const void *data, size_t n) {
  const unsigned char *p = data;
  while (n) {
    ssize_t written = write(fd, p, n);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) return -1;
    p += written; n -= (size_t)written;
  }
  return 0;
}
static int atomic_fact(int dir, const char *name, const char *body) {
  char temporary[64];
  if (snprintf(temporary, sizeof(temporary), "%s.pending", name) >= (int)sizeof(temporary)) return -1;
  int fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0) return -1;
  int result = write_all(fd, body, strlen(body)) || fsync(fd);
  if (close(fd)) result = -1;
  if (!result) result = renameat(dir, temporary, dir, name);
  if (!result) result = fsync(dir);
  return result ? -1 : 0;
}
static int read_boot(char out[37]) {
  int fd = open("/proc/sys/kernel/random/boot_id", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  char bytes[38]; ssize_t n = read(fd, bytes, sizeof(bytes)); close(fd);
  if (n != 37 || bytes[36] != '\n') return -1;
  for (int i = 0; i < 36; ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) { if (bytes[i] != '-') return -1; }
    else if (!((bytes[i] >= '0' && bytes[i] <= '9') || (bytes[i] >= 'a' && bytes[i] <= 'f'))) return -1;
  }
  memcpy(out, bytes, 36); out[36] = 0; return 0;
}
static int get_string(sd_bus *bus, const char *path, const char *interface,
                      const char *name, char *out, size_t size) {
  char *value = NULL;
  int result = sd_bus_get_property_string(bus, DEST, path, interface, name, NULL, &value);
  if (result >= 0 && value && strlen(value) < size) strcpy(out, value); else result = -1;
  free(value); return result < 0 ? -1 : 0;
}
static int get_observation(sd_bus *bus, const char *path, struct observation *out) {
  char loaded[32]; sd_bus_message *message = NULL;
  const void *id = NULL; size_t size = 0;
  int result = get_string(bus, path, UNIT, "LoadState", loaded, sizeof(loaded));
  if (result || strcmp(loaded, "loaded")) return -1;
  if (get_string(bus, path, UNIT, "Description", out->description, sizeof(out->description))) return -1;
  if (sd_bus_get_property(bus, DEST, path, UNIT, "InvocationID", NULL, &message, "ay") < 0) return -1;
  result = sd_bus_message_read_array(message, 'y', &id, &size);
  if (result > 0 && size == 0) {
    sd_bus_message_unref(message);
    return 1; /* Loaded and queued, but not yet assigned an invocation. */
  } else if (result > 0 && size == 16) {
    const unsigned char *bytes = id;
    for (int i = 0; i < 16; ++i) snprintf(out->invocation + i * 2, 3, "%02x", bytes[i]);
  } else result = -1;
  sd_bus_message_unref(message);
  if (result < 0) return -1;
  if (!hex_id(out->invocation, 32)) return 1;
  return get_string(bus, path, UNIT, "ActiveState", out->state, sizeof(out->state)) ||
    get_string(bus, path, UNIT, "SubState", out->substate, sizeof(out->substate)) ||
    get_string(bus, path, SERVICE, "Result", out->result, sizeof(out->result)) ||
    get_string(bus, path, SERVICE, "ControlGroup", out->group, sizeof(out->group)) ||
    sd_bus_get_property_trivial(bus, DEST, path, SERVICE, "MainPID", NULL, 'u', &out->pid) < 0 ||
    sd_bus_get_property_trivial(bus, DEST, path, SERVICE, "ExecMainCode", NULL, 'i', &out->code) < 0 ||
    sd_bus_get_property_trivial(bus, DEST, path, SERVICE, "ExecMainStatus", NULL, 'i', &out->status) < 0 ? -1 : 0;
}
static int empty_group(const char *unit, const struct observation *state) {
  char expected[256], path[320];
  if (snprintf(expected, sizeof(expected), "/system.slice/%s", unit) >= (int)sizeof(expected)) return -1;
  if (*state->group && strcmp(state->group, expected)) return -1;
  snprintf(path, sizeof(path), "/sys/fs/cgroup%s/cgroup.events", expected);
  FILE *file = fopen(path, "r");
  /* Kernel removal requires an empty cgroup. This inference is permitted only
   * for a retained, matching terminal unit in the same boot, never a lost unit. */
  if (!file) return errno == ENOENT ? (!*state->group ? 1 : 0) : -1;
  char line[128]; int populated = -1;
  while (fgets(line, sizeof(line), file)) { int value; if (sscanf(line, "populated %d", &value) == 1) populated = value; }
  fclose(file); return populated == 0 ? 1 : populated == 1 ? 0 : -1;
}
static int drain(int input, int output, int *remaining, int *captured, int *truncated) {
  unsigned char bytes[8192];
  /* Bound each turn so a continuous writer cannot starve settlement checks. */
  for (int i = 0; i < 32; ++i) {
    ssize_t n = read(input, bytes, sizeof(bytes));
    if (n < 0 && errno == EINTR) { --i; continue; }
    if (!n || (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) return 0;
    if (n < 0) return -1;
    int keep = n > *remaining ? *remaining : (int)n;
    if (keep && write_all(output, bytes, keep)) return -1;
    *remaining -= keep; *captured += keep; if (keep != n) *truncated = 1;
  }
  return 1;
}
int shikigami_workspace_collect(const char *directory, const char *unit,
                               const char *fingerprint, int limit, int seconds) {
  if (!valid_unit(unit) || strncmp(fingerprint, "sha256:", 7) || !hex_id(fingerprint + 7, 64) ||
      limit < 1 || limit > 1048576 || seconds < 1 || seconds > 3660) return 64;
  int dir = -1, inputs[2] = {-1, -1}, outputs[2] = {-1, -1}, lock = -1, result = 70;
  sd_bus *bus = NULL; sd_bus_message *reply = NULL; char *object = NULL;
  int private = 0, referenced = 0, stage = 1, remaining = limit, captured[2] = {0,0}, truncated[2] = {0,0};
  char boot[37], current_boot[37], pinned[33] = "", description[256];
  struct stat state;
  dir = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (dir < 0 || fstat(dir, &state) || state.st_uid != geteuid() || (state.st_mode & 077)) goto done;
  private = 1;
  lock = openat(dir, "capture.lock", O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (lock < 0 || fstat(lock, &state) || !S_ISREG(state.st_mode) || state.st_nlink != 1 || flock(lock, LOCK_EX | LOCK_NB)) goto done;
  if (fstatat(dir, "ready", &state, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT) goto done;
  stage = 2;
  if (read_boot(boot) || sd_bus_open_system(&bus) < 0 || sd_bus_set_method_call_timeout(bus, 2000000) < 0) goto done;
  const char *names[2] = {"stdout", "stderr"};
  stage = 3;
  for (int i = 0; i < 2; ++i) {
    char fifo[16]; snprintf(fifo, sizeof(fifo), "%s.pipe", names[i]);
    if (mkfifoat(dir, fifo, 0600)) goto done;
    inputs[i] = openat(dir, fifo, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    outputs[i] = openat(dir, names[i], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (inputs[i] < 0 || outputs[i] < 0) goto done;
  }
  if (atomic_fact(dir, "ready", "1\n")) goto done;
  stage = 4;
  snprintf(description, sizeof(description), "shikigami-workspace/1 %s", fingerprint);
  struct timespec started, now;
  if (clock_gettime(CLOCK_MONOTONIC, &started)) goto done;
  for (;;) {
    stage = 5;
    if (drain(inputs[0], outputs[0], &remaining, &captured[0], &truncated[0]) < 0 ||
        drain(inputs[1], outputs[1], &remaining, &captured[1], &truncated[1]) < 0) goto done;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) goto done;
    if (now.tv_sec - started.tv_sec > seconds || read_boot(current_boot) || strcmp(boot, current_boot)) goto done;
    if (!object) {
      stage = 6;
      int found = sd_bus_call_method(bus, DEST, MANAGER, DEST ".Manager", "GetUnit", NULL, &reply, "s", unit);
      if (found >= 0) {
        const char *path;
        if (sd_bus_message_read(reply, "o", &path) < 0 || !(object = strdup(path))) goto done;
        sd_bus_message_unref(reply); reply = NULL;
        if (sd_bus_call_method(bus, DEST, MANAGER, DEST ".Manager", "RefUnit", NULL, NULL, "s", unit) < 0) goto done;
        referenced = 1;
      } else {
        sd_bus_message_unref(reply); reply = NULL;
        if (now.tv_sec - started.tv_sec > 10) goto done;
        usleep(50000); continue;
      }
    }
    struct observation observation = {0};
    stage = 7;
    int observed = get_observation(bus, object, &observation);
    if (observed < 0 || strcmp(description, observation.description)) goto done;
    if (observed > 0) {
      /* A dependency can leave a correctly described unit queued before its
       * first invocation exists. Keep capture open for a bounded interval;
       * losing an identity after pinning it is still evidence loss. */
      if (*pinned || now.tv_sec - started.tv_sec > 10) goto done;
      usleep(50000); continue;
    }
    if (!*pinned) {
      strcpy(pinned, observation.invocation);
      char identity[256]; snprintf(identity, sizeof(identity), "{\"bootId\":\"%s\",\"invocationId\":\"%s\"}\n", boot, pinned);
      if (atomic_fact(dir, "observed.json", identity)) goto done;
    } else if (strcmp(pinned, observation.invocation)) goto done;
    int terminal = !observation.pid && (!strcmp(observation.substate, "exited") || !strcmp(observation.substate, "dead") || !strcmp(observation.substate, "failed"));
    if (terminal) {
      stage = 8;
      int empty = empty_group(unit, &observation);
      if (empty < 0) goto done;
      if (empty) {
        stage = 9;
        int a, b;
        do {
          a = drain(inputs[0], outputs[0], &remaining, &captured[0], &truncated[0]);
          b = drain(inputs[1], outputs[1], &remaining, &captured[1], &truncated[1]);
          if (a < 0 || b < 0) goto done;
        } while (a || b);
        if (fsync(outputs[0]) || fsync(outputs[1])) goto done;
        stage = 10;
        struct observation confirmed = {0};
        if (get_observation(bus, object, &confirmed) || strcmp(pinned, confirmed.invocation) ||
            strcmp(description, confirmed.description) || read_boot(current_boot) || strcmp(boot, current_boot)) goto done;
        stage = 11;
        int confirmed_empty = empty_group(unit, &confirmed);
        if (confirmed_empty < 0) goto done;
        /* Properties are read separately over D-Bus. A shutdown transition can
         * cross those reads; retain the identity and wait for a stable outcome. */
        if (confirmed.pid || !confirmed_empty || strcmp(observation.substate, confirmed.substate) ||
            strcmp(observation.result, confirmed.result) || observation.code != confirmed.code || observation.status != confirmed.status) {
          usleep(50000); continue;
        }
        stage = 12;
        int status = observation.code == 1 ? observation.status : (observation.code == 2 || observation.code == 3) ? 128 + observation.status : -1;
        const char *termination = !strcmp(observation.result, "timeout") ? "ProcessTimedOut" : "ProcessExited";
        if (fstatat(dir, "cancel", &state, AT_SYMLINK_NOFOLLOW) == 0) termination = "ProcessCancelled";
        /* Some settled timeout units retain no numeric main wait status. The
         * explicit timeout/cancel outcome and empty group still prove fencing,
         * but cannot prove validation success or an invented signal exit code. */
        if ((status < 0 && (observation.code || !strcmp(termination, "ProcessExited"))) || status > 255) goto done;
        char exit_code[16] = "null";
        if (status >= 0) snprintf(exit_code, sizeof(exit_code), "%d", status);
        char receipt[2048];
        snprintf(receipt, sizeof(receipt), "{\"version\":2,\"unit\":\"%s\",\"fingerprint\":\"%s\",\"bootId\":\"%s\",\"invocationId\":\"%s\",\"exitCode\":%s,\"termination\":\"%s\",\"stdoutBytes\":%d,\"stderrBytes\":%d,\"stdoutTruncated\":%s,\"stderrTruncated\":%s,\"descendantsEmpty\":true,\"outputComplete\":true}\n", unit, fingerprint, boot, pinned, exit_code, termination, captured[0], captured[1], truncated[0] ? "true" : "false", truncated[1] ? "true" : "false");
        stage = 13;
        if (atomic_fact(dir, "complete.json", receipt)) goto done;
        result = 0; goto done;
      }
    }
    usleep(50000);
  }
done:
  if (result && private) { char failure[64]; snprintf(failure, sizeof(failure), "{\"stage\":%d}\n", stage); atomic_fact(dir, "unresolved.json", failure); }
  if (referenced) sd_bus_call_method(bus, DEST, MANAGER, DEST ".Manager", "UnrefUnit", NULL, NULL, "s", unit);
  sd_bus_message_unref(reply); sd_bus_flush_close_unref(bus); free(object);
  for (int i = 0; i < 2; ++i) { if (inputs[i] >= 0) close(inputs[i]); if (outputs[i] >= 0) close(outputs[i]); }
  if (lock >= 0) close(lock);
  if (dir >= 0) close(dir);
  return result;
}
#else
int shikigami_workspace_collect(const char *directory, const char *unit, const char *fingerprint, int limit, int seconds) {
  (void)directory; (void)unit; (void)fingerprint; (void)limit; (void)seconds; return 78;
}
#endif
#ifdef SHIKIGAMI_COLLECTOR_STANDALONE
int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--profile")) {
    puts(shikigami_workspace_systemd_profile()); return 0;
  }
  if (argc != 6) return 64;
  char *end1, *end2; long limit = strtol(argv[4], &end1, 10), seconds = strtol(argv[5], &end2, 10);
  if (*end1 || *end2 || limit < 1 || limit > 1048576 || seconds < 1 || seconds > 3660) return 64;
  return shikigami_workspace_collect(argv[1], argv[2], argv[3], (int)limit, (int)seconds);
}
#endif
