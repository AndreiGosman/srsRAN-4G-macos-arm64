/*
 * struct iphdr, as Linux declares it.
 *
 * Darwin has struct ip in netinet/ip.h with the same layout and different
 * field names. Code written against Linux uses the names below, and the
 * layout is fixed by RFC 791, so declaring it here is exact rather than an
 * approximation.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#ifndef SRSLAB_LINUX_IP_H
#define SRSLAB_LINUX_IP_H

#include <linux/types.h>
#include <machine/endian.h>

struct iphdr {
#if BYTE_ORDER == LITTLE_ENDIAN
  __u8 ihl : 4, version : 4;
#elif BYTE_ORDER == BIG_ENDIAN
  __u8 version : 4, ihl : 4;
#else
#error "unknown byte order"
#endif
  __u8   tos;
  __be16 tot_len;
  __be16 id;
  __be16 frag_off;
  __u8   ttl;
  __u8   protocol;
  __sum16 check;
  __be32 saddr;
  __be32 daddr;
};

#endif
