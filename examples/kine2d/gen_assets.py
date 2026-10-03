#!/usr/bin/env python3
"""Generates the Kine2D demo characters (capybara, rock, goblin) into assets/characters/.

Each character is written the way the Kine2D editor's BUILD button exports it:
  <name>.skel.json  bones, slots (region attachments) and animations
  <name>.atlas.json one page + region rectangles
  <name>.png        the page, drawn procedurally here (no external art, stdlib only)

Kine2D bones are ABSOLUTE (not relative to their parent), so the animations are baked: this script
does the forward kinematics and keys every bone's x/y/rotation. Units: rig space is pixels, y down,
feet at y = 0, bones are written in canvas units (x/8, y/(10/3)) as the runtime expects.

  python3 examples/kine2d/gen_assets.py
"""
import json
import math
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'assets', 'characters')
CANVAS_W, CANVAS_H = 800, 600
UX, UY = CANVAS_W / 100.0, CANVAS_H / 180.0  # pixels per canvas unit


# ---------------------------------------------------------------- rig model

class Part:
    def __init__(self, name, parent, joint, ang, size, center, shape, color, tint=1.0, **kw):
        self.name, self.parent = name, parent
        self.joint = joint            # rest joint position (rig px)
        self.ang = ang                # rest world angle (deg, clockwise, 0 = +x)
        self.w, self.h = size         # sprite size
        self.cx, self.cy = center     # sprite center in bone space (bone +x along `ang`)
        self.shape, self.color, self.tint = shape, color, tint
        self.kw = kw
        self.sprite = shape is not None


class Rig:
    def __init__(self, name, parts):
        self.name = name
        self.parts = parts            # back-to-front draw order
        self.by_name = {p.name: p for p in parts}

    def pose(self, dx=0.0, dy=0.0, deltas=None):
        """Forward kinematics: {bone: (x_px, y_px, world_angle)} with root moved by (dx, dy)."""
        deltas = deltas or {}
        out = {}

        def solve(p):
            if p.name in out:
                return out[p.name]
            d = deltas.get(p.name, 0.0)
            if p.parent is None:
                res = (p.joint[0] + dx, p.joint[1] + dy, p.ang + d)
            else:
                pp = self.by_name[p.parent]
                px, py, pa = solve(pp)
                off = (p.joint[0] - pp.joint[0], p.joint[1] - pp.joint[1])
                ox, oy = rot(off[0], off[1], pa - pp.ang)
                res = (px + ox, py + oy, pa + (p.ang - pp.ang) + d)
            out[p.name] = res
            return res

        for p in self.parts:
            solve(p)
        return out


def rot(x, y, deg):
    r = math.radians(deg)
    c, s = math.cos(r), math.sin(r)
    return x * c - y * s, x * s + y * c


