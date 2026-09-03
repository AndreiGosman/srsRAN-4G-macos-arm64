/*
 * The TUN device flags and ioctl from Linux.
 *
 * Darwin has no /dev/net/tun and no TUNSETIFF. Its equivalent is utun, opened
 * as a PF_SYSTEM control socket, where the kernel picks the interface name and
 * every packet carries a four byte address family prefix. The values below
 * exist so that shared code still compiles; the Darwin path does not issue
 * TUNSETIFF.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#ifndef SRSLAB_LINUX_IF_TUN_H
#define SRSLAB_LINUX_IF_TUN_H

#include <sys/ioctl.h>

#define IFF_TUN   0x0001
#define IFF_TAP   0x0002
#define IFF_NO_PI 0x1000

#define TUNSETIFF _IOW('T', 202, int)

#endif
