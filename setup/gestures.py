"""Hand shapes for Skate 3's D-pad gestures, from the player's own disc.

Skate 3's gameplay skeleton has no fingers (the engine's animation banks
drive the body only), yet a peace sign needs two fingers up. The disc's
Create-a-Skater previews do carry them: data/anim/gesture/cac_male_*.abin,
one clip per gesture, on the full rig with all fifteen finger joints. The
converter already copies them into assets/private/stock/data/anim/gesture.

This reads each clip's fingers with the engine's own ABIN decoder and keeps
one hand shape per gesture and hand: how far each finger joint bends, in
degrees (Skate 3 bends fingers about their own Z axis; 0 is straight,
positive curls towards the palm). The frames kept are where the hands differ
most from relaxed ones (all the clips' first frames, averaged) while
keeping still, which is the gesture held: two fingers up, horns, a shaka.

Bends alone come out differently on every playermodel, whose fingers rest
at their own angles (a thumb along the palm on one, out to the side on the
next). So it also keeps where each finger bone points, measured in the
hand's own frame: x towards the knuckles, y across the knuckles from the
index to the pinky, z out of the palm. The Lua points each playermodel
finger the same way in that model's hand frame. That needs the hand's bind
pose, which the clips don't carry: it comes from the Create-a-Skater arm
model (cas_db/Arm/*.rx2), whose bones the clips' rotations turn (a clip's
rotation is applied after the bone's bind rotation).

The same aims also give the everyday hands (version 3), so riding,
grabbing and bailing hands match the gestures' on every playermodel:
relaxed is the hands every preview starts from (averaged), grip is the
Fists Up fist (grabs, punches, swinging the board) and open is the
Airplane's flat hand (flailing in a bail).

    assets/gestures/hands.json
    {"version": 3, "gestures": {"<id>": {"R": [[t1, t2, t3], [i1, i2, i3],
        [m...], [r...], [p...]], "L": [...],
        "aimR": [[[x, y, z] x3 joints] x5 fingers], "aimL": [...]}},
     "poses": {"relaxed" | "grip" | "open": {"aimR": [...], "aimL": [...]}}}

ids are cl_gestures.lua's (the gesture catalog's B_GSTR_* names). Nothing
here is distributed: it is made on the player's machine like the rest.
"""
from pathlib import Path
import json, math, sys

from syncdir import write_if_changed

# cl_gestures.lua's id -> the preview clip's file name (cac_male_<name>.abin).
CLIPS = {
    'airguitar': 'airguitar', 'airplane': 'airplane', 'boxing': 'boxing', 'bruce_lee': 'bruce',
    'checktime': 'checktime', 'devil': 'devil', 'dble_gun': 'doublegun', 'dunno': 'dunno',
    'fingerwag': 'fingerwag', 'fists': 'fists', 'bicepflex': 'flex', 'fliptable': 'fliptable',
    'fonz_eh': 'fonz', 'freedom': 'freedom', 'fu_fist': 'fu', 'getaway': 'getouttheway',
    'getouttahere': 'getoutahere', 'handcuffs': 'handcuffs', 'highpump': 'pumphigh',
    'lowpump': 'pumplow', 'prewind': 'prewind', 'peace': 'peace', 'point': 'fingerpoint',
    'raiseroof': 'raisetheroof', 'shaka': 'shaka', 'shrug': 'shrug', 'point_sky': 'sky',
    'snap': 'snap', 'soularch': 'soularch', 'spock': 'spock', 'surfsup': 'surfsup',
    'swinghigh': 'swinghigh', 'swinglow': 'swinglow', 'throwarms': 'throwarms',
    'thmb_dwn': 'thumbsdown', 'wings': 'wings', 'yardsale': 'yardsale',
}
FINGERS = ('THUMB', 'INDEX', 'MIDDLE', 'RING', 'PINKY')
# Ring and pinky hang off a palm bone each.
PALM_BONES = {'RING': 'INHANDRING', 'PINKY': 'INHANDPINKY'}
SIDES = (('R', 'RIGHT'), ('L', 'LEFT'))
VERSION = 3
# The everyday hands: which gesture's held hands make the grip and the open hand.
POSE_FROM = {'grip': 'fists', 'open': 'airplane'}
# Total degrees, over all 30 finger joints: a frame this close to the last
# one is the hands keeping still, and a held shape is this far from relaxed.
STEP = 12.0
AWAY = 150.0