def smooth(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def kf(f, keys):
    """Value at frame f from [(frame, value), ...] with smoothstep easing."""
    if f <= keys[0][0]:
        return keys[0][1]
    for (f0, v0), (f1, v1) in zip(keys, keys[1:]):
        if f <= f1:
            return v0 + (v1 - v0) * smooth((f - f0) / (f1 - f0))
    return keys[-1][1]


def wave(f, length, phase=0.0):
    return math.sin(2 * math.pi * f / length + phase)


# ---------------------------------------------------------------- drawing

def clamp01(v):
    return 0.0 if v < 0 else 1.0 if v > 1 else v


def sd_ellipse(x, y, a, b):
    k = math.hypot(x / a, y / b)
    return (k - 1.0) * min(a, b)


def sd_capsule(x, y, w, h):
    r = h / 2.0
    l = max(0.0, w / 2.0 - r)
    return math.hypot(max(abs(x) - l, 0.0), y) - r


def sd_rrect(x, y, hw, hh, r):
    qx, qy = abs(x) - hw + r, abs(y) - hh + r
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r


def sd_poly(x, y, pts):
    d2, inside = 1e18, False
    n = len(pts)
    for i in range(n):
        ax, ay = pts[i]
        bx, by = pts[(i + 1) % n]
        ex, ey = bx - ax, by - ay
        t = clamp01(((x - ax) * ex + (y - ay) * ey) / (ex * ex + ey * ey))
        d2 = min(d2, (x - ax - ex * t) ** 2 + (y - ay - ey * t) ** 2)
        if (ay > y) != (by > y) and x < (bx - ax) * (y - ay) / (by - ay) + ax:
            inside = not inside
    d = math.sqrt(d2)
    return -d if inside else d


def mul(c, k):
    return tuple(max(0, min(255, int(v * k))) for v in c)


def mix(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def draw_sprite(p):
    """RGBA bytes rows for a part's sprite (w x h), 1px transparent margin, outlined and shaded."""
    w, h = int(round(p.w)), int(round(p.h))
    base = mul(p.color, p.tint)
    edge = mul(base, 0.5)
    ow = p.kw.get('outline', 1.8)
    hw, hh = w / 2.0 - 1.0, h / 2.0 - 1.0
    rows = []
    for j in range(h):
        row = bytearray()
        for i in range(w):
            x, y = i + 0.5 - w / 2.0, j + 0.5 - h / 2.0
            if p.shape == 'ellipse' or p.shape == 'eye':
                d = sd_ellipse(x, y, hw, hh)
            elif p.shape == 'capsule':
                d = sd_capsule(x, y, w - 2, h - 2)
            elif p.shape == 'rrect':
                d = sd_rrect(x, y, hw, hh, p.kw.get('radius', 6))
            elif p.shape == 'poly':
                pts = [((px - 0.5) * 2 * hw, (py - 0.5) * 2 * hh) for px, py in p.kw['pts']]
                d = sd_poly(x, y, pts)
            else:
                raise ValueError(p.shape)
            a = clamp01(0.5 - d)
            fill = mul(base, 1.14 - 0.34 * (j / float(h)))
            if p.shape == 'eye':
                fill = (250, 250, 245)
                px_, py_ = hw * 0.25 * p.kw.get('look', 1), 0
                pr = hh * 0.62
                if math.hypot(x - px_, y - py_) < pr:
                    fill = (28, 24, 30)
                    if math.hypot(x - px_ - pr * 0.35, y - py_ + pr * 0.35) < pr * 0.28:
                        fill = (255, 255, 255)
            col = mix(fill, edge, clamp01(d + ow + 0.5)) if p.shape != 'eye' else fill
            if a <= 0:
                col = edge
            row += bytes((col[0], col[1], col[2], int(a * 255)))
        rows.append(bytes(row))
    return w, h, rows


def write_png(path, width, height, pixels):
    raw = b''.join(b'\x00' + bytes(pixels[y * width * 4:(y + 1) * width * 4]) for y in range(height))

    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)

    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(raw, 9)))
        f.write(chunk(b'IEND', b''))


def pack_atlas(rig):
    """Shelf-pack every sprite (2px padding) into one page. Returns (width, height, rgba, regions)."""
    sprites = [(p, *draw_sprite(p)) for p in rig.parts if p.sprite]
    page_w = 256
    x = y = shelf = 0
    placed = []
    for p, w, h, rows in sorted(sprites, key=lambda s: -s[2]):
        if x + w > page_w:
            x, y, shelf = 0, y + shelf + 2, 0
        placed.append((p, x, y, w, h, rows))
        x += w + 2
        shelf = max(shelf, h)
    page_h = 1
    while page_h < y + shelf:
        page_h *= 2
    buf = bytearray(page_w * page_h * 4)
    regions = {}
    for p, px, py, w, h, rows in placed:
        for j, row in enumerate(rows):
            o = ((py + j) * page_w + px) * 4
            buf[o:o + w * 4] = row
        regions[p.name] = (px, py, w, h)
    return page_w, page_h, buf, regions


# ---------------------------------------------------------------- export

def r3(v):
    return round(v, 3)


