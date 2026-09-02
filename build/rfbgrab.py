#!/usr/bin/env python3
"""Minimal RFB (VNC) client: connect, grab one raw framebuffer, report pixel stats.

Usage: rfbgrab.py HOST PORT [OUT.ppm]
Exit 0 = non-uniform framebuffer captured. Exit 2 = uniform (flat colour). Exit 1 = error.
"""
import socket, struct, sys, collections

host = sys.argv[1]
port = int(sys.argv[2])
out = sys.argv[3] if len(sys.argv) > 3 else None

s = socket.create_connection((host, port), timeout=30)
s.settimeout(60)


def recvn(n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError("server closed after %d/%d bytes" % (len(b), n))
        b += c
    return b


ver = recvn(12)
print("server version:", ver.decode(errors="replace").strip())
s.sendall(b"RFB 003.008\n")

nsec = recvn(1)[0]
if nsec == 0:
    reason_len = struct.unpack(">I", recvn(4))[0]
    raise SystemExit("connect failed: " + recvn(reason_len).decode(errors="replace"))
sectypes = list(recvn(nsec))
print("security types:", sectypes)
if 1 not in sectypes:
    raise SystemExit("server requires auth (types %s); probe expects None" % sectypes)
s.sendall(bytes([1]))
res = struct.unpack(">I", recvn(4))[0]
if res != 0:
    raise SystemExit("SecurityResult failed: %d" % res)

s.sendall(bytes([1]))  # ClientInit, shared

w, h = struct.unpack(">HH", recvn(4))
pf = recvn(16)
nlen = struct.unpack(">I", recvn(4))[0]
name = recvn(nlen).decode(errors="replace")
print("desktop: %dx%d name=%r" % (w, h, name))
print("server pixel format:", pf.hex())

# SetPixelFormat -> 32bpp depth24 little-endian truecolour BGRX
newpf = struct.pack(">BBBBHHHBBBBBB", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0, 0, 0, 0)
assert len(newpf) == 16, len(newpf)
s.sendall(b"\x00\x00\x00\x00" + newpf)

# SetEncodings: raw only
s.sendall(struct.pack(">BBH", 2, 0, 1) + struct.pack(">i", 0))

fb = None
for attempt in range(6):
    incremental = 0
    s.sendall(struct.pack(">BBHHHH", 3, incremental, 0, 0, w, h))
    msg = recvn(1)[0]
    if msg != 0:
        print("unexpected server msg type %d, skipping" % msg)
        continue
    recvn(1)
    nrects = struct.unpack(">H", recvn(2))[0]
    print("attempt %d: %d rects" % (attempt, nrects))
    if fb is None:
        fb = bytearray(w * h * 4)
    got_pixels = False
    for _ in range(nrects):
        rx, ry, rw, rh = struct.unpack(">HHHH", recvn(8))
        enc = struct.unpack(">i", recvn(4))[0]
        if enc != 0:
            raise SystemExit("server used encoding %d, expected Raw(0)" % enc)
        data = recvn(rw * rh * 4)
        got_pixels = True
        for row in range(rh):
            dst = ((ry + row) * w + rx) * 4
            src = row * rw * 4
            fb[dst:dst + rw * 4] = data[src:src + rw * 4]
    if got_pixels:
        # count distinct colours on this frame
        colours = collections.Counter()
        for i in range(0, len(fb), 4):
            colours[bytes(fb[i:i + 3])] += 1
        if len(colours) > 1:
            break

colours = collections.Counter()
for i in range(0, len(fb), 4):
    colours[bytes(fb[i:i + 3])] += 1

total = w * h
top = colours.most_common(8)
print("distinct colours: %d over %d pixels" % (len(colours), total))
for c, n in top:
    print("   #%02x%02x%02x  %8d  %5.1f%%" % (c[2], c[1], c[0], n, 100.0 * n / total))

# luma variance
mean = 0.0
for c, n in colours.items():
    mean += (0.114 * c[0] + 0.587 * c[1] + 0.299 * c[2]) * n
mean /= total
var = 0.0
for c, n in colours.items():
    l = 0.114 * c[0] + 0.587 * c[1] + 0.299 * c[2]
    var += (l - mean) ** 2 * n
var /= total
print("luma mean=%.2f variance=%.2f stddev=%.2f" % (mean, var, var ** 0.5))

if out:
    with open(out, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (w, h))
        px = bytearray(w * h * 3)
        for i in range(total):
            px[i * 3 + 0] = fb[i * 4 + 2]
            px[i * 3 + 1] = fb[i * 4 + 1]
            px[i * 3 + 2] = fb[i * 4 + 0]
        f.write(bytes(px))
    print("wrote", out)

dom = top[0][1] / total
if len(colours) <= 1:
    print("VERDICT: FLAT — single colour framebuffer (grey-screen failure)")
    raise SystemExit(2)
if dom > 0.999:
    print("VERDICT: EFFECTIVELY FLAT — %.4f%% one colour" % (dom * 100))
    raise SystemExit(2)
print("VERDICT: REAL FRAMEBUFFER — %d distinct colours, dominant %.1f%%" % (len(colours), dom * 100))