def decoder(engine):
    """The engine's vendored ABIN decoder (tools/vendor/skate3_anim)."""
    folder = str(Path(engine) / 'tools/vendor/skate3_anim')
    if folder not in sys.path:
        sys.path.insert(0, folder)
    import abin_importer
    return abin_importer


def bend(quat):
    """Degrees a finger joint curls: its turn about its own Z axis."""
    x, y, z, w = quat
    return -math.degrees(2 * math.atan2(z, w))


# Quaternions are (x, y, z, w).
def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz)


def qconj(q):
    return (-q[0], -q[1], -q[2], q[3])


def qrot(q, v):
    return qmul(qmul(q, (v[0], v[1], v[2], 0.0)), qconj(q))[:3]


def sub(a, b):
    return tuple(x - y for x, y in zip(a, b))


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def unit(v):
    n = math.sqrt(dot(v, v))
    return tuple(x / n for x in v) if n > 1e-9 else (0.0, 0.0, 0.0)


def arm_bind(engine, anim):
    """The left hand's bind pose from the Create-a-Skater arm: {bone: (local
    turn, local offset)} relative to its parent, or None. The right hand is
    its mirror image, and the clips' rotations are mirrored to match, so the
    left hand's bind serves both (a hand's frame below doesn't care which
    side it is)."""
    folder = Path(anim).parent / 'content/createacharacter/model/cas_db/Arm'
    if not folder.is_dir():
        return None
    path = str(Path(engine).resolve() / 'tools/vendor/skate3_anim')
    if path not in sys.path:
        sys.path.insert(0, path)
    import rx2_skeleton as RX2
    for rx2 in sorted(folder.glob('*.rx2')):
        try:
            bones = {b['name'].upper(): b for b in RX2.parse_rx2(str(rx2), geometry=False)['bones']}
        except Exception:
            continue
        if 'LEFTHANDINDEX1' not in bones or 'LEFTHAND' not in bones:
            continue
        bind = {}
        for name, b in bones.items():
            if not name.startswith(('LEFTHAND', 'LEFTINHAND')) or name == 'LEFTHAND':
                continue
            p = bones.get((b['parent_name'] or '').upper())
            if not p:
                continue
            turn = qmul(qconj(p['bind_quat']), b['bind_quat'])
            offset = qrot(qconj(p['bind_quat']), sub(b['bind_pos'], p['bind_pos']))
            bind[name[len('LEFT'):]] = (turn, offset)
        if all(f'HAND{f}{j}' in bind for f in FINGERS for j in (1, 2, 3)) and \
                all(b in bind for b in PALM_BONES.values()):
            return bind
    return None


def hand_pose(bind, sqts, index, side):
    """The fingers' bones in the hand's frame for one frame of a clip:
    {finger: [(position, turn) per joint]}."""
    out = {}
    for finger in FINGERS:
        chain = ([PALM_BONES[finger]] if finger in PALM_BONES else []) + [f'HAND{finger}{j}' for j in (1, 2, 3)]
        pos, turn, joints = (0.0, 0.0, 0.0), (0.0, 0.0, 0.0, 1.0), []
        for bone in chain:
            bind_turn, offset = bind[bone]
            sqt = sqts.get(index.get(side + bone)) if sqts is not None else None
            local = qmul(bind_turn, sqt.quat) if sqt else bind_turn
            pos = tuple(a + b for a, b in zip(pos, qrot(turn, offset)))
            turn = qmul(turn, local)
            if not bone.startswith('INHAND'):
                joints.append((pos, turn))
        out[finger] = joints
    return out


