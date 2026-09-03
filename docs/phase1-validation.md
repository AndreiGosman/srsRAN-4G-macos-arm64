# Phase 1 validation

Log excerpts from the run of 2026-09-03 that closed Phase 1. Machine: MacBook
Pro M4, Darwin 25.5, Apple clang 21, srsRAN 4G at upstream `6bcbd9e5b`.

Nothing here uses a radio. Both ends exchange IQ samples over ZeroMQ on
localhost, so no signal is transmitted.

## Topology

```
srsepc  MME 127.0.0.1:36412 (SCTP)     SPGW GTP-U 127.0.1.100:2152     SGi utun6 172.16.0.1
srsenb  S1C 127.0.0.1:0     (SCTP)         GTP-U 127.0.1.1:2152        ZMQ tx 2000 rx 2101
srsue                                                                  ZMQ tx 2101 rx 2000
                                                                       GW  utun7 172.16.0.2
```

SCTP endpoints stay on 127.0.0.1 because usrsctp drops traffic addressed to a
loopback alias. GTP-U uses the aliases because it is plain UDP and both
processes bind port 2152.

## S1AP setup

eNB:

```
[S1AP] SCTP socket established with MME
[S1AP] Proc "MME Connection" - S1 setup request sent. Waiting for response.
[S1AP] Proc "MME Connection" - S1Setup procedure completed successfully
```

EPC, 0.6 ms later:

```
Received S1 Setup Request.
S1 Setup Request - eNB Name: srsenb01, eNB id: 0x19b
S1 Setup Request - MCC:001, MNC:01
S1 Setup Request - TAC 7, B-PLMN 0xf110
S1 Setup Request - Paging DRX v128
[S1AP] Adding new eNB context. eNB ID 411
Sending S1 Setup Response
```

## Cell search and RRC

```
Found Cell:  Mode=FDD, PCI=1, PRB=25, Ports=1, CP=Normal, CFO=0.2 KHz
Found PLMN:  Id=00101, TAC=7
[NAS] Selecting Home PLMN Id=00101
[NAS] Requesting IMSI attach (IMSI=001010000000001)
Random Access Transmission: seq=47, tti=501, ra-rnti=0x2
RRC Connected
Random Access Complete.     c-rnti=0x46, ta=9
```

## NAS attach

UE:

```
[NAS] Received Authentication Request
[NAS] Sending Authentication Response
[NAS] Received Security Mode Command ksi: 0, eea: EEA0, eia: 128-EIA1
[NAS] Sending Security Mode Complete
[RRC] Received Security Mode Command eea: EEA0, eia: 128-EIA2
[NAS] Received Attach Accept
[NAS] Network attach successful. APN: srsapn, IP: 172.16.0.2
[NAS] Sending Attach Complete
```

EPC:

```
[SPGW GTPC] SPGW Received Create Session Request
[SPGW GTPC] Sending Create Session Response
[MME GTPC]  Create Session Response -- SPGW control TEID 1
[MME GTPC]  Create Session Response -- SPGW S1-U Address: 127.0.1.100
[NAS]       Packing Attach Accept
[NAS]       Attach Accept -- MCC 0xf001, MNC 0xff01
[S1AP]      UL NAS: Received Attach Complete
[SPGW GTPC] IMSI: 001010000000001, UE IP: 172.16.0.2
[GTPU]      Downlink eNB addr 127.0.1.1, U-TEID 0x1
```

`MCC 0xf001, MNC 0xff01` is the BCD encoding of 001 and 01 with the standard
filler nibbles, not corruption.

## Interfaces

```
utun6: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
	inet 172.16.0.1 --> 0.0.0.0 netmask 0xffff0000
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
	inet 172.16.0.2 --> 0.0.0.0 netmask 0xffff0000
```

Both names are chosen by the kernel. The configured `tun_dev_name` and
`sgi_if_name` are reported and ignored, and the number varies between runs
depending on what else holds a utun.

## Routes

```
Destination        Gateway            Flags               Netif
172.16.0.1         utun7              UHS                 utun7
172.16.0.2         utun6              UHS                 utun6
```

Crossed on purpose. Both addresses are local to this machine, so without the
crossing the kernel answers on the loopback and the test proves nothing. On
Linux the upstream tutorial avoids the question with network namespaces, which
macOS does not have.

## Ping

```
PING 172.16.0.1 (172.16.0.1): 56 data bytes
64 bytes from 172.16.0.1: icmp_seq=0 ttl=64 time=38.474 ms
64 bytes from 172.16.0.1: icmp_seq=1 ttl=64 time=25.100 ms
64 bytes from 172.16.0.1: icmp_seq=2 ttl=64 time=31.506 ms
64 bytes from 172.16.0.1: icmp_seq=3 ttl=64 time=36.701 ms
64 bytes from 172.16.0.1: icmp_seq=4 ttl=64 time=22.985 ms

5 packets transmitted, 5 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 22.985/30.953/38.474/6.126 ms
```

Corroborated in the UE log, which is what rules out a loopback shortcut:

```
[GW] TX PDU
[GW] RX PDU. Stack latency: 4 us
```

And zero occurrences of `IPv6 not supported yet` in the EPC log, which is the
signature of the four-byte utun prefix being left in the buffer.

## Reading the round trip time

Thirty milliseconds is not a slow network. The packet crosses a complete LTE
stack twice: scheduling request, uplink grant, HARQ, and a ZeroMQ transport
carrying 11.52 Msps between two processes that must stay in step. The 4
microsecond stack latency srsue reports is the time inside srsue itself, so
nearly all of the 30 ms is the radio protocol.

The first ping after an idle period can time out legitimately. The UE releases
its bearer and has to request service again; the log says `UE does not have
service, waiting for NAS service request` when that happens. Use five packets.