def export(rig, animations):
    """animations: {name: (length, fps, fn(frame) -> (dx, dy, {part: delta_deg}))}"""
    name = rig.name
    page_w, page_h, buf, regions = pack_atlas(rig)
    write_png(os.path.join(OUT, name + '.png'), page_w, page_h, buf)
    path = lambda p: '%s/%s.png' % (name, p)
    atlas = {
        'image': name + '.png', 'width': page_w, 'height': page_h,
        'regions': [{'path': path(n), 'x': x, 'y': y, 'width': w, 'height': h}
                    for n, (x, y, w, h) in regions.items()],
    }
    rest = rig.pose()

    def bone_json(p, pose):
        x, y, a = pose
        return {'name': p.name, **({'parent': p.parent} if p.parent else {}),
                'x': r3(x / UX), 'y': r3(y / UY), 'rotation': r3(a),
                'length': 0, 'scaleX': 1, 'scaleY': 1}

    skel = {
        'canvasSize': {'width': CANVAS_W, 'height': CANVAS_H},
        'bones': [bone_json(p, rest[p.name]) for p in rig.parts],
        'slots': [],
        'skins': [{'id': 'default', 'name': 'Default', 'attachments': {}}],
        'activeSkinId': 'default',
        'physicsConstraints': [], 'transformConstraints': [], 'ikConstraints': [],
        'animations': {},
    }
    for i, p in enumerate((p for p in rig.parts if p.sprite), 1):
        skel['slots'].append({
            'id': 'slot-%d' % i, 'name': p.name, 'bone': p.name, 'displayIndex': 0,
            'attachments': [{
                'path': path(p.name), 'size': {'width': int(round(p.w)), 'height': int(round(p.h))},
                'x': r3(p.cx - round(p.w) / 2.0), 'y': r3(p.cy), 'scaleX': 1, 'scaleY': 1,
            }],
        })
    for aname, (length, fps, fn) in animations.items():
        frames = list(range(0, length, 2)) + [length]
        keyframes = {p.name: {} for p in rig.parts}
        for f in frames:
            dx, dy, deltas = fn(f)
            pose = rig.pose(dx, dy, deltas)
            for p in rig.parts:
                x, y, a = pose[p.name]
                keyframes[p.name][str(f)] = {'x': r3(x / UX), 'y': r3(y / UY), 'rotation': r3(a)}
        skel['animations'][aname] = {'length': length, 'fps': fps, 'keyframes': keyframes}
    with open(os.path.join(OUT, name + '.skel.json'), 'w') as f:
        json.dump(skel, f, indent=1)
    with open(os.path.join(OUT, name + '.atlas.json'), 'w') as f:
        json.dump(atlas, f, indent=1)
    print('%-9s %3d bones  %d animations  atlas %dx%d' %
          (name, len(rig.parts), len(animations), page_w, page_h))


# ---------------------------------------------------------------- capybara (faces right)

def capybara():
    fur, dark = (176, 124, 78), (120, 80, 50)
    P = Part
    parts = [
        P('root', None, (0, 0), 0, (0, 0), (0, 0), None, fur),
        P('leg_bl', 'root', (-34, -32), 90, (40, 17), (18, 0), 'capsule', fur, 0.78),
        P('leg_fl', 'root', (34, -32), 90, (40, 17), (18, 0), 'capsule', fur, 0.78),
        P('body', 'root', (0, -50), 0, (124, 64), (0, 0), 'ellipse', fur),
        P('belly', 'body', (0, -50), 0, (92, 30), (2, 14), 'ellipse', (214, 170, 118), outline=0.01),
        P('leg_br', 'root', (-24, -32), 90, (40, 17), (18, 0), 'capsule', fur),
        P('leg_fr', 'root', (44, -32), 90, (40, 17), (18, 0), 'capsule', fur),
        P('head', 'body', (46, -62), 0, (60, 46), (16, 2), 'ellipse', fur),
        P('ear', 'head', (46, -62), 0, (15, 13), (6, -21), 'ellipse', dark),
        P('snout', 'head', (46, -62), 0, (30, 28), (42, 9), 'rrect', (190, 138, 90), radius=12),
        P('nose', 'head', (46, -62), 0, (12, 9), (54, 2), 'ellipse', (50, 36, 36), outline=0.8),
        P('eye', 'head', (46, -62), 0, (11, 11), (27, -8), 'eye', (0, 0, 0)),
    ]
    rig = Rig('capybara', parts)

    def stand(f):
        return 0, -1.2 * (wave(f, 24) + 1) / 2, {'head': 2.5 * wave(f, 24, -0.8),
                                                  'ear': 8 * wave(f, 12)}

    def walk(f):
        s = 24 * wave(f, 16)
        return 0, -2.5 * abs(wave(f, 16)), {
            'leg_fr': s, 'leg_bl': s, 'leg_fl': -s, 'leg_br': -s,
            'body': 2 * wave(f, 8, 1), 'head': 4 * wave(f, 8, -0.5), 'ear': 6 * wave(f, 8)}

    def run(f):
        s = 42 * wave(f, 10)
        return 0, -5 * abs(wave(f, 10)), {
            'leg_fr': s, 'leg_fl': s * 0.9, 'leg_br': -s, 'leg_bl': -s * 0.9,
            'body': -4 + 3 * wave(f, 10, 1), 'head': 6 * wave(f, 10, -0.5), 'ear': 12 * wave(f, 5)}

    def jump(f):
        h = kf(f, [(0, 0), (4, 6), (12, -46), (20, 0), (24, 0)])
        crouch = kf(f, [(0, 0), (4, 1), (6, 0), (18, 0), (20, 1), (24, 0)])
        tuck = kf(f, [(0, 0), (6, 0), (12, 1), (18, 0)])
        return 0, h - 3 * crouch, {
            'leg_fr': -50 * tuck, 'leg_fl': -40 * tuck, 'leg_br': 55 * tuck, 'leg_bl': 45 * tuck,
            'body': -8 * tuck, 'head': -10 * tuck + 4 * crouch}

    def happy(f):
        hop = abs(wave(f, 10))
        return 0, -9 * hop, {'head': 8 * wave(f, 10, 0.5), 'ear': 18 * wave(f, 5),
                             'leg_fr': 10 * wave(f, 10), 'leg_br': -10 * wave(f, 10),
                             'leg_fl': 10 * wave(f, 10), 'leg_bl': -10 * wave(f, 10)}

    export(rig, {'stand1': (24, 12, stand), 'walk': (16, 16, walk), 'run': (10, 20, run),
                 'jump': (24, 14, jump), 'happy': (20, 14, happy)})


