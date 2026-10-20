#define _GNU_SOURCE
#include <pwd.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>
struct passwd *getpwuid(uid_t uid) {
 static struct passwd *(*real)(uid_t);
 if (!real) real=dlsym(RTLD_NEXT,"getpwuid");
 struct passwd *p=real(uid);
 if (p && uid==getuid() && getenv("FM_LAB_ACCOUNT_HOME")) p->pw_dir=getenv("FM_LAB_ACCOUNT_HOME");
 return p;
}
