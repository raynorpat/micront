"""harness.py -- host-side packet harness for the MicroNT IP stack.

This is the send/receive side of the IPSTACK-HARDENING §5 test harness.
It drives the guest's NIC directly over QEMU's socket netdev (see
qlink.py) -- once `boot.sh --net-harness PORT` is up, the harness *is*
the guest's entire network.

It provides the minimum a guest needs to come up and be talked to:

  * a DHCP server (dhcpd.py) so the guest's boot-time client gets a
    lease -- SLIRP's built-in DHCP is gone with --net-harness;
  * an ARP responder so the guest can resolve its gateway and peers;
  * an ICMP echo responder so `ping` from the guest works.

On top of that base it exposes a frame-level API -- `send_ip`,
`pump`, observer callbacks -- that per-finding reproducers (H-012 SYN
flood, etc.) build on.

Run standalone to bring a guest up and idle:

    python3 harness.py --port 5555

scapy builds and parses every packet; this harness owns the transport
and the responder logic.
"""

import argparse
import sys
import time

from scapy.all import ARP, DHCP, Ether, ICMP, IP, TCP, UDP, BOOTP

from dhcpd import DhcpServer
from qlink import QLink, QLinkError

# The harness's own L2/L3 identity.  The guest's MAC is learned from the
# first frame it sends, so only the harness side is fixed here.
HARNESS_MAC = "52:55:00:00:02:02"   # locally-administered; != QEMU guest default
HARNESS_IP  = "10.0.2.2"            # also the gateway the guest is leased
GUEST_IP    = "10.0.2.15"           # the address the harness leases the guest
NETMASK     = "255.255.255.0"
BROADCAST_MAC = "ff:ff:ff:ff:ff:ff"


def _now():
    return time.strftime("%H:%M:%S")