# ---------------------------------------------------------------- rock golem (faces LEFT)

def rock():
    stone, light, moss = (128, 130, 142), (160, 164, 176), (96, 150, 78)
    P = Part
    parts = [
        P('root', None, (0, 0), 0, (0, 0), (0, 0), None, stone),
        P('leg_r', 'root', (14, -36), 90, (34, 26), (14, 0), 'capsule', stone, 0.8),
        P('arm_r', 'root', (46, -88), 80, (52, 22), (22, 0), 'capsule', stone, 0.8),
        P('fist_r', 'arm_r', (46 + 44 * math.cos(math.radians(80)), -88 + 44 * math.sin(math.radians(80))),
          0, (30, 28), (0, 0), 'ellipse', light, 0.8),
        P('crystal_b', 'body', (0, -78), -80, (34, 20), (14, 0), 'poly', (110, 200, 235),
          pts=[(0, 0), (0, 1), (1, 0.5)]),
        P('body', 'root', (0, -72), 0, (104, 86), (0, 0), 'rrect', stone, radius=34),
        P('moss', 'body', (0, -72), 0, (62, 24), (14, -34), 'ellipse', moss),
        P('crystal_a', 'body', (-30, -108), -105, (40, 24), (16, 0), 'poly', (140, 220, 250),
          pts=[(0, 0), (0, 1), (1, 0.5)]),
        P('leg_l', 'root', (-16, -36), 90, (34, 26), (14, 0), 'capsule', stone),
        P('eye_a', 'body', (0, -72), 0, (16, 16), (-34, -14), 'eye', (0, 0, 0), look=-1),
        P('eye_b', 'body', (0, -72), 0, (16, 16), (-10, -14), 'eye', (0, 0, 0), look=-1),
        P('mouth', 'body', (0, -72), 0, (30, 8), (-24, 12), 'rrect', (52, 46, 52), radius=3, outline=0.6),
        P('arm_l', 'root', (-46, -88), 100, (52, 22), (22, 0), 'capsule', stone),
        P('fist_l', 'arm_l', (-46 + 44 * math.cos(math.radians(100)), -88 + 44 * math.sin(math.radians(100))),
          0, (30, 28), (0, 0), 'ellipse', light),
    ]
    rig = Rig('rock', parts)

    def idle(f):
        b = wave(f, 28)
        return 0, 1.5 * b, {'body': 1.2 * b, 'arm_l': 4 * b, 'arm_r': -4 * b, 'crystal_a': 5 * b}

    def walk(f):
        s = 22 * wave(f, 16)
        return 0, -4 * abs(wave(f, 16)), {
            'leg_l': s, 'leg_r': -s, 'arm_l': -s * 0.8, 'arm_r': s * 0.8,
            'body': 3 * wave(f, 16, 1.57), 'crystal_a': 6 * wave(f, 8), 'crystal_b': -6 * wave(f, 8)}

    export(rig, {'walk': (16, 12, walk), 'idle': (28, 12, idle)})


