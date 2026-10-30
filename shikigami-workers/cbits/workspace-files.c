/* Descriptor-relative workspace IO. Provider metadata and the workspace parent
 * must be private to the provider. All workspace writers share its lock and
 * supervised repository processes must be settled before these operations. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
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
static int replace_impl(struct ws_target *t, const char *private_dir,
                        const char *nonce, const unsigned char *expected,
                        int expected_size, const unsigned char *bytes, int size, int uid) {
  if (uid >= 0 && expected_size >= 0 &&
      (t->file < 0 || t->original.st_uid != (uid_t)uid || t->original.st_gid != (gid_t)uid)) return -3;
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
  if (uid >= 0) mode = expected_size >= 0 && (t->original.st_mode & 0111) ? 0700 : 0600;
  int result = write_all(fd, bytes, size) ||
    (uid >= 0 && fchown(fd, (uid_t)uid, (gid_t)uid)) || fchmod(fd, mode) || fsync(fd);
  if (close(fd)) result = -1;
  if (!result) result = renameat(staging, nonce, t->parent, t->leaf);
  if (!result) result = fsync(staging);
  if (!result) result = fsync(t->parent);
  /* A failure after rename is uncertain; the retained prepared receipt and
   * content digest reconcile it. Remove only this invocation's private temp. */
  unlinkat(staging, nonce, 0); close(staging);
  return result ? -1 : 0;
}
int shikigami_ws_replace(struct ws_target *t, const char *private_dir,
                        const char *nonce, const unsigned char *expected,
                        int expected_size, const unsigned char *bytes, int size) {
  return replace_impl(t, private_dir, nonce, expected, expected_size, bytes, size, -1);
}
int shikigami_ws_replace_owned(struct ws_target *t, const char *private_dir,
                        const char *nonce, const unsigned char *expected,
                        int expected_size, const unsigned char *bytes, int size, int uid) {
#ifdef __linux__
  if (getuid() != 0 || geteuid() != 0) return -78;
  if (uid < 1000) return -1;
  return replace_impl(t, private_dir, nonce, expected, expected_size, bytes, size, uid);
#else
  (void)t; (void)private_dir; (void)nonce; (void)expected;
  (void)expected_size; (void)bytes; (void)size; (void)uid; return -78;
#endif
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
/* Release the open-file-description lock explicitly: another provider thread
 * may briefly fork a CLOEXEC descriptor before that unrelated child execs. */
void shikigami_ws_unlock(int fd) { flock(fd, LOCK_UN); close(fd); }

int shikigami_ws_private(const char *path) {
  int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return -1;
  struct stat state;
  int result = fstat(fd, &state) || state.st_uid != geteuid() || fchmod(fd, 0700);
  close(fd); return result ? -1 : 0;
}

/* Receipt readers must not repair permissions and then trust facts which may
 * have been exposed for modification before that repair. */
int shikigami_ws_is_private(const char *path) {
  int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return -1;
  struct stat state;
  int result = fstat(fd, &state) || state.st_uid != geteuid() || (state.st_mode & 077);
  close(fd); return result ? -1 : 0;
}

#ifdef __linux__
/* Provision only while the provider lock and database barrier establish that
 * no repository process can run. Never follow a symlink or touch a device.
 * A complete read-only pass precedes ownership changes. Interrupted changes
 * are repeatable for this same reserved uid, not transferable to another one. */
static int provision_node(int fd, dev_t device, uid_t uid, int apply,
                          int *remaining, int depth) {
  struct stat state;
  if (--*remaining < 0 || depth > 128) return -5;
  if (fstat(fd, &state) || state.st_dev != device ||
      (state.st_uid != 0 && state.st_uid != uid) ||
      (state.st_gid != 0 && state.st_gid != uid) ||
      (!S_ISDIR(state.st_mode) && (!S_ISREG(state.st_mode) || state.st_nlink != 1))) return -1;
  if (S_ISDIR(state.st_mode)) {
    int copy = dup(fd);
    if (copy < 0) return -1;
    DIR *entries = fdopendir(copy);
    if (!entries) { close(copy); return -1; }
    rewinddir(entries);
    struct dirent *entry;
    int result = 0;
    errno = 0;
    while ((entry = readdir(entries))) {
      if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
      if (!component(entry->d_name)) { result = -1; break; }
      /* Pin with O_PATH first. Opening a device for read could already have an
       * effect; inspect the pinned object before opening an ordinary handle. */
      int pinned = openat(fd, entry->d_name, O_PATH | O_NOFOLLOW | O_CLOEXEC);
      struct stat child;
      if (pinned < 0) { result = -1; break; }
      if (fstat(pinned, &child) || (!S_ISREG(child.st_mode) && !S_ISDIR(child.st_mode))) {
        close(pinned); result = -1; break;
      }
      char location[64];
      snprintf(location, sizeof(location), "/proc/self/fd/%d", pinned);
      int opened = open(location, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (S_ISDIR(child.st_mode) ? O_DIRECTORY : 0));
      close(pinned);
      if (opened < 0) { result = -1; break; }
      result = provision_node(opened, device, uid, apply, remaining, depth + 1);
      close(opened);
      if (result) break;
      errno = 0;
    }
    if (!result && errno) result = -1;
    closedir(entries);
    if (result) return result;
  }
  if (apply) {
    mode_t mode = S_ISDIR(state.st_mode) || (state.st_mode & 0111) ? 0700 : 0600;
    if (fchown(fd, uid, uid) || fchmod(fd, mode) || fsync(fd)) return -1;
  }
  return 0;
}
static int same_provision_parent(struct ws_target *target) {
  struct ws_target *current = shikigami_ws_open(target->root, target->path);
  if (!current) return 0;
  struct stat original, actual;
  int same = !fstat(target->parent, &original) && !fstat(current->parent, &actual) &&
    original.st_dev == actual.st_dev && original.st_ino == actual.st_ino;
  shikigami_ws_close(current);
  return same;
}
int shikigami_ws_provision(struct ws_target *target, int uid, int apply) {
  if (geteuid() != 0 || getuid() != 0) return -78;
  if (!target || uid < 1000 || (apply != 0 && apply != 1)) return -1;
  if (!same_provision_parent(target)) return -3;
  struct stat root;
  if (fstat(target->parent, &root)) return -1;
  int remaining = 100000;
  int result = provision_node(target->parent, root.st_dev, (uid_t)uid, 0, &remaining, 0);
  if (result || !apply) return result;
  if (!same_provision_parent(target)) return -3;
  remaining = 100000;
  result = provision_node(target->parent, root.st_dev, (uid_t)uid, 1, &remaining, 0);
  return result ? result : (same_provision_parent(target) ? 0 : -3);
}
/* Protected Git capture enumerates pinned regular files only. No directory
 * entry can cause a device open or traversal through a symlink. Callers retain
 * the same workspace lock and settled-process barrier while reading contents. */
static int manifest_node(int fd, dev_t device, uid_t uid, int depth,
                         int *remaining, const char *prefix,
                         char *out, int capacity, int *used) {
  struct stat state;
  if (--*remaining < 0 || depth > 128) return -5;
  if (fstat(fd, &state) || state.st_dev != device || state.st_uid != uid ||
      state.st_gid != uid || (!S_ISDIR(state.st_mode) &&
      (!S_ISREG(state.st_mode) || state.st_nlink != 1))) return -1;
  if (S_ISREG(state.st_mode)) {
    int size = snprintf(out + *used, capacity - *used, "%s\t%s",
      state.st_mode & 0111 ? "100755" : "100644", prefix);
    if (size < 0 || size >= capacity - *used) return -5;
    *used += size + 1;
    return 0;
  }
  int copy = dup(fd);
  if (copy < 0) return -1;
  DIR *entries = fdopendir(copy);
  if (!entries) { close(copy); return -1; }
  rewinddir(entries);
  struct dirent *entry;
  int result = 0;
  errno = 0;
  while ((entry = readdir(entries))) {
    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
    if (!component(entry->d_name) || strchr(entry->d_name, '\\')) { result = -1; break; }
    for (const unsigned char *p = (const unsigned char *)entry->d_name; *p; ++p)
      if (*p < 32 || *p >= 127) { result = -1; break; }
    if (result) break;
    char path[4097];
    int size = snprintf(path, sizeof(path), "%s%s%s", prefix, *prefix ? "/" : "", entry->d_name);
    if (size < 0 || (size_t)size >= sizeof(path)) { result = -5; break; }
    int pinned = openat(fd, entry->d_name, O_PATH | O_NOFOLLOW | O_CLOEXEC);
    struct stat child;
    if (pinned < 0) { result = -1; break; }
    if (fstat(pinned, &child) || (!S_ISREG(child.st_mode) && !S_ISDIR(child.st_mode))) {
      close(pinned); result = -1; break;
    }
    char location[64];
    snprintf(location, sizeof(location), "/proc/self/fd/%d", pinned);
    int opened = open(location, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (S_ISDIR(child.st_mode) ? O_DIRECTORY : 0));
    close(pinned);
    if (opened < 0) { result = -1; break; }
    result = manifest_node(opened, device, uid, depth + 1, remaining, path, out, capacity, used);
    close(opened);
    if (result) break;
    errno = 0;
  }
  if (!result && errno) result = -1;
  closedir(entries);
  return result;
}
int shikigami_ws_manifest(struct ws_target *target, int uid, char *out, int capacity) {
  if (geteuid() != 0 || getuid() != 0) return -78;
  if (!target || uid < 1000 || !out || capacity < 1 || capacity > 1048576) return -1;
  if (!same_provision_parent(target)) return -3;
  struct stat root;
  if (fstat(target->parent, &root)) return -1;
  int remaining = 100000, used = 0;
  int result = manifest_node(target->parent, root.st_dev, (uid_t)uid, 0, &remaining, "", out, capacity, &used);
  if (result) return result;
  return same_provision_parent(target) ? used : -3;
}
#else
int shikigami_ws_provision(struct ws_target *target, int uid, int apply) {
  (void)target; (void)uid; (void)apply; return -78;
}
int shikigami_ws_manifest(struct ws_target *target, int uid, char *out, int capacity) {
  (void)target; (void)uid; (void)out; (void)capacity; return -78;
}
#endif
/* Terminal cleanup removes only a retained files/scratch root. The provider
 * holds the metadata lock, has frozen admission and has durable settlement for
 * every repository process. Validate the entire bounded tree before deleting
 * anything; recovery validates whatever remains against the original inode. */
static int cleanup_node(int fd, dev_t device, uid_t uid, int depth,
                        int *remaining, int apply) {
  struct stat root;
  if (depth > 128 || --*remaining < 0 || fstat(fd, &root) ||
      !S_ISDIR(root.st_mode) || root.st_dev != device || root.st_uid != uid)
    return -1;
  int copy = dup(fd);
  if (copy < 0) return -1;
  DIR *entries = fdopendir(copy);
  if (!entries) { close(copy); return -1; }
  rewinddir(entries);
  int result = 0;
  struct dirent *entry;
  while ((entry = readdir(entries))) {
    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
    struct stat before, after;
    if (fstatat(fd, entry->d_name, &before, AT_SYMLINK_NOFOLLOW) ||
        before.st_dev != device || before.st_uid != uid) { result = -1; break; }
    if (S_ISDIR(before.st_mode)) {
      int child = openat(fd, entry->d_name,
                         O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      if (child < 0) { result = -1; break; }
      if (fstat(child, &after) || before.st_dev != after.st_dev ||
          before.st_ino != after.st_ino) result = -3;
      else result = cleanup_node(child, device, uid, depth + 1, remaining, apply);
      close(child);
      if (!result && apply && unlinkat(fd, entry->d_name, AT_REMOVEDIR)) result = -1;
    } else if (S_ISREG(before.st_mode) && before.st_nlink == 1) {
      if (--*remaining < 0) result = -5;
      else if (apply && unlinkat(fd, entry->d_name, 0)) result = -1;
    } else result = -1;
    if (result) break;
  }
  closedir(entries);
  if (!result && apply && fsync(fd)) result = -1;
  return result;
}
int shikigami_ws_cleanup(const char *parent, const char *name,
                         const char *identity, int uid) {
  if (!parent || !name || !identity || uid < 0 ||
      (strcmp(name, "files") && strcmp(name, "scratch"))) return -1;
  int directory = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (directory < 0) return -1;
  struct stat state;
  if (fstatat(directory, name, &state, AT_SYMLINK_NOFOLLOW)) {
    int result = errno == ENOENT ? 0 : -1;
    close(directory); return result;
  }
  int root = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (root < 0) { close(directory); return -1; }
  struct stat opened;
  char actual[128];
  int result = -3;
  if (fstat(root, &opened) || !S_ISDIR(state.st_mode) ||
      state.st_dev != opened.st_dev || state.st_ino != opened.st_ino) goto done;
  int count = snprintf(actual, sizeof(actual), "%llu:%llu",
                       (unsigned long long)opened.st_dev,
                       (unsigned long long)opened.st_ino);
  if (count < 0 || count >= (int)sizeof(actual) || strcmp(actual, identity)) goto done;
  int remaining = 100000;
  result = cleanup_node(root, opened.st_dev, (uid_t)uid, 0, &remaining, 0);
  if (result) goto done;
  remaining = 100000;
  result = cleanup_node(root, opened.st_dev, (uid_t)uid, 0, &remaining, 1);
  if (result) goto done;
  if (fstatat(directory, name, &state, AT_SYMLINK_NOFOLLOW) ||
      state.st_dev != opened.st_dev || state.st_ino != opened.st_ino) { result = -3; goto done; }
  if (unlinkat(directory, name, AT_REMOVEDIR) || fsync(directory)) result = -1;
done:
  close(root); close(directory); return result;
}
