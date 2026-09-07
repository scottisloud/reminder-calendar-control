#include "include/CDisclaim.h"

#include <dlfcn.h>
#include <stddef.h>

/* Private SPI in /usr/lib/system/libquarantine.dylib. Declared here because no SDK
   header exposes them; the signatures are the ones the dylib actually exports. */
typedef int (*rcc_setdisclaim_fn)(posix_spawnattr_t *, int);
typedef pid_t (*rcc_responsible_fn)(pid_t);

static rcc_setdisclaim_fn rcc_setdisclaim = NULL;
static rcc_responsible_fn rcc_responsible = NULL;
static int rcc_symbols_looked_up = 0;

static void rcc_resolve_symbols(void) {
    if (rcc_symbols_looked_up) {
        return;
    }
    rcc_setdisclaim =
        (rcc_setdisclaim_fn)dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
    rcc_responsible =
        (rcc_responsible_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    rcc_symbols_looked_up = 1;
}

int rcc_spawnattrs_setdisclaim(posix_spawnattr_t *attr, int disclaim) {
    rcc_resolve_symbols();
    if (rcc_setdisclaim == NULL) {
        return -1;
    }
    return rcc_setdisclaim(attr, disclaim);
}

pid_t rcc_responsible_pid(pid_t pid) {
    rcc_resolve_symbols();
    if (rcc_responsible == NULL) {
        return -1;
    }
    return rcc_responsible(pid);
}

int rcc_disclaim_available(void) {
    rcc_resolve_symbols();
    return (rcc_setdisclaim != NULL && rcc_responsible != NULL) ? 1 : 0;
}