def hand_frame(bound):
    """(towards the knuckles, across them from index to pinky, out of the
    palm) from the bind pose, whose fingers rest a little curled towards
    the palm."""
    knuckles = [bound[f][0][0] for f in FINGERS[1:]]
    forward = unit(tuple(sum(k[i] for k in knuckles) / len(knuckles) for i in range(3)))
    across = sub(bound['PINKY'][0][0], bound['INDEX'][0][0])
    across = unit(sub(across, tuple(forward[i] * dot(across, forward) for i in range(3))))
    palm = unit(cross(forward, across))
    middle = bound['MIDDLE']
    if dot(sub(middle[2][0], middle[0][0]), palm) < 0:
        palm = tuple(-x for x in palm)
    return forward, across, palm


def aims(pose, frame):
    """Where each finger bone points, in the hand frame: [finger][joint] =
    (x, y, z). A bone points at the next joint; the fingertip bone along
    its own X, like every finger bone of this rig."""
    out = []
    for finger in FINGERS:
        joints = pose[finger]
        dirs = []
        for k, (pos, turn) in enumerate(joints):
            d = unit(sub(joints[k + 1][0], pos)) if k + 1 < len(joints) else unit(qrot(turn, (1.0, 0.0, 0.0)))
            dirs.append(tuple(dot(d, axis) for axis in frame))
        out.append(dirs)
    return out


def frames(A, path, bind=None):
    """Every frame's finger bends: [frame][side][finger][joint]. With the
    hand's bind pose, also where the finger bones point: [frame][side] =
    aims(), else None."""
    data = Path(path).read_bytes()
    abin = A.AbinFile(data)
    if not abin.clips or not abin.hierarchy:
        raise ValueError(f'{Path(path).name} has no clip')
    clip = abin.clips[0]
    index = {name: i for i, name in enumerate(A.BONE_NAMES)}
    decoders = {}
    out, pointing = [], []
    frame = hand_frame(hand_pose(bind, None, index, 'LEFT')) if bind else None
    for f in range(clip.num_frames):
        sqts = A.decode_clip_frame(data, clip, decoders, f, abin.hierarchy)
        if bind:
            pointing.append([aims(hand_pose(bind, sqts, index, side), frame) for _, side in SIDES])
        else:
            pointing.append(None)
        sides = []
        for _, side in SIDES:
            hand = []
            for finger in FINGERS:
                joints = []
                for j in (1, 2, 3):
                    sqt = sqts.get(index[f'{side}HAND{finger}{j}'])
                    joints.append(bend(sqt.quat) if sqt else 0.0)
                hand.append(joints)
            sides.append(hand)
        out.append(sides)
    if not out:
        raise ValueError(f'{Path(path).name} has no frames')
    return out, pointing


def relaxed_hands(tracks):
    """Relaxed hands: every clip's first frame, averaged."""
    firsts = [t[0] for t in tracks]
    return [[[sum(fr[s][f][j] for fr in firsts) / len(firsts) for j in range(3)]
             for f in range(5)] for s in range(2)]


def held_frames(track, relaxed):
    """The frames of the hands held mid-gesture: the longest run where they
    keep still away from relaxed hands (a wind-up passes through a fist on
    its way to a Spock hand, but the Spock hand is the part that stays)."""
    def gap(a, b):
        return sum(abs(x - y) for s in range(2) for f in range(5) for x, y in zip(a[s][f], b[s][f]))
    runs, run = [], [0]
    for i in range(1, len(track)):
        if gap(track[i], track[i - 1]) <= STEP:
            run.append(i)
        else:
            runs.append(run)
            run = [i]
    runs.append(run)
    away = [r for r in runs if sum(gap(track[i], relaxed) for i in r) / len(r) >= AWAY]
    if away:
        return max(away, key=lambda r: (len(r), sum(gap(track[i], relaxed) for i in r)))
    return [max(range(len(track)), key=lambda i: gap(track[i], relaxed))]


