"""Cuts a big converted skatepark into tiles, so no single piece is more than
Garry's Mod can build physics for in one go, and cleans a piece's collision
triangles of the degenerate ones the physics engine can't use.

A park is one big world mesh: its render groups (positions, uvs, indices per
texture) and its collision (a flat list of triangle corners). A tile keeps the
park's own origin, so every tile of a park sits at the same position and the
tiles line up with no offsets. Source units (inches) throughout.
"""

# A tile's collision stays well under what Garry's Mod builds reliably
# (PhysicsFromMesh drops triangles past about 65,000), and its render
# triangles under what one mesh draws without hitching.
MAX_COLLISION = 6000
MAX_RENDER = 16000
# Smallest triangle the physics engine is given: below this an edge or the
# area is too small to be a surface.
MIN_EDGE = 0.25
MIN_AREA = 0.05
DECIMALS = 1


def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _length(a):
    return (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]) ** 0.5


def usable(a, b, c):
    """Whether three corners make a triangle the physics engine can use."""
    ab, ac, bc = _sub(b, a), _sub(c, a), _sub(c, b)
    if min(_length(ab), _length(ac), _length(bc)) < MIN_EDGE:
        return False
    return _length(_cross(ab, ac)) * 0.5 >= MIN_AREA


def clean_collision(flat):
    """A flat list of triangle corners without degenerate or repeated
    triangles (a two-sided surface keeps both sides). Corners are rounded the
    way tiles store them."""
    out, seen = [], set()
    for i in range(0, len(flat) - 8, 9):
        corners = [tuple(round(v, DECIMALS) for v in flat[i + k:i + k + 3]) for k in (0, 3, 6)]
        if not usable(*corners):
            continue
        # The same triangle twice is one; the same corners wound the other
        # way is the back of a two-sided surface and stays.
        first = corners.index(min(corners))
        key = tuple(corners[first:] + corners[:first])
        if key in seen:
            continue
        seen.add(key)
        for corner in corners:
            out.extend(corner)
    return out


def ground_height(flat, share=0.01):
    """Height of a park's ground in Source units: the level below which only
    `share` of its upward facing collision area lies. The render and collision
    bounds reach far below a park (terrain, sky models), so the lowest point
    can't say where its floor is; this ignores a few deep drains and pits.
    None when it has no upward facing collision."""
    levels = []
    for i in range(0, len(flat) - 8, 9):
        a, b, c = flat[i:i + 3], flat[i + 3:i + 6], flat[i + 6:i + 9]
        n = _cross(_sub(c, a), _sub(b, a))
        size = _length(n)
        # Skate 3's triangles face out clockwise: this normal points out.
        if size > 0 and n[2] / size > 0.7:
            levels.append(((a[2] + b[2] + c[2]) / 3, size * 0.5))
    if not levels:
        return None
    levels.sort()
    total, seen = sum(area for _, area in levels), 0.0
    for z, area in levels:
        seen += area
        if seen >= total * share:
            return round(z, 1)


# Cells of the grid that finds the collision under a drawn triangle.
FILL_CELL = 96.0
# A drawn surface counts as covered when collision lies this far above or
# below it, and is only filled when it faces up at least this much.
FILL_REACH = 24.0
FILL_FACING = 0.35
FILL_MIN_AREA = 4.0


