"""dhcpd.py -- a minimal DHCP server for the netharness.

`boot.sh --net-harness` turns off QEMU's user-mode SLIRP, and SLIRP is
what normally answers the guest's boot-time DHCP.  This server takes its
place: it leases the guest one fixed address and nothing more.

It is deliberately single-client and stateless.  The harness presents a
one-guest network, so there is no address pool to manage -- DISCOVER and
REQUEST both get the same hard-coded lease.  Keeping the leased subnet at
10.0.2.0/24 with guest 10.0.2.15 / gateway 10.0.2.2 matches what SLIRP
used to hand out, so the in-guest DHCP regression suite (test/dhcp.lua)
stays valid against the harness.

scapy builds and parses the BOOTP/DHCP wire format; this module only
decides what to put in the reply.
"""

from scapy.all import BOOTP, DHCP, Ether, IP, UDP

# DHCP message types (RFC 2132 option 53).
DHCP_DISCOVER = 1
DHCP_OFFER    = 2
DHCP_REQUEST  = 3
DHCP_DECLINE  = 4
DHCP_ACK      = 5
DHCP_NAK      = 6

_TYPE_NAME = {DHCP_DISCOVER: "DISCOVER", DHCP_OFFER: "OFFER",
              DHCP_REQUEST: "REQUEST", DHCP_DECLINE: "DECLINE",
              DHCP_ACK: "ACK", DHCP_NAK: "NAK"}

# scapy keeps option 53 as a name string ("discover") on a packet built
# in memory but as the wire integer (1) once the packet has been
# serialised and re-parsed.  This maps the names back so the server
# behaves the same either way.
_TYPE_FROM_NAME = {"discover": DHCP_DISCOVER, "offer": DHCP_OFFER,
                   "request": DHCP_REQUEST, "decline": DHCP_DECLINE,
                   "ack": DHCP_ACK, "nak": DHCP_NAK,
                   "release": 7, "inform": 8}

_BOOTP_BROADCAST = 0x8000       # BOOTP flags: reply must be broadcast


class DhcpServer:
    """Leases one fixed address to the guest.  Stateless across requests."""

    def __init__(self, server_mac, server_ip="10.0.2.2",
                 guest_ip="10.0.2.15", netmask="255.255.255.0",
                 router="10.0.2.2", dns="10.0.2.2", lease_time=86400):
        self.server_mac = server_mac
        self.server_ip  = server_ip
        self.guest_ip   = guest_ip
        self.netmask    = netmask
        self.router     = router
        self.dns        = dns
        self.lease_time = lease_time

    def handle(self, pkt):
        """Given a received scapy Ether frame, return a reply frame or None.

        Returns None for anything that is not a DHCP DISCOVER or REQUEST
        the harness should answer."""
        if BOOTP not in pkt or DHCP not in pkt:
            return None
        mtype = self._msg_type(pkt[DHCP])
        if mtype == DHCP_DISCOVER:
            return self._reply(pkt, DHCP_OFFER)
        if mtype == DHCP_REQUEST:
            return self._reply(pkt, DHCP_ACK)
        # DECLINE / RELEASE / INFORM: nothing to do for a single fixed lease.
        return None

    @staticmethod
    def _msg_type(dhcp):
        """Pull option 53 (message type) out of a scapy DHCP layer.

        Returns the integer type, coercing scapy's name-string form
        (present on an in-memory packet) to the wire integer."""
        for opt in dhcp.options:
            if isinstance(opt, tuple) and opt[0] == "message-type":
                val = opt[1]
                if isinstance(val, str):
                    return _TYPE_FROM_NAME.get(val)
                return val
        return None

    def _reply(self, req, mtype):
        """Build the OFFER / ACK frame for a DISCOVER / REQUEST."""
        bootp = req[BOOTP]
        guest_mac = req[Ether].src

        # Honour the BOOTP broadcast flag: a client that cannot yet
        # receive unicast (no IP configured) asks for a broadcast reply.
        broadcast = bool(bootp.flags & _BOOTP_BROADCAST)
        dst_mac = "ff:ff:ff:ff:ff:ff" if broadcast else guest_mac
        dst_ip  = "255.255.255.255"   if broadcast else self.guest_ip

        frame = (
            Ether(src=self.server_mac, dst=dst_mac) /
            IP(src=self.server_ip, dst=dst_ip) /
            UDP(sport=67, dport=68) /
            BOOTP(op=2, xid=bootp.xid, flags=bootp.flags,
                  yiaddr=self.guest_ip, siaddr=self.server_ip,
                  chaddr=bootp.chaddr) /
            DHCP(options=[
                ("message-type", mtype),
                ("server_id",   self.server_ip),
                ("lease_time",  self.lease_time),
                ("subnet_mask", self.netmask),
                ("router",      self.router),
                ("name_server", self.dns),
                "end",
            ])
        )
        return frame

    @staticmethod
    def describe(mtype):
        """Human-readable name for a DHCP message type."""
        return _TYPE_NAME.get(mtype, "type%s" % mtype)