class Harness:
    """The host side of the guest's network: transport + base responders."""

    def __init__(self, port, host="127.0.0.1", verbose=True):
        self.link = QLink(port, host)
        self.verbose = verbose

        self.harness_mac = HARNESS_MAC
        self.harness_ip  = HARNESS_IP
        self.guest_ip    = GUEST_IP

        # Learned at runtime.
        self.guest_mac = None       # set from the first frame the guest sends
        self.guest_up  = False      # set once a DHCP ACK has been sent

        self.dhcp = DhcpServer(server_mac=self.harness_mac,
                               server_ip=self.harness_ip,
                               guest_ip=self.guest_ip, netmask=NETMASK)

        # Observer callbacks: every received (parsed) frame is offered to
        # each, so a reproducer can watch traffic without owning the
        # pump loop.  Signature: fn(scapy_packet) -> None.
        self.observers = []

        # Counters -- a coarse oracle and a sanity check on the run.
        self.stats = {"rx": 0, "tx": 0, "arp": 0, "dhcp": 0, "icmp": 0}

    # -- lifecycle ----------------------------------------------------------

    def connect(self, timeout=30.0):
        self.log("connecting to QEMU netdev on %s:%d ..."
                 % (self.link.host, self.link.port))
        self.link.connect(timeout=timeout)
        self.log("connected -- harness is now the guest's network")

    def close(self):
        self.link.close()

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, *exc):
        self.close()

    def log(self, msg):
        if self.verbose:
            print("[%s] %s" % (_now(), msg), flush=True)

    # -- frame I/O ----------------------------------------------------------

    def _send(self, pkt):
        """Send a scapy frame, filling in the harness source MAC."""
        if Ether not in pkt:
            raise ValueError("frame has no Ethernet layer")
        if pkt[Ether].src in (None, "00:00:00:00:00:00"):
            pkt[Ether].src = self.harness_mac
        self.link.send_frame(bytes(pkt))
        self.stats["tx"] += 1

    def send_ip(self, ip_pkt):
        """Wrap an IP packet for the guest and send it.

        The guest MAC must already be known (it is, after bring-up).
        scapy recomputes IP/L4 checksums when the frame is serialised."""
        if self.guest_mac is None:
            raise QLinkError("guest MAC not yet known -- bring the guest up first")
        self._send(Ether(src=self.harness_mac, dst=self.guest_mac) / ip_pkt)

    def pump(self, timeout=1.0):
        """Receive one frame, run the base responders, return the parsed
        packet (or None on timeout).

        Every received frame is offered to the registered observers
        before the base responders run, so a reproducer sees all traffic
        including TCP the harness does not otherwise touch."""
        frame = self.link.recv_frame(timeout=timeout)
        if frame is None:
            return None
        self.stats["rx"] += 1
        pkt = Ether(frame)

        # Learn the guest's MAC from the first frame it emits.
        if self.guest_mac is None and pkt.src != self.harness_mac:
            self.guest_mac = pkt.src
            self.log("learned guest MAC %s" % self.guest_mac)

        for obs in self.observers:
            obs(pkt)

        self._dispatch(pkt)
        return pkt

    # -- base responders ----------------------------------------------------

    def _dispatch(self, pkt):
        if ARP in pkt:
            self._handle_arp(pkt)
        elif BOOTP in pkt and DHCP in pkt:
            self._handle_dhcp(pkt)
        elif ICMP in pkt:
            self._handle_icmp(pkt)

    def _handle_arp(self, pkt):
        arp = pkt[ARP]
        if arp.op != 1:                         # only answer who-has requests
            return
        # Never answer for the guest's own address (that would look like
        # an address conflict) or for the unspecified probe source.
        if arp.pdst == self.guest_ip or arp.psrc == "0.0.0.0":
            return
        # Proxy-ARP everything else: the harness is the whole network, so
        # every address the guest asks for resolves to the harness MAC.
        reply = (Ether(src=self.harness_mac, dst=pkt.src) /
                 ARP(op=2, hwsrc=self.harness_mac, psrc=arp.pdst,
                     hwdst=arp.hwsrc, pdst=arp.psrc))
        self._send(reply)
        self.stats["arp"] += 1
        self.log("ARP who-has %s -> harness %s" % (arp.pdst, self.harness_mac))

    def _handle_dhcp(self, pkt):
        mtype = DhcpServer._msg_type(pkt[DHCP])
        reply = self.dhcp.handle(pkt)
        if reply is None:
            return
        self._send(reply)
        self.stats["dhcp"] += 1
        reply_type = DhcpServer._msg_type(reply[DHCP])
        self.log("DHCP %s -> %s (guest %s)"
                 % (DhcpServer.describe(mtype),
                    DhcpServer.describe(reply_type), self.guest_ip))
        if reply_type == 5:                     # ACK -- the guest now has its IP
            self.guest_up = True

    def _handle_icmp(self, pkt):
        icmp = pkt[ICMP]
        if icmp.type != 8:                      # only answer echo requests
            return
        ip = pkt[IP]
        reply = (Ether(src=self.harness_mac, dst=pkt.src) /
                 IP(src=ip.dst, dst=ip.src) /
                 ICMP(type=0, id=icmp.id, seq=icmp.seq) /
                 bytes(icmp.payload))
        self._send(reply)
        self.stats["icmp"] += 1
        self.log("ICMP echo %s -> reply" % ip.src)

    # -- bring-up -----------------------------------------------------------

    def bring_up(self, timeout=60.0):
        """Pump frames until the guest has completed DHCP.

        Returns the leased guest IP.  Raises QLinkError on timeout."""
        self.log("waiting for the guest to come up (DHCP) ...")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.pump(timeout=1.0)
            if self.guest_up:
                self.log("guest is up: %s leased to %s"
                         % (self.guest_ip, self.guest_mac))
                return self.guest_ip
        raise QLinkError("guest did not complete DHCP within %gs" % timeout)

    def idle(self):
        """Service ARP / ICMP / DHCP-renew forever (until interrupted)."""
        self.log("idling -- servicing ARP / ICMP / DHCP (Ctrl-C to stop)")
        try:
            while True:
                self.pump(timeout=1.0)
        except KeyboardInterrupt:
            self.log("stopped; stats: %s" % self.stats)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, required=True,
                    help="TCP port QEMU's socket netdev is listening on "
                         "(boot.sh --net-harness PORT)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--connect-timeout", type=float, default=30.0,
                    help="seconds to keep retrying the connect to QEMU")
    ap.add_argument("--bring-up-timeout", type=float, default=60.0,
                    help="seconds to wait for the guest's DHCP to complete")
    args = ap.parse_args(argv)

    h = Harness(args.port, host=args.host)
    try:
        h.connect(timeout=args.connect_timeout)
    except QLinkError as e:
        print("harness: %s" % e, file=sys.stderr)
        return 1
    try:
        h.bring_up(timeout=args.bring_up_timeout)
    except QLinkError as e:
        print("harness: %s" % e, file=sys.stderr)
        h.close()
        return 1
    h.idle()
    h.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
