// Ported from chasmlol/2010-rust-rewrite-mashup (Apache-2.0) at f608f85,
// crates/render_anim/src/skate/rails.rs. Only the math crate changed.

//! Grind rails found in the map's collision: the lips a skater can grind.
//!
//! MW2 collision comes from brushes, the clip mesh and static model collision,
//! so the top of a ledge and its wall rarely share an edge vertex for vertex.
//! A lip is therefore found by probing the geometry around each edge of a
//! walkable face rather than by matching triangles: the ground must fall away
//! just past the edge and nothing may rise there. Surviving edges are merged
//! along their lines across seams and T-junctions, then chained into
//! polylines where they meet at a gentle turn, as the authoring tool does for
//! edges marked sharp.

use std::collections::HashMap;

use glam::Vec3;

/// A face this upward is walkable; its edges are rail candidates.
const UPWARD_Z: f32 = 0.65;
/// XY grid cell for probing, in map units (inches).
const CELL: f32 = 64.0;
/// How far past the lip the probes look.
const PROBE_OUT: f32 = 2.0;
/// Open space the ground must drop below the lip, just past it.
const MIN_DROP: f32 = 3.0;
/// Height above the lip the wall probe runs at.
const WALL_PROBE_UP: f32 = 3.0;
/// Clear height a skater needs over a lip: a face with a ceiling closer than
/// this, such as the back of a hollow ramp shell, is out of reach.
const HEADROOM: f32 = 24.0;
/// Shortest rail kept, after merging and chaining.
const MIN_RAIL: f32 = 24.0;
/// Steepest rail, as rise over length: stair handrails and ramp edges pass.
const MAX_SLOPE: f32 = 0.7;
/// Chains continue through a joint turning less than about 35 degrees.
const MIN_TURN_COS: f32 = 0.82;
/// Two lips this close facing away from each other are the two sides of one
/// thin bar, such as a handrail made from a slim brush: one rail down its middle.
const MAX_BAR: f32 = 4.5;
/// Rail ends this close are the same joint, however the map's numbers round.
const JOINT: f32 = 1.0;
/// Faces this close to parallel are one surface.
const SAME_SURFACE: f32 = 0.99;
/// The skate engine counts rails in a u16.
const MAX_RAILS: usize = u16::MAX as usize;

pub struct RailCensus {
    pub candidates: usize,
    pub lips: usize,
    pub runs: usize,
    pub rails: usize,
}

/// Rails over `tris` (map units, z up), each a polyline of two or more points.
pub fn find(tris: &[[Vec3; 3]]) -> (Vec<Vec<Vec3>>, RailCensus) {
    find_among(tris, tris.len())
}