def _cells(lo, hi):
    return range(int(lo // FILL_CELL), int(hi // FILL_CELL) + 1)


def _height_at(tri, x, y):
    """Height of the triangle's plane at (x, y) if the point lies inside the
    triangle seen from above, else None."""
    (ax, ay, az), (bx, by, bz), (cx, cy, cz) = tri
    d = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
    if abs(d) < 1e-9:
        return None
    u = ((by - cy) * (x - cx) + (cx - bx) * (y - cy)) / d
    v = ((cy - ay) * (x - cx) + (ax - cx) * (y - cy)) / d
    w = 1 - u - v
    if min(u, v, w) < -1e-6:
        return None
    return u * az + v * bz + w * cz


def fill_coverage(groups, flat):
    """Collision for drawn surfaces that have none. A park's collision comes
    from its own collision assets; where one is missing or unreadable, the
    board and the player fall through a surface that is plainly there. Each
    upward facing drawn triangle (cutouts like leaves and fences aside) with
    no collision under or over its middle is added, wound the way Skate 3
    winds its collision. Returns (flat list to add, drawn triangles checked)."""
    grid, big = {}, []
    for i in range(0, len(flat) - 8, 9):
        tri = ((flat[i], flat[i + 1], flat[i + 2]), (flat[i + 3], flat[i + 4], flat[i + 5]),
               (flat[i + 6], flat[i + 7], flat[i + 8]))
        xs, ys = [t[0] for t in tri], [t[1] for t in tri]
        cx, cy = _cells(min(xs), max(xs)), _cells(min(ys), max(ys))
        if len(cx) * len(cy) > 400:
            big.append(tri)
            continue
        for gx in cx:
            for gy in cy:
                grid.setdefault((gx, gy), []).append(tri)
    added, checked = [], 0
    for g in groups:
        if g.get('cut'):
            continue
        pos, idx = g['pos'], g['idx']
        for i in range(0, len(idx) - 2, 3):
            a, b, c = (tuple(pos[k * 3:k * 3 + 3]) for k in idx[i:i + 3])
            n = _cross(_sub(c, a), _sub(b, a))
            size = _length(n)
            # Skate 3's triangles face out clockwise: this normal points out.
            if size < FILL_MIN_AREA * 2 or n[2] / size < FILL_FACING:
                continue
            checked += 1
            x, y, z = (a[0] + b[0] + c[0]) / 3, (a[1] + b[1] + c[1]) / 3, (a[2] + b[2] + c[2]) / 3
            covered = False
            for tri in grid.get((int(x // FILL_CELL), int(y // FILL_CELL)), []) + big:
                h = _height_at(tri, x, y)
                if h is not None and abs(h - z) <= FILL_REACH:
                    covered = True
                    break
            if not covered:
                added.extend(a + b + c)
    return added, checked

def _bounds(points):
    if not points:
        return [[0, 0, 0], [0, 0, 0]]
    return [[min(p[a] for p in points) for a in range(3)], [max(p[a] for p in points) for a in range(3)]]


def _points(flat):
    return [tuple(flat[i:i + 3]) for i in range(0, len(flat) - 2, 3)]


def _split(items, max_collision, max_render):
    """Groups of items (kind, ref, centroid), cut along the longest axis at
    the median until each group is small enough."""
    render = sum(1 for it in items if it[0] == 'r')
    collision = len(items) - render
    if render <= max_render and collision <= max_collision:
        return [items]
    spans = []
    for a in range(3):
        values = [it[2][a] for it in items]
        spans.append(max(values) - min(values))
    axis = spans.index(max(spans))
    if spans[axis] <= 0:
        return [items]
    items = sorted(items, key=lambda it: it[2][axis])
    # Cut so both halves hold about the same number of the heavier kind.
    heavy = 'r' if render / max_render >= collision / max_collision else 'c'
    total = render if heavy == 'r' else collision
    seen, cut = 0, len(items) // 2
    for index, it in enumerate(items):
        if it[0] == heavy:
            seen += 1
            if seen * 2 >= total:
                cut = index + 1
                break
    if cut <= 0 or cut >= len(items):
        cut = len(items) // 2
    # A cut has to separate something, or it would never end.
    if items[0][2][axis] == items[-1][2][axis]:
        return [items]
    return _split(items[:cut], max_collision, max_render) + _split(items[cut:], max_collision, max_render)


def tile(piece, max_collision=MAX_COLLISION, max_render=MAX_RENDER):
    """The park piece cut into tile pieces: [(piece dict), ...]. Each keeps
    the park's origin. A piece small enough comes back as one tile."""
    groups = piece['groups']
    collision = clean_collision(piece.get('collision') or [])
    items = []
    for gi, g in enumerate(groups):
        pos, idx = g['pos'], g['idx']
        for t in range(0, len(idx) - 2, 3):
            ia, ib, ic = idx[t] * 3, idx[t + 1] * 3, idx[t + 2] * 3
            centroid = tuple((pos[ia + k] + pos[ib + k] + pos[ic + k]) / 3 for k in range(3))
            items.append(('r', (gi, t), centroid))
    for t in range(0, len(collision), 9):
        centroid = tuple((collision[t + k] + collision[t + 3 + k] + collision[t + 6 + k]) / 3 for k in range(3))
        items.append(('c', t, centroid))
    parts = _split(items, max_collision, max_render) if items else []
    tiles = []
    for n, part in enumerate(parts):
        by_group, flat = {}, []
        for kind, ref, _ in part:
            if kind == 'r':
                by_group.setdefault(ref[0], []).append(ref[1])
            else:
                flat.extend(collision[ref:ref + 9])
        out_groups = []
        for gi in sorted(by_group):
            g = groups[gi]
            pos, uv, idx = g['pos'], g.get('uv') or [], g['idx']
            remap, new_pos, new_uv, new_idx = {}, [], [], []
            for t in by_group[gi]:
                for k in range(3):
                    old = idx[t + k]
                    if old not in remap:
                        remap[old] = len(remap)
                        new_pos.extend(round(v, DECIMALS) for v in pos[old * 3:old * 3 + 3])
                        new_uv.extend(uv[old * 2:old * 2 + 2] if len(uv) >= old * 2 + 2 else (0, 0))
                    new_idx.append(remap[old])
            out = {'tex': g['tex'], 'pos': new_pos, 'uv': new_uv, 'idx': new_idx}
            if g.get('cut'):
                out['cut'] = True
            out_groups.append(out)
        points = [p for g in out_groups for p in _points(g['pos'])] or _points(flat)
        tiles.append({
            'id': f"{piece['id']}_t{n}",
            'name': f"{piece['name']} tile {n}",
            'category': 'Tiles',
            'bounds': _bounds(points),
            'groups': out_groups,
            'collision': flat,
        })
    return tiles
