# Patch 026: the lte_cell_measure example

Added 2026-09-22. This patch brings one example program into the series; it
changes nothing in the port itself.

## Where it comes from

Fork `lmesserStep/srsRAN_4G`, branch `lte-cell-measure`, commit
`8fdbb82698d9fada9f250f392b80f9e3bb481183` of 2026-03-08, "Add LTE cell
measurement utility with JSON output". That commit adds
`lib/examples/lte_cell_measure.c` (1220 lines) and seven lines in
`lib/examples/CMakeLists.txt`, and nothing else. The program links
`srsran_phy`, `srsran_common` and `srsran_rf` only, so no dependency is added.

It scans a range of EARFCNs in one band, synchronises to each cell it finds
and prints one JSON object per measurement on stdout: PCI, RSRP, RSRQ, SNR,
CFO and frame type. A PCI can be given to measure one cell only. TDD Band 48
is supported.

## Why a patch on this series rather than a port of the fork

The fork base is `1fab3df8` (2025-10-22), three months older than the
`6bcbd9e5` this series targets. Replaying the Darwin patches on the fork base
was tried first and failed on seven of them. `lib/examples/CMakeLists.txt` is
byte-identical (md5 `e32948b61c0aebcd39dc47300ecc65dc`) at the fork base, at
`6bcbd9e5` and after patches 001 to 025, so the small CMake change applies on
top of the series without conflict. The two files were taken out of the fork
with `git show`; the fork commit itself is not cherry-picked.

The patch is self-contained: the CMake hunk plus the new file, generated with
`git diff` after `git add -N`, so the series still replays on a clean checkout.
It applies with Apple `patch 2.0` as `scripts/install.sh` runs it.

## Deviation from the fork

The fork commit also registers `add_executable(cell_monitor cell_monitor.c)`,
but `cell_monitor.c` exists nowhere in the fork tree, so that target cannot
build. Both `cell_monitor` lines are dropped. Only `lte_cell_measure` is
registered, right after `cell_search`.

## What was measured

2026-09-22, Bucharest. LibreSDR B220 mini (bkerler B210 bitstream, USB 3),
SIRIO SO 4G LTE-M3 antenna on RX A, one 45 s run per cell, all with
`-g 60 -w 15 -a master_clock_rate=11.52e6`, PCI targeted. Every run found the
target PCI on the first scan and produced 62 valid JSON lines with zero
`measure_failed`, zero crashes and zero `wait_for_ack` errors. Medians:

| EARFCN | Band | PCI | PLMN (from SIB1, 2026-09-04) | RSRP dBm | RSRQ dB | SNR dB |
|---|---|---|---|---|---|---|
| 1256 | 3 | 243 | 22601 Vodafone | -76.6 | -5.2 | 17.5 |
| 1600 | 3 | 93 | 22610 Orange | -78.8 | -9.4 | 16.5 |
| 525 | 1 | 480 | 22605 Digi | -85.2 | -8.3 | 10.8 |
| 1400 | 3 | 120 | 22601 Vodafone | -76.2 | -4.9 | 18.0 |
| 3350 | 7 | 339 | 22605 Digi | -95.3 | -8.7 | 12.0 |

RSRP spans -96.3 to -71.4 dBm and RSRQ -17.9 to -4.0 dB across all samples.
CFO sits at 2.3 to 3.5 kHz, rising with frequency, which is the LibreSDR
TCXO at roughly 1.3 ppm. The raw JSON is not in this repository.

## Things to know before using it on a LibreSDR

Bandwidth stops at 15 PRB. `rf_uhd_imp.cc` asks for a master clock of
4 x sample rate whenever the current clock is not an integer multiple of the
sample rate. At the 11.52 MHz that patch 025 sets, 6 PRB (1.92 Msps, ratio 6)
and 15 PRB (3.84 Msps, ratio 3) keep the clock; 25 PRB (7.68 Msps, ratio 1.5)
would request 30.72 MHz, which the B220 bitstream does not survive. Always pass
`-w 6` or `-w 15`. One experiment with `-w 25 -a master_clock_rate=7.68e6`
streamed 39 measurements, but UHD moved the clock to 23.04 MHz during the scan
and the process ignored SIGINT and had to be killed. Treat 25 PRB as
unsupported until that is understood.

A single EARFCN needs `-e N+1`. `srsran_band_get_fd_band()` in
`lib/src/phy/common/phy_common.c` computes `end - start` channels, so
`-s 1256 -e 1256` yields "No EARFCNs for band 3". The default end and the
range-check message both imply an inclusive end, so with the default range the
last EARFCN of every band is never scanned either. This is upstream code,
present in `srsran/srsRAN_4G` master as of 2026-09-10, and a candidate for a
separate pull request. No patch in this series changes it.

If your prefix carries an older `libsrsran_rf_uhd.dylib` than the one you just
built, the 11.52 MHz default from patch 025 is not in effect and UHD asks for
23.04 MHz. Reinstall, or pass `-a master_clock_rate=11.52e6` as above.

## Defects in the utility itself, not fixed here

These belong to the fork and are recorded so nobody rediscovers them.

RSRP calibration is a fixed offset. `rsrp = measured - rx_gain +
B210_CAL_OFFSET` with the offset hard-coded at -65.0 dB. The same cell minutes
apart read -76.6 dBm at 15 PRB and -71.7 dBm at 25 PRB, a 5 dB step that
follows the decimation, not the channel. Compare absolute values only between
runs with the same `-w`.

With `-w` the utility skips the MIB decode and writes `ports=2` into every
JSON line (source comment: "Assume 2 ports for TDD CBRS"). The field is a stub
whenever the bandwidth is forced.

`build_rf_args()` hard-codes `type=b200,num_recv_frames=512,recv_frame_size=8200`
and appends whatever `-a` carries. `-a` therefore works, but the device type
cannot be changed through it; use `-d` for a different RF driver.

None of this has been reported to the fork author yet.
