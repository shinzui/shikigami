/* Descriptor-relative workspace IO. Provider metadata and the workspace parent
 * must be private to the provider. All workspace writers share its lock and
 * supervised repository processes must be settled before these operations. */
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdio.h>
#include <errno.h>
#include <dirent.h>

struct ws_target { int parent; int file; char *leaf; char *root; char *path; struct stat original; };

static int component(const char *s) {
  for (const unsigned char *p = (const unsigned char *)s; *p; ++p) if (*p >= 127) return 0;
  return *s && strcmp(s, ".") && strcmp(s, "..") && strcasecmp(s, ".git");
}
/* Require the exact directory-entry spelling. Case-insensitive host lookups
 * must not bypass the frozen, case-sensitive repository instruction scopes. */
static int exact_entry(int parent, const char *name) {
  int copy = dup(parent);
  if (copy < 0) return 0;
  DIR *entries = fdopendir(copy);
  if (!entries) { close(copy); return 0; }
  rewinddir(entries);
  int found = 0, count = 0;
  struct dirent *entry;
  while ((entry = readdir(entries))) {
    if (++count > 100000) break;
    if (!strcmp(entry->d_name, name)) { found = 1; break; }
  }
  closedir(entries); return found;
}
void shikigami_ws_close(struct ws_target *t) {
  if (!t) return;
  if (t->file >= 0) close(t->file);
  if (t->parent >= 0) close(t->parent);
  free(t->leaf); free(t->root); free(t->path); free(t);
}
struct ws_target *shikigami_ws_open(const char *root, const char *path) {
  if (!*path || *path == '/' || strchr(path, '\\')) return NULL;
  int dir = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (dir < 0) return NULL;
  struct stat anchor;
  if (fstat(dir, &anchor)) { close(dir); return NULL; }
  char *copy = strdup(path);
  if (!copy) { close(dir); return NULL; }
  char *part = copy, *slash;
  while ((slash = strchr(part, '/'))) {
    *slash = 0;
    if (!component(part) || !exact_entry(dir, part)) goto fail;
    int next = openat(dir, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (next < 0) goto fail;
    struct stat state;
    if (fstat(next, &state) || state.st_dev != anchor.st_dev) { close(next); goto fail; }
    close(dir); dir = next; part = slash + 1;
  }
  if (!component(part)) goto fail;
  struct ws_target *t = calloc(1, sizeof(*t));
  if (!t) goto fail;
  t->parent = dir; t->file = -1; t->leaf = strdup(part);
  t->root = strdup(root); t->path = strdup(path);
  free(copy);
  if (!t->leaf || !t->root || !t->path) { shikigami_ws_close(t); return NULL; }
  t->file = openat(dir, t->leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
  if (t->file < 0) {
    if (errno == ENOENT) return t;
    shikigami_ws_close(t); return NULL;
  }
  if (!exact_entry(dir, t->leaf) || fstat(t->file, &t->original) || !S_ISREG(t->original.st_mode) ||
      t->original.st_nlink != 1 || t->original.st_dev != anchor.st_dev) {
    shikigami_ws_close(t); return NULL;
  }
  return t;
fail:
  free(copy); close(dir); return NULL;
}
int shikigami_ws_identity(struct ws_target *t, char *out, int size) {
  struct stat parent;
  if (fstat(t->parent, &parent)) return -1;
  int n = snprintf(out, size, "%llu:%llu", (unsigned long long)parent.st_dev,
                   (unsigned long long)parent.st_ino);
  return n >= 0 && n < size ? n : -1;
}
int shikigami_ws_read(struct ws_target *t, unsigned char *out, int limit) {
  if (t->file < 0) return -2;
  struct stat state;
  if (fstat(t->file, &state) || !S_ISREG(state.st_mode) || state.st_nlink != 1) return -1;
  if (state.st_size > limit) return -5;
  int total = 0;
  while (total <= limit) {
    ssize_t n = pread(t->file, out + total, limit + 1 - total, total);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) return -1;
    if (!n) return total;
    total += (int)n;
  }
  return -5;
}
static int write_all(int fd, const unsigned char *bytes, int size) {
  int total = 0;
  while (total < size) {
    ssize_t n = write(fd, bytes + total, size - total);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return -1;
    total += (int)n;
  }
  return 0;
}
/* expected_size == -1 means the accepted target was absent. Compare bytes
 * again immediately before publication. Never write through a mutable inode. */
int shikigami_ws_replace(struct ws_target *t, const char *private_dir,
                        const char *nonce, const unsigned char *expected,
                        int expected_size, const unsigned char *bytes, int size) {
  /* Re-resolve only under the provider's private root and refuse a substituted
   * parent before publishing. No symlink component is followed. */
  struct ws_target *current = shikigami_ws_open(t->root, t->path);
  if (!current) return -3;
  struct stat original_parent, current_parent;
  int moved = fstat(t->parent, &original_parent) || fstat(current->parent, &current_parent) ||
    original_parent.st_dev != current_parent.st_dev || original_parent.st_ino != current_parent.st_ino;
  shikigami_ws_close(current);
  if (moved) return -3;
  if (!component(nonce) || strchr(nonce, '/')) return -1;
  struct stat now;
  int found = fstatat(t->parent, t->leaf, &now, AT_SYMLINK_NOFOLLOW);
  if (expected_size < 0) {
    if (t->file >= 0 || !found || errno != ENOENT) return -3;
  } else {
    if (found || t->file < 0 || !S_ISREG(now.st_mode) || now.st_nlink != 1 ||
        now.st_dev != t->original.st_dev || now.st_ino != t->original.st_ino ||
        now.st_size != expected_size) return -3;
    unsigned char buffer[8192]; int offset = 0;
    while (offset < expected_size) {
      int wanted = expected_size - offset;
      if (wanted > (int)sizeof(buffer)) wanted = sizeof(buffer);
      ssize_t n = pread(t->file, buffer, wanted, offset);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0 || memcmp(buffer, expected + offset, n)) return -3;
      offset += (int)n;
    }
  }
  int staging = open(private_dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (staging < 0) return -1;
  int fd = openat(staging, nonce, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (fd < 0) { close(staging); return -1; }
  mode_t mode = expected_size < 0 ? 0644 : (t->original.st_mode & 0777);
  int result = write_all(fd, bytes, size) || fchmod(fd, mode) || fsync(fd);
  if (close(fd)) result = -1;
  if (!result) result = renameat(staging, nonce, t->parent, t->leaf);
  if (!result) result = fsync(staging);
  if (!result) result = fsync(t->parent);
  /* A failure after rename is uncertain; the retained prepared receipt and
   * content digest reconcile it. Remove only this invocation's private temp. */
  unlinkat(staging, nonce, 0); close(staging);
  return result ? -1 : 0;
}
int shikigami_ws_lock(const char *metadata) {
  int dir = open(metadata, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (dir < 0) return -1;
  int fd = openat(dir, "workspace.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
  close(dir);
  if (fd < 0) return -1;
  struct stat state;
  if (fstat(fd, &state) || !S_ISREG(state.st_mode) || state.st_nlink != 1 ||
      flock(fd, LOCK_EX | LOCK_NB)) { close(fd); return -1; }
  return fd;
}
void shikigami_ws_unlock(int fd) { close(fd); }

int shikigami_ws_private(const char *path) {
  int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return -1;
  struct stat state;
  int result = fstat(fd, &state) || state.st_uid != geteuid() || fchmod(fd, 0700);
  close(fd); return result ? -1 : 0;
}