/// Rails on the edges of the first `candidates` triangles only; the rest are
/// probed for the ground and walls around them but grow no rails of their own.
pub fn find_among(tris: &[[Vec3; 3]], candidates: usize) -> (Vec<Vec<Vec3>>, RailCensus) {
    let grid = Grid::build(tris);
    let mut probe = Probe {
        tris,
        grid: &grid,
        stamp: vec![0; tris.len()],
        round: 0,
        scratch: Vec::new(),
    };

    // Every edge of a walkable face, once. An edge between two walkable faces
    // of one surface is a seam in the surface, not a lip: on a bar narrower
    // than the probe is long, the diagonal of its top would pass for one.
    let key = |v: Vec3| v.to_array().map(|x| (x * 8.).round() as i32);
    let mut edges: HashMap<([i32; 3], [i32; 3]), (Vec3, Vec3, Vec3, Vec3)> = HashMap::new();
    let mut seams: HashMap<([i32; 3], [i32; 3]), bool> = HashMap::new();
    for (index, tri) in tris[..candidates.min(tris.len())].iter().enumerate() {
        let normal = (tri[1] - tri[0]).cross(tri[2] - tri[0]).normalize_or_zero();
        if normal.z <= UPWARD_Z || probe.buried(index, normal) {
            continue;
        }
        let centroid = (tri[0] + tri[1] + tri[2]) / 3.;
        for i in 0..3 {
            let (a, b) = (tri[i], tri[(i + 1) % 3]);
            let (ka, kb) = (key(a), key(b));
            let k = if ka < kb { (ka, kb) } else { (kb, ka) };
            match edges.entry(k) {
                std::collections::hash_map::Entry::Vacant(slot) => {
                    slot.insert((a, b, normal, centroid));
                }
                std::collections::hash_map::Entry::Occupied(slot) => {
                    if key(slot.get().0) == kb && slot.get().2.dot(normal) >= SAME_SURFACE {
                        seams.insert(k, true);
                    }
                }
            }
        }
    }
    let candidates = edges.len();

    let mut lips = Vec::new();
    for (k, (a, b, normal, centroid)) in edges {
        if seams.contains_key(&k) {
            continue;
        }
        let along = b - a;
        let len = along.length();
        if len < 1. || along.z.abs() > MAX_SLOPE * len {
            continue;
        }
        let mid = (a + b) * 0.5;
        let mut out = along.cross(normal).normalize_or_zero();
        if out.dot(centroid - mid) > 0. {
            out = -out;
        }
        let samples: &[f32] = if len < 12. {
            &[0.5]
        } else {
            &[0.25, 0.5, 0.75]
        };
        let passing = samples
            .iter()
            .filter(|&&s| probe.is_lip(a + along * s, out))
            .count();
        if passing * 3 >= samples.len() * 2 {
            lips.push(Lip { a, b, out });
        }
    }
    // The edge map iterates in no fixed order; the rails shouldn't follow it.
    lips.sort_by(|p, q| {
        let k = |l: &Lip| [l.a.x, l.a.y, l.a.z, l.b.x, l.b.y, l.b.z];
        k(p).iter().zip(k(q)).map(|(x, y)| x.total_cmp(&y)).find(|o| o.is_ne()).unwrap_or(std::cmp::Ordering::Equal)
    });
    let lip_count = lips.len();

    let runs = merge_collinear(pair_bars(lips));
    let run_count = runs.len();
    let mut rails = chain(runs);
    rails.retain(|rail| polyline_len(rail) >= MIN_RAIL);
    if rails.len() > MAX_RAILS {
        rails.sort_by(|a, b| polyline_len(b).total_cmp(&polyline_len(a)));
        rails.truncate(MAX_RAILS);
    }
    let census = RailCensus {
        candidates,
        lips: lip_count,
        runs: run_count,
        rails: rails.len(),
    };
    (rails, census)
}

fn polyline_len(points: &[Vec3]) -> f32 {
    points.windows(2).map(|w| w[0].distance(w[1])).sum()
}

struct Grid {
    cells: HashMap<(i32, i32), Vec<u32>>,
}

fn cell_of(v: f32) -> i32 {
    (v / CELL).floor() as i32
}

impl Grid {
    fn build(tris: &[[Vec3; 3]]) -> Self {
        let mut cells: HashMap<(i32, i32), Vec<u32>> = HashMap::new();
        for (index, tri) in tris.iter().enumerate() {
            let min = tri[0].min(tri[1]).min(tri[2]);
            let max = tri[0].max(tri[1]).max(tri[2]);
            for x in cell_of(min.x)..=cell_of(max.x) {
                for y in cell_of(min.y)..=cell_of(max.y) {
                    cells.entry((x, y)).or_default().push(index as u32);
                }
            }
        }
        Self { cells }
    }
}

struct Probe<'a> {
    tris: &'a [[Vec3; 3]],
    grid: &'a Grid,
    stamp: Vec<u32>,
    round: u32,
    scratch: Vec<u32>,
}