# ---------------------------------------------------------------- goblin (faces right)

def goblin():
    skin, cloth, wood = (118, 176, 84), (136, 92, 58), (150, 106, 64)
    P = Part
    shoulder = (6, -62)
    arm_len = 28
    hand = (shoulder[0], shoulder[1] + arm_len)
    parts = [
        P('root', None, (0, 0), 0, (0, 0), (0, 0), None, skin),
        P('leg_far', 'root', (-6, -30), 90, (36, 13), (16, 0), 'capsule', skin, 0.8),
        P('arm_far', 'root', (-4, -62), 90, (36, 12), (14, 0), 'capsule', skin, 0.8),
        P('ear_far', 'head', (0, -84), -150, (30, 17), (14, 0), 'poly', skin,
          pts=[(0, 0.15), (0, 0.85), (1, 0.5)], tint=0.8),
        P('leg_near', 'root', (7, -30), 90, (36, 13), (16, 0), 'capsule', skin),
        P('body', 'root', (0, -50), 0, (42, 48), (0, 0), 'rrect', cloth, radius=16),
        P('belt', 'body', (0, -50), 0, (44, 8), (0, 12), 'rrect', (84, 56, 36), radius=3, outline=0.8),
        P('head', 'body', (2, -76), 0, (56, 46), (2, -8), 'ellipse', skin),
        P('ear_near', 'head', (-6, -84), -158, (32, 18), (15, 0), 'poly', skin,
          pts=[(0, 0.15), (0, 0.85), (1, 0.5)]),
        P('nose', 'head', (2, -76), 0, (14, 12), (30, -4), 'poly', (96, 150, 68),
          pts=[(0, 0), (0, 1), (1, 0.6)]),
        P('eye', 'head', (2, -76), 0, (13, 13), (16, -14), 'eye', (0, 0, 0)),
        P('mouth', 'head', (2, -76), 0, (16, 5), (20, 6), 'rrect', (60, 36, 36), radius=2, outline=0.5),
        P('arm_near', 'root', shoulder, 90, (arm_len + 8, 13), (arm_len / 2, 0), 'capsule', skin),
        P('club', 'arm_near', hand, -35, (58, 18), (22, 0), 'poly', wood,
          pts=[(0, 0.38), (0.55, 0.3), (1, 0), (1, 1), (0.55, 0.7), (0, 0.62)]),
    ]
    rig = Rig('goblin', parts)

    def idle(f):
        b = wave(f, 24)
        return 0, -1.5 * (b + 1) / 2, {'head': 3 * wave(f, 24, -0.7), 'arm_near': 5 * b,
                                        'arm_far': -4 * b, 'ear_near': 6 * wave(f, 12),
                                        'ear_far': 6 * wave(f, 12, 1)}

    def attack(f):
        lunge = kf(f, [(0, 0), (4, -6), (7, 16), (12, 6), (16, 0)])
        arm = kf(f, [(0, 0), (4, -120), (7, 50), (12, 30), (16, 0)])
        lean = kf(f, [(0, 0), (4, -8), (7, 12), (12, 4), (16, 0)])
        return lunge, 0, {'arm_near': arm, 'arm_far': -arm * 0.3, 'body': lean,
                          'head': lean * 0.5, 'leg_near': -lunge, 'leg_far': lunge * 0.6}

    def skill(f):
        jump = kf(f, [(0, 0), (4, 5), (10, -34), (15, -34), (19, 0), (21, 0), (24, 0)])
        arm = kf(f, [(0, 0), (5, -150), (15, -165), (18, 70), (21, 40), (24, 0)])
        lean = kf(f, [(0, 0), (5, -10), (15, -14), (18, 16), (21, 6), (24, 0)])
        return 0, jump, {'arm_near': arm, 'arm_far': -arm * 0.4, 'body': lean, 'head': lean * 0.6,
                         'ear_near': 15 * smooth(jump / -34.0), 'ear_far': 15 * smooth(jump / -34.0),
                         'leg_near': -25 * smooth(jump / -34.0), 'leg_far': 25 * smooth(jump / -34.0)}

    export(rig, {'idle': (24, 12, idle), 'attack': (16, 16, attack), 'skill': (24, 14, skill)})


if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    capybara()
    rock()
    goblin()
