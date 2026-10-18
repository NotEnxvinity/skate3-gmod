"""World collision for a box: a vphysics "compact surface" for one convex
box, the format .phy files and a map's physcollide lump hold. Built from the
layout of a real box solid (12 triangles, 8 points, one ledge tree node): the
topology stays and only the eight corner points, the radii and the node's
box sizes change."""
import math, struct

TEMPLATE = bytes.fromhex(
    '56504859000100009c0100000000803f0000803f0000803f000000001920cd315029cbad5bfca03226e8f742fb63f842'
    '29e8f74080049f41fa9c010080010000000000000000000049565053d000000000000000041500000c00000000900000'
    '0000060001001700020006000180000000000e00030028000100fa7f02b000000000fa7f020011000400020003a00000'
    '0000fe7f04001900050006000470000000000600060018000300f27f056000000000fa7f050010000600fa7f06500000'
    '0200e97f010003000400ef7f074000000400fd7f01000f00070004000810000007000a00060003000400fc7f09100000'
    '0400fd7f0600f07f0500e77f0a300000070006000300e87f0600f67f0b2000000700f17f0100d87f0300fa7ff8449a40'
    'bf0e1c3df9449a4100000000fc449a40bf0e1cbdf9449ac100000000fc449a40bf0e1c3df9449ac100000000f8449a40'
    'bf0e1cbdf9449a4100000000f8449ac0bf0e1c3df9449ac100000000fc449ac0bf0e1c3df9449a4100000000fc449ac0'
    'bf0e1cbdf9449a4100000000f8449ac0bf0e1cbdf9449ac10000000000000000b0feffff000000000000000000000000'
    '80049f413d01f300'
)
INCH = 0.0254
# the template's corner signs (x, y, z) for its points 0..7
SIGNS = [(1, 1, 1), (1, -1, -1), (1, 1, -1), (1, -1, 1), (-1, 1, -1), (-1, 1, 1), (-1, -1, 1), (-1, -1, -1)]


def ivp(x, y, z):
    """A world position in Source units to where the engine reads it in a
    map's physcollide lump (metres, with y and z flipped from the usual
    Source-to-physics axes; checked by dropping props on a map in a server)."""
    return (x * INCH, -z * INCH, y * INCH)


def solid(lo, hi):
    """One box solid covering lo..hi (Source units, world space) as bytes."""
    a, b = ivp(*lo), ivp(*hi)
    lo_i = [min(a[k], b[k]) for k in range(3)]
    hi_i = [max(a[k], b[k]) for k in range(3)]
    center = [(lo_i[k] + hi_i[k]) / 2 for k in range(3)]
    half = [(hi_i[k] - lo_i[k]) / 2 for k in range(3)]
    radius = math.sqrt(sum(h * h for h in half))
    d = bytearray(TEMPLATE)
    # compact surface header at 28: mass center, rotation inertia, radius
    d[28:40] = struct.pack('<3f', *center)
    d[52:56] = struct.pack('<f', radius)
    # points at 284, 16 bytes each
    for i, (sx, sy, sz) in enumerate(SIGNS):
        d[284 + 16 * i:284 + 16 * i + 16] = struct.pack(
            '<4f', center[0] + sx * half[0], center[1] + sy * half[1], center[2] + sz * half[2], 0.0)
    # ledge tree node at 412: center, radius, box sizes in units of radius / 250
    unit = radius / 250
    sizes = [min(255, max(1, math.ceil(h / unit))) for h in half]
    d[420:432] = struct.pack('<3f', *center)
    d[432:436] = struct.pack('<f', radius)
    d[436:439] = bytes(sizes)
    return bytes(d)


def physcollide(lo, hi, surface='default'):
    """The map's physcollide lump holding one box as the world's collision."""
    s = solid(lo, hi)
    data = struct.pack('<i', len(s)) + s
    key = ('solid {\n"index" "0"\n"name" "world"\n"mass" "1000000.000000"\n"surfaceprop" "%s"\n'
           '"damping" "0.000000"\n"rotdamping" "0.000000"\n"inertia" "1.000000"\n"volume" "1000000.000000"\n}\n' % surface).encode()
    return struct.pack('<4i', 0, len(data), len(key), 1) + data + key + struct.pack('<4i', -1, 0, 0, 0)
