#pragma once

#include <spawn.h>
#include <sys/types.h>

/// Thin wrappers over two private symbols in `libquarantine.dylib`.
///
/// Neither has an SDK header, so they are resolved with `dlsym` at first use rather than
/// linked against: a future OS that drops them must make `rcc` degrade with a diagnostic
/// (SPEC §6.2), not fail to load.
///
/// Returns 0 on success, -1 if the symbol is unavailable, otherwise the SPI's own return.
int rcc_spawnattrs_setdisclaim(posix_spawnattr_t *attr, int disclaim);

/// The process TCC holds responsible for `pid`'s access requests. Returns -1 if the
/// symbol is unavailable.
///
/// This is the authoritative observable for whether disclaiming worked: before the
/// disclaimed re-exec it reports the top of the launching chain (Claude Desktop,
/// Terminal, launchd); afterwards it reports the process itself.
pid_t rcc_responsible_pid(pid_t pid);

/// Whether both symbols resolved. `rcc doctor` reports this directly.
int rcc_disclaim_available(void);