impl Probe<'_> {
    /// Past `p` along `out` the ground falls away and nothing rises.
    fn is_lip(&mut self, p: Vec3, out: Vec3) -> bool {
        if self.hit(p + Vec3::Z * 1.5, Vec3::Z, HEADROOM) {
            return false;
        }
        let down_from = p + out * PROBE_OUT + Vec3::Z;
        if self.hit(down_from, -Vec3::Z, 1. + MIN_DROP) {
            return false;
        }
        let across_from = p - out + Vec3::Z * WALL_PROBE_UP;
        !self.hit(across_from, out, 2. + PROBE_OUT)
    }

    /// Whether a face is covered edge to edge by a face of another brush
    /// facing the other way on the same plane: the two are the inside of a
    /// joint, such as the cut between neighbouring slabs of a curved ramp, and
    /// no skater reaches them.
    fn buried(&self, index: usize, normal: Vec3) -> bool {
        let tri = &self.tris[index];
        let centroid = (tri[0] + tri[1] + tri[2]) / 3.;
        let Some(cell) = self.grid.cells.get(&(cell_of(centroid.x), cell_of(centroid.y))) else {
            return false;
        };
        // Points to cover: the middle, and three points near the corners.
        let points = [
            centroid,
            centroid.lerp(tri[0], 0.9),
            centroid.lerp(tri[1], 0.9),
            centroid.lerp(tri[2], 0.9),
        ];
        let mut covered = [false; 4];
        for &other in cell {
            if other as usize == index {
                continue;
            }
            let t = &self.tris[other as usize];
            let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero();
            if n.dot(normal) > -0.999 || (tri[0] - t[0]).dot(n).abs() > 0.05 {
                continue;
            }
            for (done, p) in covered.iter_mut().zip(points) {
                if !*done && (0..3).all(|i| {
                    let (a, b) = (t[i], t[(i + 1) % 3]);
                    (b - a).normalize_or_zero().cross(p - a).dot(n) >= -0.05
                }) {
                    *done = true;
                }
            }
        }
        covered.iter().all(|c| *c)
    }

    /// Whether the segment from `origin` along unit `dir` for `len` crosses
    /// any triangle, either side facing.
    fn hit(&mut self, origin: Vec3, dir: Vec3, len: f32) -> bool {
        let end = origin + dir * len;
        let (min, max) = (origin.min(end), origin.max(end));
        self.round = self.round.wrapping_add(1);
        if self.round == 0 {
            self.stamp.fill(0);
            self.round = 1;
        }
        self.scratch.clear();
        for x in cell_of(min.x)..=cell_of(max.x) {
            for y in cell_of(min.y)..=cell_of(max.y) {
                let Some(cell) = self.grid.cells.get(&(x, y)) else {
                    continue;
                };
                for &index in cell {
                    let seen = &mut self.stamp[index as usize];
                    if *seen != self.round {
                        *seen = self.round;
                        self.scratch.push(index);
                    }
                }
            }
        }
        self.scratch
            .iter()
            .any(|&index| ray_triangle(origin, dir, len, &self.tris[index as usize]))
    }
}

/// Möller–Trumbore, both faces, hits within `(0, len]`.
fn ray_triangle(origin: Vec3, dir: Vec3, len: f32, tri: &[Vec3; 3]) -> bool {
    let e1 = tri[1] - tri[0];
    let e2 = tri[2] - tri[0];
    let p = dir.cross(e2);
    let det = e1.dot(p);
    if det.abs() < 1e-8 {
        return false;
    }
    let inv = 1. / det;
    let s = origin - tri[0];
    let u = s.dot(p) * inv;
    if !(0. ..=1.).contains(&u) {
        return false;
    }
    let q = s.cross(e1);
    let v = dir.dot(q) * inv;
    if v < 0. || u + v > 1. {
        return false;
    }
    let t = e2.dot(q) * inv;
    t > 1e-4 && t <= len
}

/// A lip: an edge of a walkable face with the ground falling away past it,
/// in direction `out`.
struct Lip {
    a: Vec3,
    b: Vec3,
    out: Vec3,
}

