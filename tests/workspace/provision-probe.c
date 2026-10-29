/* Native primitive evidence; no accepted execution or Unix account is created
 * by this fixture. The shell provisions only its disposable guest's account. */
#define _GNU_SOURCE
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include "workspace-systemd-profile.h"
struct ws_target;
struct ws_target *shikigami_ws_open(const char *, const char *);
void shikigami_ws_close(struct ws_target *);
int shikigami_ws_provision(struct ws_target *, int, int);
int shikigami_ws_replace_owned(struct ws_target *, const char *, const char *, const unsigned char *, int, const unsigned char *, int, int);
static void require(int yes, const char *message) {
  if (!yes) { fprintf(stderr,"FAIL %s (%d)\n",message,errno); exit(1); }
}
static void path(char out[1024], const char *root, const char *name) {
  require(snprintf(out,1024,"%s/%s",root,name)<1024,"fixture path bound");
}
static void file(const char *root, const char *name, mode_t mode) {
  char out[1024]; path(out,root,name);
  int fd=open(out,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
  require(fd>=0 && write(fd,"fixture",7)==7 && !fchmod(fd,mode) && !close(fd),"fixture file");
}
static int unchanged(const char *root) {
  char out[1024]; path(out,root,"file"); struct stat state;
  return !lstat(out,&state) && state.st_uid==0 && (state.st_mode&07777)==0644;
}
static void tree(char out[1024], const char *prefix, const char *name) {
  path(out,prefix,name); require(!mkdir(out,0755),"fixture tree");
  file(out,"file",0644);
}
static int provision(const char *root, int uid, int apply) {
  struct ws_target *target=shikigami_ws_open(root,".shikigami-profile-target");
  require(target!=NULL,"anchor fixture tree");
  int result=shikigami_ws_provision(target,uid,apply);
  shikigami_ws_close(target); return result;
}
static void owned(const char *root, const char *name, uid_t uid, mode_t mode) {
  char out[1024]; path(out,root,name); struct stat state;
  require(!lstat(out,&state) && state.st_uid==uid && state.st_gid==uid && (state.st_mode&07777)==mode,"exact owner and private mode");
}
int main(int argc,char **argv) {
  if (argc==2 && !strcmp(argv[1],"--profile")) { puts(SHIKIGAMI_WORKSPACE_SYSTEMD_PROFILE); return 0; }
  if (argc==2 && !strcmp(argv[1],"--unsupported")) {
    require(shikigami_ws_provision(NULL,62001,1)==-78,"unprivileged provisioning refused");
    puts("PASS an unprivileged process cannot provision an identity or directory"); return 0;
  }
  require(argc==2 && getuid()==0,"root guest fixture");
  const char *prefix=argv[1]; umask(0);
  char root[1024], other[1024], target[1024];
  tree(root,prefix,"good");
  path(other,root,"sub"); require(!mkdir(other,0755),"nested fixture directory");
  file(other,"script",04777);
  require(!provision(root,62001,0) && unchanged(root),"read-only preflight has no ownership effect");
  puts("PASS complete preflight leaves ownership and permissions unchanged");
  require(!provision(root,62001,1),"native provision");
  owned(root,"",62001,0700); owned(root,"file",62001,0600);
  owned(root,"sub",62001,0700); owned(root,"sub/script",62001,0700);
  require(!provision(root,62001,1),"repeat same reserved identity");
  puts("PASS all files and directories acquire the reserved identity, retain executable intent and converge on retry");
  char metadata[1024]; path(metadata,prefix,"metadata"); require(!mkdir(metadata,0700),"private fixture metadata");
  struct ws_target *publication=shikigami_ws_open(root,"published"); require(publication!=NULL,"new owned target");
  require(!shikigami_ws_replace_owned(publication,metadata,"publish-owned",NULL,-1,(const unsigned char *)"fixture",7,62001),"owned publication");
  shikigami_ws_close(publication); owned(root,"published",62001,0600);
  publication=shikigami_ws_open(root,"sub/script"); require(publication!=NULL,"existing owned target");
  require(shikigami_ws_replace_owned(publication,metadata,"wrong-identity",(const unsigned char *)"fixture",7,(const unsigned char *)"other",5,62002)<0,"another identity refused");
  require(!shikigami_ws_replace_owned(publication,metadata,"replace-owned",(const unsigned char *)"fixture",7,(const unsigned char *)"fixture",7,62001),"owned executable replacement");
  shikigami_ws_close(publication); owned(root,"sub/script",62001,0700);
  puts("PASS new and replaced files retain reserved ownership and executable intent without accepting another identity");
  tree(root,prefix,"symlink"); file(prefix,"outside",0644);
  path(other,root,"link"); path(target,prefix,"outside");
  require(!symlink(target,other),"fixture symlink");
  require(provision(root,62001,1)<0 && unchanged(root),"symlink refusal before effects");
  struct stat outside; require(!lstat(target,&outside) && outside.st_uid==0,"outside target untouched");
  puts("PASS a symlink refuses the whole preflight without changing its target or ordinary files");
  tree(root,prefix,"fifo"); path(other,root,"fifo"); require(!mkfifo(other,0600),"fixture fifo");
  require(provision(root,62001,1)<0 && unchanged(root),"fifo refusal before effects");
  puts("PASS a FIFO is refused without opening or waiting on it");
  tree(root,prefix,"hardlink"); path(other,root,"alias"); require(!link(target,other),"fixture hardlink");
  require(provision(root,62001,1)<0 && unchanged(root),"hardlink refusal before effects");
  require(!lstat(target,&outside) && outside.st_uid==0,"outside hardlink untouched");
  puts("PASS a hard link cannot transfer ownership of an outside inode");
  tree(root,prefix,"moved");
  struct ws_target *anchor=shikigami_ws_open(root,".shikigami-profile-target"); require(anchor!=NULL,"original anchor");
  path(other,prefix,"original"); require(!rename(root,other) && !mkdir(root,0755),"substitute fixture root");
  require(shikigami_ws_provision(anchor,62001,1)==-3 && unchanged(other),"substituted root refused");
  shikigami_ws_close(anchor);
  puts("PASS root substitution after target authorization refuses before ownership changes");
  tree(root,prefix,"partial"); path(other,root,"file"); require(!chown(other,62001,62001),"partial fixture ownership");
  require(provision(root,62002,1)<0,"another identity cannot adopt partial provisioning");
  require(!provision(root,62001,1),"recover original partial identity");
  owned(root,"file",62001,0600);
  puts("PASS partial provisioning recovers only its original reserved identity");
  tree(root,prefix,"invalid");
  require(provision(root,0,1)<0 && unchanged(root),"root identity refused");
  puts("PASS a root identity request refuses before any tree changes");
  return 0;
}
