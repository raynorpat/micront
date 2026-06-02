-- ssh.consts — SSH-2 message numbers, reason codes, and the algorithm
-- name strings for MicroNT's single supported suite.
--
-- Message numbers: RFC 4253 (transport) / 4252 (userauth) / 4254
-- (connection).  The 30/31 range is KEX-method-specific; for the
-- curve25519/ECDH method they are KEX_ECDH_INIT / KEX_ECDH_REPLY, and
-- 60 in userauth is method-specific (PK_OK for publickey).

local M = {}

M.msg = {
    -- transport layer
    DISCONNECT                = 1,
    IGNORE                    = 2,
    UNIMPLEMENTED             = 3,
    DEBUG                     = 4,
    SERVICE_REQUEST           = 5,
    SERVICE_ACCEPT            = 6,
    KEXINIT                   = 20,
    NEWKEYS                   = 21,
    -- KEX-method-specific (curve25519 / ECDH)
    KEX_ECDH_INIT             = 30,
    KEX_ECDH_REPLY            = 31,
    -- userauth layer
    USERAUTH_REQUEST          = 50,
    USERAUTH_FAILURE          = 51,
    USERAUTH_SUCCESS          = 52,
    USERAUTH_BANNER           = 53,
    USERAUTH_PK_OK            = 60,   -- method-specific (publickey)
    -- connection layer
    GLOBAL_REQUEST            = 80,
    REQUEST_SUCCESS           = 81,
    REQUEST_FAILURE           = 82,
    CHANNEL_OPEN              = 90,
    CHANNEL_OPEN_CONFIRMATION = 91,
    CHANNEL_OPEN_FAILURE      = 92,
    CHANNEL_WINDOW_ADJUST     = 93,
    CHANNEL_DATA              = 94,
    CHANNEL_EXTENDED_DATA     = 95,
    CHANNEL_EOF               = 96,
    CHANNEL_CLOSE             = 97,
    CHANNEL_REQUEST           = 98,
    CHANNEL_SUCCESS           = 99,
    CHANNEL_FAILURE           = 100,
}

-- SSH_DISCONNECT_* reason codes (RFC 4253 §11.1).
M.disconnect = {
    HOST_NOT_ALLOWED_TO_CONNECT  = 1,
    PROTOCOL_ERROR               = 2,
    KEY_EXCHANGE_FAILED          = 3,
    MAC_ERROR                    = 5,
    SERVICE_NOT_AVAILABLE        = 7,
    PROTOCOL_VERSION_NOT_SUPPORTED = 6,
    HOST_KEY_NOT_VERIFIABLE      = 9,
    CONNECTION_LOST              = 10,
    BY_APPLICATION               = 11,
    AUTH_CANCELLED_BY_USER       = 13,
    NO_MORE_AUTH_METHODS_AVAILABLE = 14,
}

-- SSH_OPEN_* channel-open failure codes (RFC 4254 §5.1).
M.open_failure = {
    ADMINISTRATIVELY_PROHIBITED = 1,
    CONNECT_FAILED              = 2,
    UNKNOWN_CHANNEL_TYPE        = 3,
    RESOURCE_SHORTAGE          = 4,
}

-- CHANNEL_EXTENDED_DATA type codes (RFC 4254 §5.2).
M.extended_data = {
    STDERR = 1,
}

-- The one suite we negotiate.  These are the exact name-list members
-- advertised in our KEXINIT.  curve25519-sha256 and its @libssh.org alias
-- are byte-identical in construction (RFC 8731); we offer both for
-- interop with older peers.  The MAC list is still exchanged but unused:
-- chacha20-poly1305@openssh.com is AEAD, so the negotiated MAC is implicit.
M.algo = {
    kex          = { "curve25519-sha256", "curve25519-sha256@libssh.org" },
    host_key     = { "ssh-ed25519" },
    cipher       = { "chacha20-poly1305@openssh.com" },
    mac          = { "hmac-sha2-256" },   -- placeholder; ignored under AEAD
    compression  = { "none" },
}

return M
