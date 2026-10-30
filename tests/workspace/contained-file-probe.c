#define _GNU_SOURCE
#include "workspace-files.c"
#include <signal.h>
#include <sys/wait.h>

static void require(int condition, const char *label) {
  if (!condition) { fprintf(stderr, "FAIL %s\n", label); exit(1); }
}
static char *child(const char *parent, const char *name) {
  char *path = malloc(strlen(parent) + strlen(name) + 2);
  require(path != NULL, "path allocation");
  strcpy(path, parent); strcat(path, "/"); strcat(path, name); return path;
}
static void put(const char *path, const char *value) {
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  require(fd >= 0, "fixture file");
  require(!write_all(fd, (const unsigned char *)value, strlen(value)), "fixture write");
  close(fd);
}
int main(void) {
  char template[] = "/tmp/shikigami-contained-XXXXXX";
  char *temporary = mkdtemp(template);
  require(temporary != NULL, "fixture directory");
  char *root = child(temporary, "files"), *metadata = child(temporary, "metadata"), *outside = child(temporary, "outside");
  require(!mkdir(root,0700) && !mkdir(metadata,0700) && !mkdir(outside,0700), "fixture roots");
  char *file = child(root,"file"), *secret = child(outside,"secret");
  put(file,"old"); put(secret,"PRIVATE_OUTSIDE");
  struct ws_target *target = shikigami_ws_open(root,"file");
  unsigned char bytes[16];
  require(target && shikigami_ws_read(target,bytes,15)==3 && !memcmp(bytes,"old",3), "contained read");
  require(!shikigami_ws_replace(target,metadata,"replace-one",(const unsigned char *)"old",3,(const unsigned char *)"new",3), "compare and replace");
  shikigami_ws_close(target);
  puts("PASS bounded contained read and replacement");

  target = shikigami_ws_open(root,"file");
  require(target != NULL, "reopen target");
  require(!unlink(file) && !symlink(secret,file), "substitute leaf");
  require(shikigami_ws_replace(target,metadata,"replace-two",(const unsigned char *)"new",3,(const unsigned char *)"bad",3)==-3, "refuse substituted leaf");
  shikigami_ws_close(target);
  puts("PASS substituted leaf refuses publication");

  char *nested=child(root,"nested"), *retained=child(root,"retained");
  require(!mkdir(nested,0700), "nested fixture");
  put(child(nested,"file"),"old");
  target=shikigami_ws_open(root,"nested/file");
  require(target && !rename(nested,retained) && !symlink(outside,nested), "substitute parent");
  require(shikigami_ws_replace(target,metadata,"replace-three",(const unsigned char *)"old",3,(const unsigned char *)"bad",3)==-3, "refuse substituted parent");
  shikigami_ws_close(target);
  puts("PASS substituted parent refuses publication");

  require(!link(secret,child(root,"hardlink")), "hardlink fixture");
  require(shikigami_ws_open(root,"hardlink")==NULL && shikigami_ws_open(root,"../outside/secret")==NULL && shikigami_ws_open(root,".git/config")==NULL, "refuse unsafe objects");
  require(!mkfifo(child(root,"fifo"),0600) && shikigami_ws_open(root,"fifo")==NULL, "nonblocking fifo refusal");
  puts("PASS traversal, metadata, hardlinks and FIFOs refuse");

  target=shikigami_ws_open(root,"retained/file");
  require(target && shikigami_ws_read(target,bytes,2)==-5, "bound read");
  put(child(retained,"file"),"bad");
  require(shikigami_ws_replace(target,metadata,"replace-four",(const unsigned char *)"old",3,(const unsigned char *)"new",3)==-3, "recheck inode bytes");
  shikigami_ws_close(target);
  puts("PASS byte limits and same-inode conflicts");

  int communication[2]; require(!pipe(communication), "lock pipe");
  pid_t owner=fork(); require(owner>=0, "lock owner");
  if (!owner) {
    close(communication[0]);
    int lock=shikigami_ws_lock(metadata);
    if (lock<0 || write(communication[1],"1",1)!=1) _exit(1);
    for (;;) pause();
  }
  close(communication[1]);
  require(read(communication[0],bytes,1)==1, "lock acquired"); close(communication[0]);
  require(shikigami_ws_lock(metadata)<0, "lock excludes second process");
  require(!kill(owner,SIGKILL) && waitpid(owner,NULL,0)==owner, "settle killed owner");
  int lock=shikigami_ws_lock(metadata); require(lock>=0, "lock recovered after owner death");
  shikigami_ws_unlock(lock);
  puts("PASS process death releases the independent file lock");
  struct stat state;
  char identity[128];
  require(!stat(root,&state), "cleanup root identity");
  snprintf(identity,sizeof(identity),"%llu:%llu",(unsigned long long)state.st_dev,(unsigned long long)state.st_ino);
  require(shikigami_ws_cleanup(temporary,"files",identity,getuid())!=0 &&
          !access(child(retained,"file"),F_OK) && !access(secret,F_OK), "hostile cleanup refuses before deletion");
  puts("PASS terminal cleanup refuses hostile trees before deleting ordinary files");

  char *scratch=child(temporary,"scratch"), *oldScratch=child(temporary,"scratch-retained");
  require(!mkdir(scratch,0700), "cleanup scratch root");
  put(child(scratch,"file"),"retained");
  require(!stat(scratch,&state), "scratch identity");
  snprintf(identity,sizeof(identity),"%llu:%llu",(unsigned long long)state.st_dev,(unsigned long long)state.st_ino);
  require(!rename(scratch,oldScratch) && !mkdir(scratch,0700), "substitute cleanup root");
  require(shikigami_ws_cleanup(temporary,"scratch",identity,getuid())!=0 &&
          !access(child(oldScratch,"file"),F_OK), "substituted cleanup root refuses");
  puts("PASS terminal cleanup pins the original root inode");
  require(!rmdir(scratch) && !rename(oldScratch,scratch), "restore cleanup root");
  require(!shikigami_ws_cleanup(temporary,"scratch",identity,getuid()) &&
          access(scratch,F_OK)!=0 && !shikigami_ws_cleanup(temporary,"scratch",identity,getuid()) &&
          !access(secret,F_OK) && !access(metadata,F_OK), "exact cleanup and duplicate recovery");
  puts("PASS terminal cleanup removes only its exact owned root and recovers acknowledgement loss");
  puts("Native file boundary passed (9 cases); supervisor qualification remains separate.");
  return 0;
}
