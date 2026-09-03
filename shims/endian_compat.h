/**
 * Byte order macros for platforms without endian.h.
 *
 * Copyright 2013-2023 Software Radio Systems Limited
 * Darwin compatibility layer added 2026 by Andrei Gosman.
 *
 * This file is part of srsRAN. Same licence as the rest of the tree.
 *
 * glibc exposes htole16 and friends through endian.h, and pulls that in
 * transitively often enough that sources here use the macros without asking
 * for them. Darwin has no endian.h; the same conversions live in
 * libkern/OSByteOrder.h under different names.
 */

#ifndef SRSRAN_ENDIAN_COMPAT_H
#define SRSRAN_ENDIAN_COMPAT_H

#ifdef __APPLE__

#include <libkern/OSByteOrder.h>

#define htole16(x) OSSwapHostToLittleInt16(x)
#define htole32(x) OSSwapHostToLittleInt32(x)
#define htole64(x) OSSwapHostToLittleInt64(x)
#define le16toh(x) OSSwapLittleToHostInt16(x)
#define le32toh(x) OSSwapLittleToHostInt32(x)
#define le64toh(x) OSSwapLittleToHostInt64(x)

#define htobe16(x) OSSwapHostToBigInt16(x)
#define htobe32(x) OSSwapHostToBigInt32(x)
#define htobe64(x) OSSwapHostToBigInt64(x)
#define be16toh(x) OSSwapBigToHostInt16(x)
#define be32toh(x) OSSwapBigToHostInt32(x)
#define be64toh(x) OSSwapBigToHostInt64(x)

#else

#include <endian.h>

#endif /* __APPLE__ */

#endif /* SRSRAN_ENDIAN_COMPAT_H */
