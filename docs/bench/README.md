# Benchmarks

Every number on this page comes from the `benchmark` workflow in this repository, run on a GitHub-hosted runner.

## Machine

| property | value |
|---|---|
| runner image | ubuntu24 20261116.133.1 |
| cpu | Intel(R) Xeon(R) 6975P-C |
| cpu cores | 4 |
| memory | 15.3 GB |
| kernel | Linux 7.0.0-1014-aws |
| zig | 0.17.1 |
| date | 2026-11-22 |

## Method

Two network namespaces joined by a veth pair. Traffic enters the tunnel device (MTU 8500), leaves through the same SOCKS5 server (hev-socks5-server) for every engine, and reaches the servers in the second namespace. Engines are interleaved: each round starts every engine once and runs every scenario against it, so background noise spreads evenly. CPU comes from `/proc/<pid>/stat` and memory from `VmRSS`, summed over all processes of an engine.

Duration 8 s per scenario, 2 rounds, 4 queues. Memory is read twice: the highest sample while the scenario runs, and again after 5 s of idle, which shows whether an engine gives the memory back.

## Throughput

![throughput](throughput.svg)

## CPU

![cpu](cpu.svg)

## Request/response

![transactions](transactions.svg)

![latency](latency.svg)

## UDP

![udp](udp.svg)

## Memory

![memory](memory.svg)

## Raw results

| engine | scenario | median | cpu % | max rss MB | rss after idle MB |
|---|---|---:|---:|---:|---:|
| zeptun-userspace | tcp-up-1 | 27.849 Gbit/s | 95 | 2.9 | 1.7 |
| zeptun-userspace | tcp-up-10 | 37.037 Gbit/s | 151 | 9.9 | 2.7 |
| zeptun-userspace | tcp-down-1 | 22.117 Gbit/s | 99 | 2.9 | 2.7 |
| zeptun-userspace | tcp-down-10 | 36.743 Gbit/s | 192 | 6.5 | 2.8 |
| zeptun-userspace | rr | 20873 tps p50=34us p99=106us p99.9=117us  | 31 | 2.9 | 2.8 |
| zeptun-userspace | rr-8x1k | 108189 tps p50=71us p99=154us p99.9=196us  | 88 | 3.0 | 2.8 |
| zeptun-userspace | crr | 4509 tps p50=214us p99=288us p99.9=316us  | 38 | 4.7 | 4.4 |
| zeptun-userspace | udp-100k | 99978 echo pps (100.0% of 99992 sent)  | 28 | 5.0 | 4.4 |
| zeptun-userspace | udp-gso-100k | 99989 echo pps (100.0% of 99992 sent)  | 21 | 5.3 | 4.4 |
| hev | tcp-up-1 | 23.479 Gbit/s | 92 | 8.8 | 8.6 |
| hev | tcp-up-10 | 38.217 Gbit/s | 189 | 10.5 | 8.9 |
| hev | tcp-down-1 | 22.637 Gbit/s | 97 | 8.9 | 8.9 |
| hev | tcp-down-10 | 45.331 Gbit/s | 204 | 9.5 | 8.9 |
| hev | rr | 17904 tps p50=48us p99=110us p99.9=122us  | 34 | 8.9 | 8.9 |
| hev | rr-8x1k | 89499 tps p50=82us p99=206us p99.9=276us  | 128 | 9.0 | 8.9 |
| hev | crr | 3891 tps p50=250us p99=312us p99.9=340us  | 54 | 8.9 | 8.9 |
| hev | udp-100k | 99990 echo pps (100.0% of 99992 sent)  | 35 | 9.1 | 9.0 |
| hev | udp-gso-100k | 99978 echo pps (100.0% of 99992 sent)  | 35 | 9.3 | 9.3 |
| zeptun-hybrid | tcp-up-1 | 21.198 Gbit/s | 99 | 2.2 | 2.0 |
| zeptun-hybrid | tcp-up-10 | 35.568 Gbit/s | 199 | 3.8 | 2.8 |
| zeptun-hybrid | tcp-down-1 | 21.006 Gbit/s | 99 | 3.1 | 2.7 |
| zeptun-hybrid | tcp-down-10 | 39.223 Gbit/s | 218 | 3.8 | 2.9 |
| zeptun-hybrid | rr | 18772 tps p50=39us p99=112us p99.9=120us  | 36 | 2.9 | 2.7 |
| zeptun-hybrid | rr-8x1k | 91115 tps p50=83us p99=184us p99.9=246us  | 124 | 2.8 | 2.5 |
| zeptun-hybrid | crr | 3382 tps p50=288us p99=392us p99.9=428us  | 66 | 7.8 | 7.7 |
| zeptun-hybrid | udp-100k | 99974 echo pps (100.0% of 99992 sent)  | 32 | 8.2 | 7.8 |
| zeptun-hybrid | udp-gso-100k | 99980 echo pps (100.0% of 99992 sent)  | 21 | 8.3 | 7.8 |
| tun2socks | tcp-up-1 | 8.091 Gbit/s | 217 | 17.5 | 17.2 |
| tun2socks | tcp-up-10 | 11.195 Gbit/s | 299 | 35.2 | 33.6 |
| tun2socks | tcp-down-1 | 6.298 Gbit/s | 168 | 38.4 | 24.7 |
| tun2socks | tcp-down-10 | 11.910 Gbit/s | 274 | 144.8 | 144.8 |
| tun2socks | rr | 9300 tps p50=106us p99=162us p99.9=196us  | 73 | 144.8 | 144.8 |
| tun2socks | rr-8x1k | 47829 tps p50=156us p99=364us p99.9=704us  | 172 | 152.9 | 21.7 |
| tun2socks | crr | 2144 tps p50=452us p99=584us p99.9=2176us  | 93 | 39.7 | 39.7 |
| tun2socks | udp-100k | 87216 echo pps (87.2% of 99992 sent)  | 196 | 32.4 | 31.9 |
| tun2socks | udp-gso-100k | 88688 echo pps (88.7% of 99984 sent)  | 198 | 32.3 | 32.2 |

zeptun: startup 2 ms, idle 1116 KB, 5 wakeups in 20 s | tcp 1000: 3088 KB (conns: 1000/1000 established, 0 failed, 3098 conn/s) | udp 1000: 2804 KB (udp flows: 1000/1000 answered, 18132 flows/s)
hev: startup 2 ms, idle 538 KB, 2 wakeups in 20 s | tcp 1000: 9289 KB (conns: 1000/1000 established, 0 failed, 3738 conn/s) | udp 1000: 9125 KB (udp flows: 1000/1000 answered, 19215 flows/s)
singbox-system: startup 35 ms, idle 53820 KB, 6 wakeups in 20 s | tcp 1000: 70039 KB (conns: 1000/1000 established, 0 failed, 2507 conn/s) | udp 1000: 63923 KB (udp flows: 0/1000 answered, 0 flows/s)
singbox-gvisor: startup 37 ms, idle 55976 KB, 125 wakeups in 20 s | tcp 1000: 90383 KB (conns: 1000/1000 established, 0 failed, 2014 conn/s) | udp 1000: 93335 KB (udp flows: 0/1000 answered, 0 flows/s)
tun2socks: startup 3 ms, idle 11200 KB, 248 wakeups in 20 s | tcp 1000: 58848 KB (conns: 1000/1000 established, 0 failed, 2026 conn/s) | udp 1000: 114452 KB (udp flows: 1000/1000 answered, 7610 flows/s)