/// Where lips face away from each other across a strip no wider than a thin
/// bar, one rail down the middle of the strip replaces the two. The parts of
/// either lip beyond the strip stay as they were.
fn pair_bars(lips: Vec<Lip>) -> Vec<(Vec3, Vec3)> {
    const STEP: f32 = 8.;
    let cell = |v: Vec3| v.to_array().map(|x| (x / STEP).floor() as i32);
    let mut grid: HashMap<[i32; 3], Vec<usize>> = HashMap::new();
    for (i, lip) in lips.iter().enumerate() {
        let len = lip.a.distance(lip.b);
        let n = (len / STEP).ceil().max(1.) as usize;
        let mut last = None;
        for s in 0..=n {
            let c = cell(lip.a.lerp(lip.b, s as f32 / n as f32));
            if last != Some(c) {
                grid.entry(c).or_default().push(i);
                last = Some(c);
            }
        }
    }
    // Along `lips[i]`, the span `[t0, t1]` (as fractions) that `lips[j]` also
    // covers, and how far apart the two lines are.
    let beside = |i: usize, j: usize| -> Option<(f32, f32, f32)> {
        let (p, q) = (&lips[i], &lips[j]);
        let along = p.b - p.a;
        let len = along.length();
        let d = along / len;
        if d.dot((q.b - q.a).normalize_or_zero()).abs() < 0.98 || p.out.dot(q.out) > -0.8 {
            return None;
        }
        // q must lie behind p's lip, over the surface.
        let (qa, qb) = (q.a - p.a, q.b - p.a);
        let off = |v: Vec3| v - d * v.dot(d);
        let gap = (off(qa) + off(qb)) * 0.5;
        if gap.dot(p.out) > -0.05 || gap.length() > MAX_BAR {
            return None;
        }
        let (u, v) = (qa.dot(d), qb.dot(d));
        let (t0, t1) = (u.min(v).max(0.) / len, u.max(v).min(len) / len);
        (t1 > t0).then_some((t0, t1, gap.length()))
    };
    let mut used = vec![false; lips.len()];
    let mut out = Vec::new();
    // Closest pairs first.
    let mut pairs = Vec::new();
    for i in 0..lips.len() {
        let mut seen = std::collections::HashSet::new();
        let len = lips[i].a.distance(lips[i].b);
        let n = (len / STEP).ceil().max(1.) as usize;
        for s in 0..=n {
            let c = cell(lips[i].a.lerp(lips[i].b, s as f32 / n as f32));
            for dx in -1..=1 {
                for dy in -1..=1 {
                    for dz in -1..=1 {
                        let Some(list) = grid.get(&[c[0] + dx, c[1] + dy, c[2] + dz]) else {
                            continue;
                        };
                        for &j in list {
                            if j > i && seen.insert(j) {
                                if let Some((t0, t1, gap)) = beside(i, j) {
                                    let share = (t1 - t0) * len;
                                    if share >= 0.5 * len.min(lips[j].a.distance(lips[j].b)) {
                                        pairs.push((gap, i, j));
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    pairs.sort_by(|x, y| x.0.total_cmp(&y.0).then(x.1.cmp(&y.1)).then(x.2.cmp(&y.2)));
    for (_, i, j) in pairs {
        if used[i] || used[j] {
            continue;
        }
        let Some((t0, t1, _)) = beside(i, j) else {
            continue;
        };
        used[i] = true;
        used[j] = true;
        let (p, q) = (&lips[i], &lips[j]);
        let len = p.a.distance(p.b);
        let d = (p.b - p.a) / len;
        let (ua, ub) = ((q.a - p.a).dot(d), (q.b - p.a).dot(d));
        let on_q = |s: f32| (s - ua) / (ub - ua);
        let (s0, s1) = (t0 * len, t1 * len);
        let at_q = |s: f32| q.a.lerp(q.b, on_q(s));
        out.push((
            p.a.lerp(p.b, t0).lerp(at_q(s0), 0.5),
            p.a.lerp(p.b, t1).lerp(at_q(s1), 0.5),
        ));
        let (v0, v1) = (on_q(s0).clamp(0., 1.), on_q(s1).clamp(0., 1.));
        for (lip, lo, hi) in [(p, t0, t1), (q, v0.min(v1), v0.max(v1))] {
            let len = lip.a.distance(lip.b);
            if lo * len > 1. {
                out.push((lip.a, lip.a.lerp(lip.b, lo)));
            }
            if (1. - hi) * len > 1. {
                out.push((lip.a.lerp(lip.b, hi), lip.b));
            }
        }
    }
    for (i, lip) in lips.iter().enumerate() {
        if !used[i] {
            out.push((lip.a, lip.b));
        }
    }
    out
}

/// Lips on one line, merged into maximal runs where they overlap or touch.
fn merge_collinear(lips: Vec<(Vec3, Vec3)>) -> Vec<(Vec3, Vec3)> {
    let mut lines: HashMap<([i32; 3], [i32; 3]), (Vec3, Vec3, Vec<(f32, f32)>)> = HashMap::new();
    for (mut a, mut b) in lips {
        let mut d = (b - a).normalize_or_zero();
        if d == Vec3::ZERO {
            continue;
        }
        let flip =
            d.x < -1e-4 || (d.x.abs() <= 1e-4 && (d.y < -1e-4 || (d.y.abs() <= 1e-4 && d.z < 0.)));
        if flip {
            d = -d;
            std::mem::swap(&mut a, &mut b);
        }
        let o = a - d * a.dot(d);
        let k = (
            (d * 64.).to_array().map(|x| x.round() as i32),
            (o * 2.).to_array().map(|x| x.round() as i32),
        );
        let line = lines.entry(k).or_insert((d, o, Vec::new()));
        line.2.push((a.dot(line.0), b.dot(line.0)));
    }
    let mut runs = Vec::new();
    for (d, o, mut spans) in lines.into_values() {
        spans.sort_by(|x, y| x.0.total_cmp(&y.0));
        let mut current = spans[0];
        for &(t0, t1) in &spans[1..] {
            if t0 <= current.1 + 1.5 {
                current.1 = current.1.max(t1);
            } else {
                runs.push((o + d * current.0, o + d * current.1));
                current = (t0, t1);
            }
        }
        runs.push((o + d * current.0, o + d * current.1));
    }
    // The line map iterates in no fixed order, and the chains, their order
    // and so the rails' numbers would follow it: the same map must give the
    // same rails every time, or a rebuild mid-grind renumbers the rail
    // under the skater.
    let key = |r: &(Vec3, Vec3)| [r.0.x, r.0.y, r.0.z, r.1.x, r.1.y, r.1.z];
    runs.sort_by(|p, q| key(p).iter().zip(key(q)).map(|(x, y)| x.total_cmp(&y)).find(|o| o.is_ne()).unwrap_or(std::cmp::Ordering::Equal));
    runs
}

/// Runs joined end to end into polylines through joints where exactly two
/// runs meet at a gentle turn. Ends within `JOINT` of each other are one
/// joint, so a corner that a map's numbers land either side of a rounding
/// boundary still joins.
fn chain(runs: Vec<(Vec3, Vec3)>) -> Vec<Vec<Vec3>> {
    // Joint of each end: [run][0 = start, 1 = end].
    let ends: Vec<Vec3> = runs.iter().flat_map(|(a, b)| [*a, *b]).collect();
    let cell = |v: Vec3| v.to_array().map(|x| (x / JOINT).floor() as i32);
    let mut grid: HashMap<[i32; 3], Vec<usize>> = HashMap::new();
    for (i, e) in ends.iter().enumerate() {
        grid.entry(cell(*e)).or_default().push(i);
    }
    let mut group: Vec<usize> = (0..ends.len()).collect();
    fn root(group: &mut [usize], mut i: usize) -> usize {
        while group[i] != i {
            group[i] = group[group[i]];
            i = group[i];
        }
        i
    }
    for (i, e) in ends.iter().enumerate() {
        let c = cell(*e);
        for dx in -1..=1 {
            for dy in -1..=1 {
                for dz in -1..=1 {
                    let Some(list) = grid.get(&[c[0] + dx, c[1] + dy, c[2] + dz]) else {
                        continue;
                    };
                    for &j in list {
                        if j > i && e.distance(ends[j]) < JOINT {
                            let (x, y) = (root(&mut group, i), root(&mut group, j));
                            group[x] = y;
                        }
                    }
                }
            }
        }
    }
    let mut at: HashMap<usize, Vec<usize>> = HashMap::new();
    for i in 0..ends.len() {
        let r = root(&mut group, i);
        at.entry(r).or_default().push(i);
    }
    let joint_of: Vec<usize> = (0..ends.len()).map(|i| root(&mut group, i)).collect();
    let mut used = vec![false; runs.len()];
    // The run continuing from `tip` (an end, as run * 2 + 0|1), arriving along
    // `heading`: the other end it leaves from and the end it reaches.
    let next = |tip: usize, heading: Vec3, used: &[bool]| -> Option<usize> {
        let there = &at[&joint_of[tip]];
        if there.len() != 2 {
            return None;
        }
        let &from = there.iter().find(|&&e| e != tip)?;
        if used[from / 2] {
            return None;
        }
        let leave = (ends[from ^ 1] - ends[from]).normalize_or_zero();
        (heading.dot(leave) >= MIN_TURN_COS).then_some(from)
    };
    let mut rails = Vec::new();
    for start in 0..runs.len() {
        if used[start] {
            continue;
        }
        used[start] = true;
        let (a, b) = runs[start];
        let mut points = std::collections::VecDeque::from([a, b]);
        // Forward from b, then backward from a.
        let mut tip = start * 2 + 1;
        let mut heading = (b - a).normalize_or_zero();
        while let Some(from) = next(tip, heading, &used) {
            used[from / 2] = true;
            let to = ends[from ^ 1];
            heading = (to - ends[tip]).normalize_or_zero();
            tip = from ^ 1;
            points.push_back(to);
        }
        let mut tip = start * 2;
        let mut heading = (a - b).normalize_or_zero();
        while let Some(from) = next(tip, heading, &used) {
            used[from / 2] = true;
            let to = ends[from ^ 1];
            heading = (to - ends[tip]).normalize_or_zero();
            tip = from ^ 1;
            points.push_front(to);
        }
        rails.push(points.into_iter().collect());
    }
    rails
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An axis-aligned box as twelve outward-wound triangles.
    fn cuboid(lo: Vec3, hi: Vec3) -> Vec<[Vec3; 3]> {
        let c = |x: bool, y: bool, z: bool| {
            Vec3::new(if x { hi.x } else { lo.x }, if y { hi.y } else { lo.y }, if z { hi.z } else { lo.z })
        };
        let quads = [
            [c(false, false, true), c(true, false, true), c(true, true, true), c(false, true, true)],
            [c(false, false, false), c(false, true, false), c(true, true, false), c(true, false, false)],
            [c(false, false, false), c(true, false, false), c(true, false, true), c(false, false, true)],
            [c(true, false, false), c(true, true, false), c(true, true, true), c(true, false, true)],
            [c(true, true, false), c(false, true, false), c(false, true, true), c(true, true, true)],
            [c(false, true, false), c(false, false, false), c(false, false, true), c(false, true, true)],
        ];
        quads.iter().flat_map(|q| [[q[0], q[1], q[2]], [q[0], q[2], q[3]]]).collect()
    }

    fn floor() -> Vec<[Vec3; 3]> {
        cuboid(Vec3::new(-400., -400., -8.), Vec3::new(400., 400., 0.))
    }

    fn length(rail: &[Vec3]) -> f32 {
        polyline_len(rail)
    }

    #[test]
    fn a_thin_bar_is_one_rail_down_its_middle() {
        let mut tris = floor();
        tris.extend(cuboid(Vec3::new(0., 0., 20.), Vec3::new(100., 2., 22.)));
        let (rails, _) = find(&tris);
        let bar: Vec<_> = rails.iter().filter(|r| r.iter().all(|p| p.z > 10.)).collect();
        assert_eq!(bar.len(), 1, "{bar:?}");
        assert!((length(bar[0]) - 100.).abs() < 1.5, "{bar:?}");
        assert!(bar[0].iter().all(|p| (p.y - 1.).abs() < 0.1), "{bar:?}");
    }

    #[test]
    fn a_wide_ledge_keeps_its_two_edges() {
        let mut tris = floor();
        tris.extend(cuboid(Vec3::new(0., 0., 20.), Vec3::new(100., 12., 22.)));
        let (rails, _) = find(&tris);
        let bar: Vec<_> = rails.iter().filter(|r| r.iter().all(|p| p.z > 10.)).collect();
        assert_eq!(bar.len(), 2, "{bar:?}");
    }

    #[test]
    fn thin_bars_end_to_end_chain_into_one_rail_even_off_the_whole_unit() {
        let mut tris = floor();
        // Three bars, each meeting the last at a corner that rounds the other way.
        tris.extend(cuboid(Vec3::new(0., 0., 20.49), Vec3::new(100., 2., 22.49)));
        tris.extend(cuboid(Vec3::new(100., 0., 20.51), Vec3::new(200., 2., 22.51)));
        tris.extend(cuboid(Vec3::new(200., 0., 20.5), Vec3::new(300., 2., 22.5)));
        let (rails, _) = find(&tris);
        let bar: Vec<_> = rails.iter().filter(|r| r.iter().all(|p| p.z > 10.)).collect();
        assert_eq!(bar.len(), 1, "{bar:?}");
        assert!((length(bar[0]) - 300.).abs() < 3., "{bar:?}");
    }

    #[test]
    fn a_ledge_edge_is_not_a_seam_when_two_pieces_share_it_the_same_way() {
        // The same ledge built twice over still has its rail.
        let mut tris = floor();
        tris.extend(cuboid(Vec3::new(0., 0., 20.), Vec3::new(100., 12., 22.)));
        tris.extend(cuboid(Vec3::new(0., 0., 20.), Vec3::new(100., 12., 22.)));
        let (rails, _) = find(&tris);
        assert!(rails.iter().any(|r| r.iter().all(|p| p.z > 10.)));
    }

    #[test]
    fn the_joint_between_stacked_brushes_is_not_a_rail() {
        // A slab with a taller one of the same footprint on top: their touching
        // faces are inside the solid, and only the upper top is a ledge.
        let mut tris = floor();
        tris.extend(cuboid(Vec3::new(0., 0., 20.), Vec3::new(100., 50., 30.)));
        tris.extend(cuboid(Vec3::new(0., 0., 30.), Vec3::new(100., 50., 60.)));
        let (rails, _) = find(&tris);
        let up: Vec<_> = rails.iter().filter(|r| r.iter().all(|p| p.z > 10.)).collect();
        assert!(!up.is_empty());
        assert!(up.iter().all(|r| r.iter().all(|p| p.z > 59.)), "{up:?}");
    }

    #[test]
    fn a_ledge_under_a_low_ceiling_is_not_a_rail() {
        let mut tris = floor();
        tris.extend(cuboid(Vec3::new(0., 0., 20.), Vec3::new(100., 50., 30.)));
        tris.extend(cuboid(Vec3::new(-20., -20., 40.), Vec3::new(120., 70., 50.)));
        let (rails, _) = find(&tris);
        assert!(rails.iter().all(|r| r.iter().all(|p| p.z > 45. || p.z < 10.)), "{rails:?}");
    }

    #[test]
    fn the_cut_between_slabs_of_a_steep_ramp_is_not_a_rail() {
        // A 63 degree surface, and inside the solid under it a cut that two
        // slabs share, one face of it facing up: its edge lies on the surface.
        let quad = |a: Vec3, b: Vec3, c: Vec3, d: Vec3, toward: Vec3| {
            let n = (b - a).cross(c - a);
            if n.dot(toward) > 0. {
                vec![[a, b, c], [a, c, d]]
            } else {
                vec![[a, c, b], [a, d, c]]
            }
        };
        let (a, b) = (Vec3::new(0., 0., 0.), Vec3::new(0., 100., 0.));
        let (c, d) = (Vec3::new(10., 100., 20.), Vec3::new(10., 0., 20.));
        let along = Vec3::new(20., 0., 10.);
        let mut tris = quad(a, b, c, d, Vec3::new(-1., 0., 0.5));
        let cut = |toward: Vec3| quad(a, b, b + along, a + along, toward);
        let up_cut = cut(Vec3::new(-1., 0., 2.));
        let down_cut = cut(Vec3::new(1., 0., -2.));
        tris.extend(up_cut.clone());
        let (before, _) = find(&tris);
        tris.extend(down_cut);
        let (after, _) = find(&tris);
        assert!(!before.is_empty(), "the lone cut should look like a ledge");
        assert!(after.is_empty(), "{after:?}");
    }
}
