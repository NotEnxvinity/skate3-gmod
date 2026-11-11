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

    assets/gestures/hands.json
    {"version": 1, "gestures": {"<id>": {"R": [[t1, t2, t3], [i1, i2, i3],
        [m...], [r...], [p...]], "L": [...]}}}

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
SIDES = (('R', 'RIGHT'), ('L', 'LEFT'))
VERSION = 1
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


def frames(A, path):
    """Every frame's finger bends: [frame][side][finger][joint]."""
    data = Path(path).read_bytes()
    abin = A.AbinFile(data)
    if not abin.clips or not abin.hierarchy:
        raise ValueError(f'{Path(path).name} has no clip')
    clip = abin.clips[0]
    index = {name: i for i, name in enumerate(A.BONE_NAMES)}
    decoders = {}
    out = []
    for f in range(clip.num_frames):
        sqts = A.decode_clip_frame(data, clip, decoders, f, abin.hierarchy)
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
    return out


def relaxed_hands(tracks):
    """Relaxed hands: every clip's first frame, averaged."""
    firsts = [t[0] for t in tracks]
    return [[[sum(fr[s][f][j] for fr in firsts) / len(firsts) for j in range(3)]
             for f in range(5)] for s in range(2)]


def held_shape(track, relaxed):
    """The hands held mid-gesture: the longest run of frames where they keep
    still away from relaxed hands (a wind-up passes through a fist on its
    way to a Spock hand, but the Spock hand is the part that stays)."""
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
        keep = [track[i] for i in max(away, key=lambda r: (len(r), sum(gap(track[i], relaxed) for i in r)))]
    else:
        keep = [max(track, key=lambda fr: gap(fr, relaxed))]
    shape = {}
    for s, (key, _) in enumerate(SIDES):
        shape[key] = [[round(max(-40.0, min(120.0, sum(fr[s][f][j] for fr in keep) / len(keep))), 1)
                       for j in range(3)] for f in range(5)]
    return shape


def build(engine, anim):
    """{id: shape} for every gesture whose preview clip is there."""
    A = decoder(engine)
    folder = Path(anim) / 'gesture'
    tracks = {}
    for gid, name in CLIPS.items():
        for sex in ('male', 'female'):
            path = folder / f'cac_{sex}_{name}.abin'
            if path.is_file():
                tracks[gid] = frames(A, path)
                break
    if not tracks:
        return {}
    relaxed = relaxed_hands(list(tracks.values()))
    return {gid: held_shape(t, relaxed) for gid, t in tracks.items()}


def export(engine, anim, out, report):
    """Writes assets/gestures/hands.json from the converted data's anim
    folder (assets/private/stock/data/anim). Returns True if it did; without
    it gestures play with our own relaxed hands."""
    if not (Path(anim) / 'gesture').is_dir():
        report("This copy of the game has no gesture previews, so gestures keep relaxed hands.")
        return False
    shapes = build(engine, anim)
    if not shapes:
        report("Couldn't find the gesture previews, so gestures keep relaxed hands.")
        return False
    text = json.dumps({'version': VERSION, 'gestures': shapes}, sort_keys=True, separators=(',', ':'))
    write_if_changed(Path(out) / 'hands.json', text.encode('utf-8'))
    report(f"Read the hand shapes of {len(shapes)} of Skate 3's {len(CLIPS)} gestures")
    return True


if __name__ == '__main__':
    # gestures.py <engine> <assets/private/stock/data/anim> <out folder>
    export(sys.argv[1], sys.argv[2], sys.argv[3], print)
