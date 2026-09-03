/**
 * TUN device access, with a Darwin utun backend.
 *
 * Copyright 2013-2023 Software Radio Systems Limited
 * Darwin compatibility layer added 2026 by Andrei Gosman.
 *
 * This file is part of srsRAN. Same licence as the rest of the tree.
 *
 * Linux opens /dev/net/tun and names the device with TUNSETIFF. Darwin has
 * neither. Its equivalent, utun, is a PF_SYSTEM control socket, and it differs
 * in two ways that callers have to know about.
 *
 * The kernel picks the interface name. A utun is always utunN for the first
 * free N, so a configured device name cannot be honoured. srsran_tun_open
 * reports the name actually in use and leaves it to the caller to say so.
 *
 * Every packet carries a four byte address family prefix, in network order.
 * There is no equivalent of IFF_NO_PI to turn it off. srsran_tun_read and
 * srsran_tun_write add and remove it with readv and writev, so no copy is
 * needed and callers see bare IP packets exactly as they do on Linux.
 */

#ifndef SRSRAN_TUN_COMPAT_H
#define SRSRAN_TUN_COMPAT_H

#include <errno.h>
#include <string.h>
#include <sys/uio.h>
#include <unistd.h>

#ifdef __APPLE__

#include <arpa/inet.h>
#include <net/if_utun.h>
#include <netinet/in.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>

#else

#include <fcntl.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <sys/ioctl.h>

#endif

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Opens a TUN device. On success returns the descriptor and writes the name
 * of the interface in use into actual_name. On Linux that is requested_name;
 * on Darwin it is whatever the kernel assigned, which the caller should
 * compare against what it asked for. Returns -1 with errno set on failure.
 */
static inline int srsran_tun_open(const char* requested_name, char* actual_name, size_t actual_len)
{
#ifdef __APPLE__
  struct ctl_info     ci;
  struct sockaddr_ctl sc;
  socklen_t           nlen = (socklen_t)actual_len;
  int                 fd;

  (void)requested_name;

  fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
  if (fd < 0) {
    return -1;
  }

  memset(&ci, 0, sizeof(ci));
  strncpy(ci.ctl_name, UTUN_CONTROL_NAME, sizeof(ci.ctl_name) - 1);
  if (ioctl(fd, CTLIOCGINFO, &ci) < 0) {
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
  }

  memset(&sc, 0, sizeof(sc));
  sc.sc_len       = sizeof(sc);
  sc.sc_family    = AF_SYSTEM;
  sc.ss_sysaddr   = AF_SYS_CONTROL;
  sc.sc_id        = ci.ctl_id;
  sc.sc_unit      = 0; /* zero asks the kernel for the first free unit */

  if (connect(fd, (struct sockaddr*)&sc, sizeof(sc)) < 0) {
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
  }

  if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, actual_name, &nlen) < 0) {
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
  }

  return fd;
#else
  struct ifreq ifr;
  int          fd = open("/dev/net/tun", O_RDWR);
  if (fd < 0) {
    return -1;
  }

  memset(&ifr, 0, sizeof(ifr));
  ifr.ifr_flags = IFF_TUN | IFF_NO_PI;
  strncpy(ifr.ifr_name, requested_name, IFNAMSIZ - 1);
  ifr.ifr_name[IFNAMSIZ - 1] = '\0';

  if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
  }

  strncpy(actual_name, ifr.ifr_name, actual_len - 1);
  actual_name[actual_len - 1] = '\0';
  return fd;
#endif
}

/* Reads one packet. The returned length counts the IP packet only. */
static inline ssize_t srsran_tun_read(int fd, void* buf, size_t len)
{
#ifdef __APPLE__
  uint32_t     family;
  struct iovec iov[2];
  ssize_t      n;

  iov[0].iov_base = &family;
  iov[0].iov_len  = sizeof(family);
  iov[1].iov_base = buf;
  iov[1].iov_len  = len;

  n = readv(fd, iov, 2);
  if (n < (ssize_t)sizeof(family)) {
    return n < 0 ? n : 0;
  }
  return n - (ssize_t)sizeof(family);
#else
  return read(fd, buf, len);
#endif
}

/* Writes one packet. len counts the IP packet only. */
static inline ssize_t srsran_tun_write(int fd, const void* buf, size_t len)
{
#ifdef __APPLE__
  uint32_t     family;
  struct iovec iov[2];
  ssize_t      n;

  if (len == 0) {
    return 0;
  }

  /* The version nibble tells the two apart, which is all utun needs. */
  family = (((const unsigned char*)buf)[0] >> 4) == 6 ? htonl(AF_INET6) : htonl(AF_INET);

  iov[0].iov_base = &family;
  iov[0].iov_len  = sizeof(family);
  iov[1].iov_base = (void*)(uintptr_t)buf;
  iov[1].iov_len  = len;

  n = writev(fd, iov, 2);
  if (n < (ssize_t)sizeof(family)) {
    return n < 0 ? n : 0;
  }
  return n - (ssize_t)sizeof(family);
#else
  return write(fd, buf, len);
#endif
}

#ifdef __cplusplus
}
#endif

#endif /* SRSRAN_TUN_COMPAT_H */
