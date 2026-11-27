# Host handoff

By default every datagram is relayed through the configured handler and every
stream is proxied to its destination. That is the right shape for a tunnel.

Some embedders need the traffic itself rather than a relay: they terminate the
protocol, produce the replies, and own the state. Handoff gives them that
without giving up the TUN device, the IP parsing, the routing or the session
bookkeeping.

Two paths, one selection rule:

* **Datagrams** — the host receives each matching datagram with its metadata.
* **Streams** — the host receives a connected socket once the client's
  handshake completes.

Anything that does not match keeps flowing through the configured handler, so
handoff and proxying coexist in one engine.

## Selection

Both paths use the same port filter: a list of up to `ZEPTUN_UDP_MAX_PORTS`
(64) entries, where an empty list means every port. Datagrams additionally
support a second-stage filter for ports the list misses.

```c
int zeptun_set_udp_intercept_ports(Zeptun *tun, const uint16_t *ports, size_t count);
int zeptun_set_tcp_intercept_ports(Zeptun *tun, const uint16_t *ports, size_t count);
```

A listed port never pays for extra callbacks. Listing more than 64 ports
returns `ZEPTUN_ERR_LIMIT_EXCEEDED` rather than silently truncating.

All callbacks, filters and port lists must be configured before
`zeptun_start()`. Attempts to register or change them after start return
`ZEPTUN_ERR_ALREADY_RUNNING`; they are not runtime-mutable settings.

The existing per-flow verdict is evaluated before handoff selection. A
`drop` or `reject` verdict prevents handoff, and `direct` follows the
direct handler. Only a `proxy` verdict allows the port/filter selection below
to hand the flow to the host.

## Datagrams

```c
typedef struct ZeptunUdpMeta {
    uint8_t family;          /* 4 or 6 */
    uint8_t src[16];         /* sender address */
    uint8_t dst[16];         /* destination address */
    uint16_t src_port;
    uint16_t dst_port;
    uint32_t payload_off;    /* offset to the UDP payload */
    uint32_t payload_len;
    char name[256];          /* fake-IP hostname, empty when unknown */
} ZeptunUdpMeta;

typedef void (*zeptun_udp_cb)(void *ctx, const uint8_t *packet, size_t len,
                              const ZeptunUdpMeta *meta);

typedef int (*zeptun_udp_filter_cb)(void *ctx, const uint8_t *packet, size_t len,
                                    const ZeptunUdpMeta *meta);

int zeptun_set_udp_callback(Zeptun *tun, zeptun_udp_cb callback, void *ctx);
int zeptun_set_udp_filter_callback(Zeptun *tun, zeptun_udp_filter_cb callback, void *ctx);
```

`packet` starts at the IP header and `len` covers the whole datagram. Use
`meta.payload_off` and `meta.payload_len` to reach the payload without
re-parsing.

The filter is consulted only for datagrams whose port did not match. Non-zero
takes the datagram, zero leaves it on the proxy path. The classification rule
belongs to the application: the engine makes no assumption about what a
payload carries.

When UDP segmentation offload is enabled, the handoff path presents ordinary
UDP datagrams one at a time. UDP GSO input selected by the port list is
segmented before the callback, and partial UDP checksums are completed, so
each callback invocation and its metadata describe one complete datagram
rather than an offload super-packet. A GSO packet on an unlisted port stays on
the normal handler path; the second-stage filter is not run on a super-packet.

### Replying

```c
int zeptun_send_packet(Zeptun *tun, const uint8_t *data, size_t len);
int zeptun_send_packets(Zeptun *tun, const ZeptunPacket *packets, size_t count);
```

Replies are complete IP datagrams. For IPv4 a UDP checksum of zero is
accepted; IPv6 requires a computed checksum. These are thread safe and may be
called from inside the callback.

For `zeptun_send_packet`, zero-length or over-MTU packets return
`ZEPTUN_ERR_INVALID_ARGUMENT`, a full bounded queue returns
`ZEPTUN_ERR_WOULD_BLOCK`, and a stopped engine returns `ZEPTUN_ERR_CLOSED`.
`zeptun_send_packets` keeps its batch contract and returns the number accepted;
a short count means the batch stopped at the first rejected packet.

## Streams

```c
typedef struct ZeptunTcpMeta {
    uint8_t family;          /* 4 or 6 */
    uint8_t src[16];         /* client address */
    uint8_t dst[16];         /* original destination */
    uint16_t src_port;
    uint16_t dst_port;
    char name[256];          /* fake-IP hostname, empty when unknown */
} ZeptunTcpMeta;

#include <stdint.h>

typedef void (*zeptun_tcp_cb)(void *ctx, const ZeptunTcpMeta *meta,
                              uintptr_t sock);

int zeptun_set_tcp_callback(Zeptun *tun, zeptun_tcp_cb callback, void *ctx);
```

