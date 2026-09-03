/**
 * UNIX socket addressing, with a filesystem fallback for systems that have no
 * abstract namespace.
 *
 * Copyright 2013-2023 Software Radio Systems Limited
 * Darwin compatibility layer added 2026 by Andrei Gosman.
 *
 * This file is part of srsRAN. Same licence as the rest of the tree.
 *
 * Linux lets a UNIX socket live in an abstract namespace: sun_path starts with
 * a NUL byte, the rest of it names the socket, and nothing appears in the
 * filesystem, so there is no file to collide with and nothing to clean up.
 *
 * Darwin has no such namespace. A sun_path that starts with NUL is an empty
 * path and bind fails with ENOENT. The addresses here fall back to real files
 * under a runtime directory, which means the path has to be removed before
 * binding: a socket file left behind by a previous run would otherwise be
 * rejected as already in use.
 */

#ifndef SRSRAN_UNIX_SOCKET_COMPAT_H
#define SRSRAN_UNIX_SOCKET_COMPAT_H

#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef SRSRAN_UNIX_SOCKET_DIR
#define SRSRAN_UNIX_SOCKET_DIR "/tmp"
#endif

/*
 * Fills addr for the socket called name, where name carries no prefix and no
 * path, for example "mme_s11". Returns the length to hand to bind, connect or
 * sendto.
 */
static inline socklen_t srsran_unix_addr(struct sockaddr_un* addr, const char* name)
{
  memset(addr, 0, sizeof(*addr));
  addr->sun_family = AF_UNIX;

#ifdef __linux__
  snprintf(addr->sun_path, sizeof(addr->sun_path), "@%s", name);
  addr->sun_path[0] = '\0';
  return (socklen_t)sizeof(*addr);
#else
  snprintf(addr->sun_path, sizeof(addr->sun_path), "%s/srsran_%s", SRSRAN_UNIX_SOCKET_DIR, name);
  return (socklen_t)(offsetof(struct sockaddr_un, sun_path) + strlen(addr->sun_path) + 1);
#endif
}

/*
 * Removes a stale socket file before binding. A no-op where the address lives
 * in the abstract namespace, since there is no file.
 */
static inline void srsran_unix_addr_cleanup(const struct sockaddr_un* addr)
{
#ifdef __linux__
  (void)addr;
#else
  if (addr->sun_path[0] != '\0') {
    unlink(addr->sun_path);
  }
#endif
}

#ifdef __cplusplus
}
#endif

#endif /* SRSRAN_UNIX_SOCKET_COMPAT_H */