def held_shape(track, relaxed, pointing=None):
    """The held hands' bends per side, and with `pointing` (frames()'s
    second list) where their finger bones point, averaged over those frames."""
    kept = held_frames(track, relaxed)
    keep = [track[i] for i in kept]
    shape = {}
    for s, (key, _) in enumerate(SIDES):
        shape[key] = [[round(max(-40.0, min(120.0, sum(fr[s][f][j] for fr in keep) / len(keep))), 1)
                       for j in range(3)] for f in range(5)]
    if pointing and all(pointing[i] for i in kept):
        for s, (key, _) in enumerate(SIDES):
            shape['aim' + key] = [[[round(x, 3) for x in unit(tuple(sum(pointing[i][s][f][j][k] for i in kept)
                                                                     for k in range(3)))]
                                   for j in range(3)] for f in range(5)]
    return shape


def build(engine, anim):
    """({id: shape} for every gesture whose preview clip is there, {id:
    frames()'s aims per frame})."""
    A = decoder(engine)
    try:
        bind = arm_bind(engine, anim)
    except Exception:
        bind = None
    folder = Path(anim) / 'gesture'
    tracks, pointing = {}, {}
    for gid, name in CLIPS.items():
        for sex in ('male', 'female'):
            path = folder / f'cac_{sex}_{name}.abin'
            if path.is_file():
                tracks[gid], pointing[gid] = frames(A, path, bind)
                break
    if not tracks:
        return {}, {}
    relaxed = relaxed_hands(list(tracks.values()))
    return {gid: held_shape(t, relaxed, pointing[gid]) for gid, t in tracks.items()}, pointing


def mean_aims(frames):
    """Per side, finger and joint, the average of several frames' aims."""
    return [[[[round(x, 3) for x in unit(tuple(sum(fr[s][f][j][k] for fr in frames) for k in range(3)))]
              for j in range(3)] for f in range(5)] for s in range(len(SIDES))]


def everyday_poses(shapes, pointing):
    """{'relaxed' | 'grip' | 'open': {'aimR': ..., 'aimL': ...}} from the
    gestures (see the top), or {} without aims."""
    firsts = [p[0] for p in pointing.values() if p and p[0]]
    if not firsts:
        return {}
    poses = {'relaxed': {'aim' + key: side for (key, _), side in zip(SIDES, mean_aims(firsts))}}
    for name, gid in POSE_FROM.items():
        shape = shapes.get(gid, {})
        if 'aimR' in shape and 'aimL' in shape:
            poses[name] = {'aimR': shape['aimR'], 'aimL': shape['aimL']}
    return poses if len(poses) == 1 + len(POSE_FROM) else {}


def export(engine, anim, out, report):
    """Writes assets/gestures/hands.json from the converted data's anim
    folder (assets/private/stock/data/anim). Returns True if it did; without
    it gestures play with our own relaxed hands."""
    if not (Path(anim) / 'gesture').is_dir():
        report("This copy of the game has no gesture previews, so gestures keep relaxed hands.")
        return False
    shapes, pointing = build(engine, anim)
    if not shapes:
        report("Couldn't find the gesture previews, so gestures keep relaxed hands.")
        return False
    out_json = {'version': VERSION, 'gestures': shapes}
    poses = everyday_poses(shapes, pointing)
    if poses:
        out_json['poses'] = poses
    text = json.dumps(out_json, sort_keys=True, separators=(',', ':'))
    write_if_changed(Path(out) / 'hands.json', text.encode('utf-8'))
    aimed = sum(1 for s in shapes.values() if 'aimR' in s)
    report(f"Read the hand shapes of {len(shapes)} of Skate 3's {len(CLIPS)} gestures"
           + ('' if aimed else " (no Create-a-Skater arm found, so fingers bend instead of aiming)"))
    return True


if __name__ == '__main__':
    # gestures.py <engine> <assets/private/stock/data/anim> <out folder>
    export(sys.argv[1], sys.argv[2], sys.argv[3], print)
