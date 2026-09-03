/*
 * struct tcphdr with the Linux field names, layout fixed by RFC 9293.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#ifndef SRSLAB_LINUX_TCP_H
#define SRSLAB_LINUX_TCP_H

#include <linux/types.h>
#include <machine/endian.h>

struct tcphdr {
  __be16 source;
  __be16 dest;
  __be32 seq;
  __be32 ack_seq;
#if BYTE_ORDER == LITTLE_ENDIAN
  __u16 res1 : 4, doff : 4, fin : 1, syn : 1, rst : 1, psh : 1, ack : 1, urg : 1, ece : 1, cwr : 1;
#elif BYTE_ORDER == BIG_ENDIAN
  __u16 doff : 4, res1 : 4, cwr : 1, ece : 1, urg : 1, ack : 1, psh : 1, rst : 1, syn : 1, fin : 1;
#else
#error "unknown byte order"
#endif
  __be16  window;
  __sum16 check;
  __be16  urg_ptr;
};

#endif
