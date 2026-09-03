/*
 * struct udphdr with the Linux field names. Darwin's netinet/udp.h uses
 * uh_sport, uh_dport, uh_ulen and uh_sum for the same four words.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#ifndef SRSLAB_LINUX_UDP_H
#define SRSLAB_LINUX_UDP_H

#include <linux/types.h>

struct udphdr {
  __be16  source;
  __be16  dest;
  __be16  len;
  __sum16 check;
};

#endif
