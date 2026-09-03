/*
 * Darwin already declares struct ifreq, IFNAMSIZ, IFF_UP and IFF_RUNNING in
 * net/if.h, and its ioctls expect that struct.
 *
 * This header deliberately declares no struct of its own. Defining a second,
 * Linux-shaped struct ifreq would compile and then be passed to SIOCGIFFLAGS
 * and SIOCSIFADDR, which read the BSD layout. Code that reaches for the Linux
 * spelling ifr_ifrn.ifrn_name should use ifr_name instead, which is correct on
 * both systems: Linux defines it as a macro for exactly that member.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#ifndef SRSLAB_LINUX_IF_H
#define SRSLAB_LINUX_IF_H

#include <net/if.h>
#include <sys/socket.h>

#ifndef IFNAMSIZ
#define IFNAMSIZ IF_NAMESIZE
#endif

#endif
