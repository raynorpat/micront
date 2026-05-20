# netharness — host-side packet harness

The send/receive side of the IP-stack hardening test harness
(`docs-wip/IPSTACK-HARDENING.md` §5). It drives the guest's NIC
directly: with `boot.sh --net-harness`, QEMU's user-mode SLIRP backend
is replaced by a socket netdev, and this harness — running on the host —
becomes the guest's entire network. No SLIRP means deterministic,
point-to-point traffic: the guest sees exactly the frames the harness
sends and nothing else.

Pure host-side Python. scapy builds and parses packets; the harness owns
the transport and the responder logic.

## Layout

| file | role |
|---|---|
| `qlink.py` | transport — framed Ethernet over QEMU's socket netdev |
| `dhcpd.py` | minimal single-lease DHCP server (SLIRP's is gone) |
| `harness.py` | orchestrator — ARP / ICMP / DHCP responders, frame API, CLI |
| `selftest.py` | offline checks for the above (no QEMU, no guest) |

Per-finding reproducers (H-012 SYN flood, …) build on `harness.Harness`.

## Requirements

- `python3-scapy`
- QEMU with a `socket` netdev (any recent `qemu-system-x86_64`)

No root: the socket netdev is a plain TCP socket, so there is no tap
device and no `CAP_NET_ADMIN`.

## Offline self-test

Logic checks with no boot — run after editing the harness:

```sh
python3 src/tools/netharness/selftest.py
```

## Bring-up (integration)

The guest must run its DHCP client, so boot the selftest profile, which
does. In one shell:

```sh
make -C src selftest NET_HARNESS=5555
```

QEMU comes up and listens on `127.0.0.1:5555`. In another shell:

```sh
python3 src/tools/netharness/harness.py --port 5555
```

The harness connects, serves the guest's DHCP (DISCOVER→OFFER,
REQUEST→ACK, leasing `10.0.2.15`), then idles answering ARP / ICMP. The
guest's in-tree DHCP suite (`test/dhcp.lua`) runs against the harness
and is the bring-up oracle: if it passes, the transport works end to
end.

`--netdump` still works alongside `--net-harness` — `filter-dump`
attaches to the netdev by id, so every frame is captured to
`vionet.pcap` regardless of backend.
