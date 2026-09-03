/*
 * struct ipv6hdr and struct in6_ifreq, as Linux declares them.
 * Layout is fixed by RFC 8200.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#ifndef SRSLAB_LINUX_IPV6_H
#define SRSLAB_LINUX_IPV6_H

#include <linux/types.h>
#include <machine/endian.h>
#include <netinet/in.h>

struct ipv6hdr {
#if BYTE_ORDER == LITTLE_ENDIAN
  __u8 priority : 4, version : 4;
#elif BYTE_ORDER == BIG_ENDIAN
  __u8 version : 4, priority : 4;
#else
#error "unknown byte order"
#endif
  __u8 flow_lbl[3];

  __be16 payload_len;
  __u8   nexthdr;
  __u8   hop_limit;

  struct in6_addr saddr;
  struct in6_addr daddr;
};

struct in6_ifreq {
  struct in6_addr ifr6_addr;
  __u32           ifr6_prefixlen;
  int             ifr6_ifindex;
};

#endif
