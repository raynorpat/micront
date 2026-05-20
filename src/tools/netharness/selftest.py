"""selftest.py -- offline checks for the netharness logic.

Exercises the packet-handling logic with no QEMU and no guest: the
qlink stream reframer, the DHCP server, and the harness's ARP / ICMP /
DHCP responders.  Run it after changing any of those before spending a
boot on an integration test.

    python3 selftest.py

Integration -- the harness actually driving a booted guest -- is not
covered here; that needs `boot.sh --net-harness` and a guest.
"""

import struct
import sys

from scapy.all import ARP, BOOTP, DHCP, Ether, ICMP, IP, UDP, conf

import harness as H
from dhcpd import DhcpServer
from qlink import QLink

conf.verb = 0

GUEST_MAC = "52:54:00:12:34:56"     # QEMU's default virtio-net guest MAC


def check(name, fn):
    try:
        fn()
    except AssertionError as e:
        print("FAIL  %s: %s" % (name, e))
        return False
    except Exception as e:                              # noqa: BLE001
        print("ERROR %s: %r" % (name, e))
        return False
    print("ok    %s" % name)
    return True


# -- qlink stream reframing -------------------------------------------------

def test_qlink_reframe():
    f1, f2 = b"FRAME-ONE", b"frame2!!"
    wire = (struct.pack("!I", len(f1)) + f1 +
            struct.pack("!I", len(f2)) + f2)

    # Fed one byte at a time, no frame surfaces until it is complete.
    q = QLink(0)
    out = []
    for b in wire:
        q._buf += bytes([b])
        fr = q._take_frame()
        if fr is not None:
            out.append(fr)
    assert out == [f1, f2], out

    # Fed all at once, both frames come back in order.
    q = QLink(0)
    q._buf = wire
    got = []
    while True:
        fr = q._take_frame()
        if fr is None:
            break
        got.append(fr)
    assert got == [f1, f2], got


# -- DHCP server ------------------------------------------------------------

def _discover(mtype="discover"):
    return (Ether(src=GUEST_MAC, dst="ff:ff:ff:ff:ff:ff") /
            IP(src="0.0.0.0", dst="255.255.255.255") /
            UDP(sport=68, dport=67) /
            BOOTP(op=1, xid=0xABCD,
                  chaddr=bytes.fromhex("525400123456") + b"\x00" * 10) /
            DHCP(options=[("message-type", mtype), "end"]))


def test_dhcp_offer_and_ack():
    srv = DhcpServer(server_mac=H.HARNESS_MAC)

    offer = srv.handle(_discover("discover"))
    assert offer is not None, "no reply to DISCOVER"
    assert offer[BOOTP].yiaddr == "10.0.2.15", offer[BOOTP].yiaddr
    assert offer[BOOTP].xid == 0xABCD, "xid not echoed"
    assert offer[Ether].dst == GUEST_MAC, "offer not unicast to guest"
    assert offer[UDP].sport == 67 and offer[UDP].dport == 68
    assert DhcpServer._msg_type(offer[DHCP]) == 2, "not an OFFER"

    ack = srv.handle(_discover("request"))
    assert DhcpServer._msg_type(ack[DHCP]) == 5, "REQUEST did not get an ACK"


def test_dhcp_wire_roundtrip():
    """The OFFER must survive serialise + re-parse intact."""
    srv = DhcpServer(server_mac=H.HARNESS_MAC)
    offer = srv.handle(_discover("discover"))
    rt = Ether(bytes(offer))
    assert rt[BOOTP].yiaddr == "10.0.2.15"
    assert DhcpServer._msg_type(rt[DHCP]) == 2
    opts = dict(o for o in rt[DHCP].options if isinstance(o, tuple))
    assert opts["server_id"] == "10.0.2.2", opts
    assert opts["router"] == "10.0.2.2", opts
    assert opts["subnet_mask"] == "255.255.255.0", opts


# -- harness responders -----------------------------------------------------

def _harness_with_capture():
    h = H.Harness(0, verbose=False)
    sent = []
    h._send = lambda p: sent.append(p)
    h.guest_mac = GUEST_MAC
    return h, sent


def test_arp_responder():
    h, sent = _harness_with_capture()
    h._dispatch(Ether(src=GUEST_MAC, dst="ff:ff:ff:ff:ff:ff") /
                ARP(op=1, hwsrc=GUEST_MAC, psrc="10.0.2.15", pdst="10.0.2.2"))
    assert sent, "no ARP reply"
    r = sent[-1][ARP]
    assert r.op == 2 and r.psrc == "10.0.2.2" and r.hwsrc == H.HARNESS_MAC


def test_arp_suppressed_for_guest_and_dad():
    h, sent = _harness_with_capture()
    # who-has the guest's own IP -- must not answer (looks like a conflict).
    h._dispatch(Ether(src=GUEST_MAC) /
                ARP(op=1, hwsrc=GUEST_MAC, psrc="10.0.2.15", pdst="10.0.2.15"))
    # duplicate-address-detection probe (psrc 0.0.0.0) -- must not answer.
    h._dispatch(Ether(src=GUEST_MAC) /
                ARP(op=1, hwsrc=GUEST_MAC, psrc="0.0.0.0", pdst="10.0.2.99"))
    assert not sent, "answered an ARP that should be suppressed"


def test_icmp_echo():
    h, sent = _harness_with_capture()
    h._dispatch(Ether(src=GUEST_MAC) / IP(src="10.0.2.15", dst="10.0.2.2") /
                ICMP(type=8, id=1, seq=7) / b"ping")
    r = sent[-1]
    assert r[ICMP].type == 0 and r[ICMP].seq == 7
    assert bytes(r[ICMP].payload) == b"ping"


def test_dhcp_drives_guest_up():
    h, sent = _harness_with_capture()
    h._dispatch(_discover("discover"))
    assert sent[-1][BOOTP].yiaddr == "10.0.2.15"
    assert h.guest_up is False, "guest_up set on OFFER"
    h._dispatch(_discover("request"))
    assert h.guest_up is True, "guest_up not set after ACK"


TESTS = [
    ("qlink reframing", test_qlink_reframe),
    ("dhcp offer + ack", test_dhcp_offer_and_ack),
    ("dhcp wire round-trip", test_dhcp_wire_roundtrip),
    ("arp responder", test_arp_responder),
    ("arp suppressed for guest IP / DAD", test_arp_suppressed_for_guest_and_dad),
    ("icmp echo responder", test_icmp_echo),
    ("dhcp drives guest_up", test_dhcp_drives_guest_up),
]


def main():
    ok = sum(check(name, fn) for name, fn in TESTS)
    total = len(TESTS)
    print("netharness selftest: %d/%d passed" % (ok, total))
    return 0 if ok == total else 1


if __name__ == "__main__":
    sys.exit(main())