The callback runs only after the client's TCP handshake is established.
It is not a SYN-time callback: with `tcp_early_accept = false`, receiving a
SYN does not invoke it. Early-accept configuration does not change the callback
contract; it only affects when the engine may acknowledge the client relative
to upstream processing.

`sock` is a **blocking** stream socket owned by the host. The public handle
uses a platform-width integer type, so it is wide enough for native Windows
socket values as well as POSIX descriptors. Convert it to the host platform's
socket API type at the integration boundary:

* reading it yields the client's bytes, exactly as sent;
* writing to it sends bytes back to the client through the real TCP state
  machine — sequence numbers, retransmission, window and all;
* closing it closes the client's connection;
* the host must close it when done, otherwise the connection stays open.

The engine never touches that socket again. It is handed out once per
connection.

TCP handoff requires the userspace TCP stack. A configuration using the system
or hybrid TCP stack cannot provide this callback; registering it must return
`ZEPTUN_ERR_NOT_SUPPORTED` (or configuration validation must reject the
combination) rather than silently skipping handoff. The current API rejects it
at `zeptun_set_tcp_callback()` time.

```c
static void on_tcp(void *ctx, const ZeptunTcpMeta *m, uintptr_t sock) {
    /* Hand the work to your own thread: this runs on a zeptun worker. */
    submit_to_worker_pool(ctx, m, sock);
}

/* On your thread; use the native socket type at this boundary. */
for (;;) {
    ssize_t n = host_socket_recv(sock, buf, sizeof buf, 0);
    if (n <= 0) break;                  /* EOF or error: client is gone */
    process(buf, n);
    host_socket_send(sock, reply, reply_len, 0);
}
host_socket_close(sock);
```

Do not block in the callback itself: it runs on a worker thread and holds up
every flow that worker owns.

## Threading and lifetime

| | Runs on | Memory valid |
|---|---|---|
| `zeptun_udp_cb` | worker thread, synchronously | until the callback returns |
| `zeptun_udp_filter_cb` | same | until the callback returns |
| `zeptun_tcp_cb` | worker thread, synchronously | the socket outlives the call |

`zeptun_send_packet(s)` copies into a bounded queue (2048 entries) and wakes
the engine, so it is safe from any thread, including from inside a callback.
When the queue is full it reports back-pressure instead of blocking.

The inject queue has one consumer, so datagram replies leave through a single
worker regardless of which worker received the datagram. Stream replies go
out on the worker that owns the connection.

## Registration order

All callback, filter and port-list setters must be called before
`zeptun_start()`. This includes `zeptun_set_udp_callback`,
`zeptun_set_tcp_callback`, `zeptun_set_udp_filter_callback`,
`zeptun_set_udp_intercept_ports` and `zeptun_set_tcp_intercept_ports`.
Passing `NULL` disables a callback before start; changing any of these
settings after start returns `ZEPTUN_ERR_ALREADY_RUNNING` rather than racing
with worker threads.

Registering a TCP callback with a system or hybrid TCP stack is rejected with
`ZEPTUN_ERR_NOT_SUPPORTED` at registration time.

## Elastic queues

A handed-out connection can be migrated like any other. The descriptor is
process-wide, so the transfer keeps it: the sending worker unregisters it from
its own loop, the record carries the descriptor, and the receiving worker
registers it on the other side. The host's half of the socket pair never
learns that anything moved — the same `sock` keeps reading and writing the
same byte stream across the migration.

One thing to be aware of: pending reads and writes are cancelled at the start
of a migration, and those cancellations complete asynchronously. A connection
therefore sees cancelled completions after it has already been marked as
moved, which is why the read paths ignore them when either the migration or
the moved flag is set. If you build on this, keep that ordering in mind.

If you would rather not rely on migration at all, `elastic = off` (or a single
queue) keeps every connection on the worker that opened it.

## Testing

The handoff API, UDP segmentation behavior, TCP handshake timing, error classes,
userspace-only validation and platform-width socket ABI are covered by the Zig
test suite and run as part of:

```sh
zig build test
```

The handoff tests use an external device model where possible, so they do not
require a real TUN device or elevated privileges. The build also exercises the
supported target configurations; application-specific protocol behavior stays
outside the library tests.
