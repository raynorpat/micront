"""qlink.py -- transport to QEMU's socket netdev.

`boot.sh --net-harness PORT` swaps the guest's NIC backend from user-mode
SLIRP to

    -netdev socket,id=n0,listen=127.0.0.1:PORT

so QEMU's virtio-net device hangs off a plain TCP socket instead of the
SLIRP NAT.  QEMU listens; this harness connects.  Once connected, the
harness *is* the guest's entire network -- every frame the guest emits
arrives here and nothing reaches the guest except what the harness sends.

Wire framing
------------
QEMU's socket netdev (net/socket.c) prefixes every Ethernet frame, both
directions, with a 4-byte big-endian length:

    [ uint32 be: len ][ <len> bytes: raw Ethernet frame ]

TCP is a byte stream, so a single read() may return a partial header, a
partial frame, or several frames; `recv_frame` reframes against an
internal buffer.  The frame bytes themselves are opaque here -- scapy
(`Ether(raw)` / `bytes(pkt)`) handles their contents in the harness.

This module has no scapy dependency: it moves bytes, nothing more.
"""

import select
import socket
import struct
import time

# QEMU's `listen=` socket only accepts a peer once the guest's netdev is
# up, and the guest takes a while to boot.  The harness therefore retries
# the connect rather than failing on the first refused attempt.
_CONNECT_RETRY_DELAY = 0.25     # seconds between connect attempts


class QLinkError(Exception):
    """Transport fault -- connect timed out, or the peer closed the link."""


class QLink:
    """A framed Ethernet link to the guest over QEMU's socket netdev."""

    def __init__(self, port, host="127.0.0.1"):
        self.host = host
        self.port = port
        self.sock = None
        self._buf = b""             # unconsumed stream bytes (reframing)

    # -- connection ---------------------------------------------------------

    def connect(self, timeout=30.0):
        """Connect to QEMU's listen socket, retrying until `timeout`.

        QEMU may not have opened the listener yet (boot.sh still starting)
        or the guest's netdev may not be up; both show as a refused
        connect.  Retry until the deadline."""
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            try:
                s.connect((self.host, self.port))
            except OSError as e:
                last = e
                s.close()
                time.sleep(_CONNECT_RETRY_DELAY)
                continue
            # Disable Nagle: the harness sends small frames and wants the
            # guest to see each one without coalescing latency.
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self.sock = s
            return
        raise QLinkError("could not connect to QEMU netdev at %s:%d (%s)"
                         % (self.host, self.port, last))

    def close(self):
        if self.sock is not None:
            self.sock.close()
            self.sock = None

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, *exc):
        self.close()

    # -- frame I/O ----------------------------------------------------------

    def send_frame(self, frame):
        """Send one raw Ethernet frame (bytes) to the guest."""
        if self.sock is None:
            raise QLinkError("send on a closed link")
        self.sock.sendall(struct.pack("!I", len(frame)) + bytes(frame))

    def recv_frame(self, timeout=None):
        """Receive one raw Ethernet frame, or None if `timeout` elapses.

        `timeout=None` blocks indefinitely; `timeout=0` polls.  Raises
        QLinkError if the guest side of the link closes."""
        if self.sock is None:
            raise QLinkError("recv on a closed link")
        deadline = None if timeout is None else time.monotonic() + timeout

        while True:
            frame = self._take_frame()
            if frame is not None:
                return frame

            # Need more bytes.  Wait for the socket within the deadline.
            if deadline is None:
                wait = None
            else:
                wait = deadline - time.monotonic()
                if wait <= 0:
                    return None
            ready, _, _ = select.select([self.sock], [], [], wait)
            if not ready:
                return None
            chunk = self.sock.recv(65536)
            if not chunk:
                raise QLinkError("QEMU closed the netdev link")
            self._buf += chunk

    def _take_frame(self):
        """Pull one complete frame out of the stream buffer, or None."""
        if len(self._buf) < 4:
            return None
        (length,) = struct.unpack("!I", self._buf[:4])
        if len(self._buf) < 4 + length:
            return None
        frame = self._buf[4:4 + length]
        self._buf = self._buf[4 + length:]
        return frame

    def drain(self):
        """Discard any frames the guest has already queued.

        Useful between test phases -- e.g. after bring-up, before a
        reproducer run -- so stale traffic doesn't confuse a fresh
        observation."""
        n = 0
        while self.recv_frame(timeout=0) is not None:
            n += 1
        return n
