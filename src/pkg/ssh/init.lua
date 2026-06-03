-- ssh — minimal SSH-2 for MicroNT (feasibility/learning).
--
-- A deliberately tiny SSH-2 implementation around a single cipher suite:
--
--   KEX       curve25519-sha256            (X25519 + SHA-256)
--   host key  ssh-ed25519                  (Ed25519, → SHA-512)
--   cipher    chacha20-poly1305@openssh.com  (AEAD — MAC is implicit)
--
-- See docs-wip/MICRONT-SSH-TODO.md for the rationale and the build order.
-- wolfSSH (stuff/wolfssh) is the protocol-choreography reference; OpenSSH's
-- cipher-chachapoly.c / packet.c is the reference for the cipher framing.
--
-- Layering (bottom-up):
--
--   crypto   FFI binding to djbcrypt.dll — the DJB primitive set, pure
--            functions; entropy stays in Lua (nt.dll.rng).
--   wire     SSH binary wire types (RFC 4251 §5): byte/uint32/string/
--            mpint/name-list, with a cursor Reader and an accumulator Buf.
--   consts   message numbers + algorithm name strings + reason codes.
--   packet   binary packet protocol (RFC 4253 §6): the cipher seam lives
--            here — a cipher object owns seal/read framing. `none` (plain)
--            ships now; the chacha20-poly1305 AEAD cipher rides the seam.
--   xport    transport over an nt.net.afd socket: version-string exchange
--            + buffered read-exactly-N / write.
--
--   kex      KEXINIT negotiation + curve25519 ECDH + exchange hash + keys
--   userauth publickey (ssh-ed25519)
--   channel  session-channel message builders
--   conn     one connection as an event-driven reactor (the I/O composition)
--   sessions what runs on the channel: a launched program / line REPL / echo
--
-- This is a LIBRARY: it knows SSH over a given socket and nothing about how
-- the host gets an IP or which program is the shell.  Listening, network
-- bring-up and shell policy belong to the deployment (see pkg/sshd.lua).
--
-- Public surface for building a server:
--   ssh.serve(sock, { hostkey, session, authorize })  -- run one connection
--   ssh.sessions.shell{ exe = ... }                   -- attach a program
--
-- Nothing here holds module-local connection state: sequence numbers,
-- cipher keys and channel tables all live on per-connection instances, so
-- the package is reentrant across lua_States (cf. the pkg/nt pure-library
-- discipline).

local M = {
    crypto   = require('ssh.crypto'),
    wire     = require('ssh.wire'),
    consts   = require('ssh.consts'),
    packet   = require('ssh.packet'),
    cipoly   = require('ssh.cipoly'),
    kex      = require('ssh.kex'),
    userauth = require('ssh.userauth'),
    channel  = require('ssh.channel'),
    xport    = require('ssh.xport'),
    conn     = require('ssh.conn'),
    sessions = require('ssh.sessions'),
}

M.serve = M.conn.serve              -- ssh.serve(sock, opts) — run one connection

M.VERSION_ID = "SSH-2.0-MicroNT_0.1"

return M
