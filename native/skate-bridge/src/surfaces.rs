//! Fixes players make to a map's collision with the Skate 3 Surface tool.
//!
//! Source maps are built for walking, not for a board with four tiny wheels:
//! a displacement's bumps, a one-inch lip where two brushes meet, a pipe whose
//! physics hull is a handful of slabs. Each leaves the board on a surface that
//! isn't the one the player sees. The tool lets a player mark where:
//!
//! * `Flat`: the surface around the spot is one plane. Bumps and small steps
//!   within the band are pressed onto the best-fit plane.
//! * `Smooth`: the same with a gentle curve (a quadric), for ramps, banks
//!   and pipes, whose shape a plane would flatten.
//! * `Ignore`: pieces of collision lying entirely inside the area (a trim
//!   ledge, a prop's hull) aren't solid for skating. Big surfaces that run
//!   out of the area stay.
//! * rails: polylines that are grindable whatever the geometry looks like.
//!
//! A fix moves vertices by a function of where the vertex is, never of the
//! triangle it belongs to, so triangles that met before still meet after (no
//! cracks open at seams or T-junctions), and it fades to nothing at the
//! region's edge so the fixed patch joins the untouched map. Brush faces are
//! a few big triangles with no vertices to move, so first the triangles over a
//! region are cut along a grid laid on the region (the cuts depend only on
//! where an edge runs, so neighbours are cut at the same points). Everything
//! works in Source units (inches, Z up).

use std::collections::HashSet;

use glam::Vec3;

/// Part of the radius, from the centre, that is fully fixed; the fix fades
/// out over the rest.
const FULL_RADIUS: f32 = 0.7;
/// Fewest distinct vertices a fit needs, per surface kind.
const MIN_FLAT: usize = 3;
const MIN_SMOOTH: usize = 6;
/// Triangles whose face is further than this (cosine) from the aimed
/// surface's aren't part of it: walls beside a ramp, the floor's underside.
const FLAT_COS: f32 = 0.766; // 40 degrees
const SMOOTH_COS: f32 = 0.5; // 60 degrees
/// Rails and regions kept: a runaway file can't stall a map load.
pub const MAX_REGIONS: usize = 4096;
pub const MAX_RAILS: usize = 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Flat,
    Smooth,
    Ignore,
}

#[derive(Clone, Copy, Debug)]
pub struct Region {
    pub kind: Kind,
    pub center: Vec3,
    /// Which way the aimed surface faces.
    pub normal: Vec3,
    pub radius: f32,
    /// How far from the fitted surface a vertex may be and still be pressed
    /// onto it. Keep it under the thickness of the floors in the area.
    pub band: f32,
}

/// What a map's flags say, as the tool saved them.
#[derive(Clone, Debug, Default)]
pub struct Surfaces {
    pub regions: Vec<Region>,
    pub rails: Vec<Vec<Vec3>>,
}

impl Surfaces {
    pub fn is_empty(&self) -> bool {
        self.regions.is_empty() && self.rails.is_empty()
    }

    /// Reads the flat lists Lua sends. Regions are
    /// `{kind (1 flat, 2 smooth, 3 ignore), x, y, z, nx, ny, nz, radius, band, ...}`,
    /// rails `{points, x, y, z, x, y, z, ..., points, ...}`. Anything unusable
    /// is skipped.
    pub fn from_flat(regions: &[f32], rails: &[f32]) -> Self {
        let regions = regions
            .chunks_exact(9)
            .filter_map(|r| {
                let kind = match r[0] as i32 {
                    1 => Kind::Flat,
                    2 => Kind::Smooth,
                    3 => Kind::Ignore,
                    _ => return None,
                };
                let center = Vec3::new(r[1], r[2], r[3]);
                let normal = Vec3::new(r[4], r[5], r[6]).try_normalize()?;
                let (radius, band) = (r[7], r[8]);
                (center.is_finite() && radius.is_finite() && radius >= 4. && band.is_finite())
                    .then_some(Region {
                        kind,
                        center,
                        normal,
                        radius: radius.min(2048.),
                        band: band.clamp(0.5, 64.),
                    })
            })
            .take(MAX_REGIONS)
            .collect();
        let mut out = Vec::new();
        let mut at = 0;
        while at < rails.len() && out.len() < MAX_RAILS {
            let count = rails[at].max(0.) as usize;
            let Some(points) = rails.get(at + 1..at + 1 + count * 3) else {
                break;
            };
            at += 1 + count * 3;
            let line: Vec<Vec3> = points
                .chunks_exact(3)
                .map(|p| Vec3::new(p[0], p[1], p[2]))
                .collect();
            if line.len() >= 2 && line.iter().all(|p| p.is_finite()) {
                out.push(line);
            }
        }
        Self {
            regions,
            rails: out,
        }
    }

    /// Fits each region to the map's own triangles. `tris` is the map as built,
    /// before any flag touched it.
    pub fn fit(&self, tris: &[[Vec3; 3]]) -> Fitted {
        let mut fitted = Fitted {
            grinds: self.rails.clone(),
            ..Fitted::default()
        };
        for region in &self.regions {
            match region.kind {
                Kind::Ignore => {
                    fitted.ignores.push((region.center, region.radius));
                    fitted.notes.push(format!(
                        "ignore at ({:.0} {:.0} {:.0}) radius {:.0}",
                        region.center.x, region.center.y, region.center.z, region.radius
                    ));
                }
                Kind::Flat | Kind::Smooth => match Patch::fit(region, tris) {
                    Ok((patch, note)) => {
                        fitted.patches.push(patch);
                        fitted.notes.push(note);
                    }
                    Err(why) => fitted.notes.push(format!(
                        "{} at ({:.0} {:.0} {:.0}) did nothing: {why}",
                        if region.kind == Kind::Flat {
                            "flat"
                        } else {
                            "smooth"
                        },
                        region.center.x,
                        region.center.y,
                        region.center.z
                    )),
                },
            }
        }
        fitted
    }
}

/// Regions fitted to a map: ready to move any set of triangles.
#[derive(Clone, Debug, Default)]
pub struct Fitted {
    patches: Vec<Patch>,
    ignores: Vec<(Vec3, f32)>,
    grinds: Vec<Vec<Vec3>>,
    /// One line per region, for the console.
    pub notes: Vec<String>,
}

#[derive(Clone, Debug)]
struct Patch {
    center: Vec3,
    n: Vec3,
    u: Vec3,
    v: Vec3,
    radius: f32,
    band: f32,
    /// Grid the triangles over the region are cut along, and how far from the
    /// tangent plane a triangle may be and still be cut.
    step: f32,
    reach: f32,
    /// Height over the tangent plane in units of the radius, as a polynomial
    /// in the position over it (also in units of the radius):
    /// `a + b x + c y + d x^2 + e x y + f y^2`.
    coeffs: [f64; 6],
}

impl Fitted {
    pub fn is_empty(&self) -> bool {
        self.patches.is_empty() && self.ignores.is_empty() && self.grinds.is_empty()
    }

    /// Rails the player drew, to add to the ones found in the map.
    pub fn grinds(&self) -> &[Vec<Vec3>] {
        &self.grinds
    }

    /// Whether the fixes change triangles at all (rails alone don't).
    pub fn edits_triangles(&self) -> bool {
        !self.patches.is_empty() || !self.ignores.is_empty()
    }

    /// Moves `tris` by the flat and smooth regions and drops what the ignore
    /// regions cover. Triangles a fix collapsed are left for the caller's own
    /// sliver filter.
    pub fn apply(&self, tris: &mut Vec<[Vec3; 3]>) {
        for patch in &self.patches {
            patch.tessellate(tris);
            for tri in tris.iter_mut() {
                for v in tri.iter_mut() {
                    *v = patch.warp(*v);
                }
            }
        }
        if !self.ignores.is_empty() {
            tris.retain(|t| {
                !self
                    .ignores
                    .iter()
                    .any(|(c, r)| t.iter().all(|v| v.distance_squared(*c) <= r * r))
            });
        }
    }

    /// Where a vertex ends up. A function of the position alone.
    pub fn warp(&self, mut p: Vec3) -> Vec3 {
        for patch in &self.patches {
            p = patch.warp(p);
        }
        p
    }
}

impl Patch {
    fn tessellate(&self, tris: &mut Vec<[Vec3; 3]>) {
        Grid {
            center: self.center,
            n: self.n,
            half: self.radius,
            step: self.step,
            reach: self.reach,
        }
        .cut(tris);
    }

    fn warp(&self, p: Vec3) -> Vec3 {
        let d = p - self.center;
        let r2 = d.length_squared();
        if r2 >= self.radius * self.radius {
            return p;
        }
        let along = r2.sqrt() / self.radius;
        let radial = if along <= FULL_RADIUS {
            1.
        } else {
            let t = (along - FULL_RADIUS) / (1. - FULL_RADIUS);
            1. - t * t * (3. - 2. * t)
        };
        let off = d.dot(self.n) - self.height(d);
        let size = off.abs();
        let near = if size <= self.band {
            1.
        } else if size >= 2. * self.band {
            0.
        } else {
            1. - (size - self.band) / self.band
        };
        p - self.n * (off * radial * near)
    }

    /// The fitted surface's height over the tangent plane at `d` (from the
    /// centre).
    fn height(&self, d: Vec3) -> f32 {
        let r = f64::from(self.radius);
        let x = f64::from(d.dot(self.u)) / r;
        let y = f64::from(d.dot(self.v)) / r;
        (poly(&self.coeffs, x, y) * r) as f32
    }

    fn fit(region: &Region, tris: &[[Vec3; 3]]) -> Result<(Self, String), &'static str> {
        let n = region.normal;
        let u = n.any_orthonormal_vector();
        let v = n.cross(u);
        let step = (region.radius / 8.).clamp(4., 24.);
        let reach = 2. * region.band
            + region.radius
                * if region.kind == Kind::Smooth {
                    0.5
                } else {
                    0.25
                };
        let min_cos = if region.kind == Kind::Flat {
            FLAT_COS
        } else {
            SMOOTH_COS
        };
        let degree_two = region.kind == Kind::Smooth;
        let grid = Grid {
            center: region.center,
            n,
            half: region.radius,
            step,
            reach,
        };
        // The surface's own vertices: from triangles around the spot that face
        // the way the aimed surface does and lie near its tangent plane, cut
        // so there are vertices to read.
        let mut candidates: Vec<[Vec3; 3]> = tris
            .iter()
            .filter(|t| {
                grid.wants(t)
                    && (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero().dot(n) >= min_cos
            })
            .copied()
            .collect();
        grid.cut(&mut candidates);
        let mut seen = HashSet::new();
        let mut points = Vec::<[f64; 3]>::new();
        let r = f64::from(region.radius);
        for tri in &candidates {
            let normal = (tri[1] - tri[0]).cross(tri[2] - tri[0]).normalize_or_zero();
            if normal.dot(n) < min_cos {
                continue;
            }
            for p in tri {
                let d = *p - region.center;
                if d.length_squared() > region.radius * region.radius || d.dot(n).abs() > reach {
                    continue;
                }
                let key = (d * 4.).round().to_array().map(|x| x as i32);
                if seen.insert(key) {
                    points.push([
                        f64::from(d.dot(u)) / r,
                        f64::from(d.dot(v)) / r,
                        f64::from(d.dot(n)) / r,
                    ]);
                }
            }
        }
        let need = if degree_two { MIN_SMOOTH } else { MIN_FLAT };
        if points.len() < need {
            return Err("no surface of that shape was close enough to fit");
        }
        let band = f64::from(region.band) / r;
        let mut keep: Vec<[f64; 3]> = points.clone();
        let mut coeffs = [0.; 6];
        // Fit, throw out what sits far from the fit (a wall's foot, a floor
        // above), fit again.
        for round in 0..3 {
            coeffs = solve(&keep, degree_two).ok_or("the surface there is too thin to fit")?;
            if round == 2 {
                break;
            }
            let resid: Vec<f64> = points
                .iter()
                .map(|p| (p[2] - poly(&coeffs, p[0], p[1])).abs())
                .collect();
            let next: Vec<[f64; 3]> = points
                .iter()
                .zip(&resid)
                .filter(|(_, e)| **e <= band * 2.)
                .map(|(p, _)| *p)
                .collect();
            if next.len() < need {
                break;
            }
            keep = next;
        }
        let errors: Vec<f64> = keep
            .iter()
            .map(|p| (p[2] - poly(&coeffs, p[0], p[1])) * r)
            .collect();
        let rms = (errors.iter().map(|e| e * e).sum::<f64>() / errors.len() as f64).sqrt();
        let worst = errors.iter().fold(0f64, |m, e| m.max(e.abs()));
        let note = format!(
            "{} at ({:.0} {:.0} {:.0}) radius {:.0}: fitted {} vertices, bumps {:.2} units rms, {:.2} at most",
            if degree_two { "smooth" } else { "flat" },
            region.center.x,
            region.center.y,
            region.center.z,
            region.radius,
            keep.len(),
            rms,
            worst
        );
        Ok((
            Self {
                center: region.center,
                n,
                u,
                v,
                radius: region.radius,
                band: region.band,
                step,
                reach,
                coeffs,
            },
            note,
        ))
    }
}

/// The square lattice (in X and Y) over a region that triangles are cut along.
struct Grid {
    center: Vec3,
    n: Vec3,
    /// Half the square's side.
    half: f32,
    step: f32,
    reach: f32,
}

impl Grid {
    /// Whether the triangle is one to cut: over the square and near the aimed
    /// surface's tangent plane.
    fn wants(&self, t: &[Vec3; 3]) -> bool {
        let (lo, hi) = (
            t[0].min(t[1]).min(t[2]) - self.center,
            t[0].max(t[1]).max(t[2]) - self.center,
        );
        if lo.x > self.half || lo.y > self.half || hi.x < -self.half || hi.y < -self.half {
            return false;
        }
        let heights = t.map(|v| (v - self.center).dot(self.n));
        let (low, high) = (
            heights.iter().cloned().fold(f32::MAX, f32::min),
            heights.iter().cloned().fold(f32::MIN, f32::max),
        );
        if low > self.reach || high < -self.reach {
            return false;
        }
        true
    }

    /// Cuts every triangle `wants` along the lattice, and along the square's
    /// sides where it runs out of it, into convex pieces fanned into triangles.
    fn cut(&self, tris: &mut Vec<[Vec3; 3]>) {
        let mut out = Vec::with_capacity(tris.len());
        for t in tris.iter() {
            if !self.wants(t) {
                out.push(*t);
                continue;
            }
            let mut pieces = vec![t.to_vec()];
            for axis in 0..2 {
                let origin = self.center[axis] - self.half;
                let last = (2. * self.half / self.step).ceil() as i32;
                let lo = t.iter().map(|v| v[axis]).fold(f32::MAX, f32::min);
                let hi = t.iter().map(|v| v[axis]).fold(f32::MIN, f32::max);
                let first = (((lo - origin) / self.step).floor() as i32).max(0);
                let end = (((hi - origin) / self.step).ceil() as i32).min(last);
                for k in first..=end {
                    let line = if k == last {
                        self.center[axis] + self.half
                    } else {
                        origin + k as f32 * self.step
                    };
                    let mut next = Vec::with_capacity(pieces.len() + 1);
                    for piece in pieces {
                        split(piece, axis, line, &mut next);
                    }
                    pieces = next;
                }
            }
            for piece in pieces {
                for i in 1..piece.len().saturating_sub(1) {
                    out.push([piece[0], piece[i], piece[i + 1]]);
                }
            }
        }
        *tris = out;
    }
}

/// Splits a convex polygon by the plane `axis = line`, keeping its winding.
/// The point where an edge crosses is worked out from the edge's endpoints in
/// a fixed order, so two triangles sharing the edge get the same point.
fn split(poly: Vec<Vec3>, axis: usize, line: f32, out: &mut Vec<Vec<Vec3>>) {
    let (mut below, mut above) = (Vec::new(), Vec::new());
    let n = poly.len();
    for i in 0..n {
        let (a, b) = (poly[i], poly[(i + 1) % n]);
        let (da, db) = (a[axis] - line, b[axis] - line);
        if da <= 0. {
            below.push(a);
        }
        if da >= 0. {
            above.push(a);
        }
        if (da < 0. && db > 0.) || (da > 0. && db < 0.) {
            let (p, q) = if a.to_array().map(f32::to_bits) <= b.to_array().map(f32::to_bits) {
                (a, b)
            } else {
                (b, a)
            };
            let mut at = p + (q - p) * ((line - p[axis]) / (q[axis] - p[axis]));
            at[axis] = line;
            below.push(at);
            above.push(at);
        }
    }
    for side in [below, above] {
        if side.len() >= 3 {
            out.push(side);
        }
    }
}

fn poly(c: &[f64; 6], x: f64, y: f64) -> f64 {
    c[0] + c[1] * x + c[2] * y + c[3] * x * x + c[4] * x * y + c[5] * y * y
}

/// Least squares for the height over `(x, y)`: a plane, or a quadric.
fn solve(points: &[[f64; 3]], quadric: bool) -> Option<[f64; 6]> {
    let terms = if quadric { 6 } else { 3 };
    let mut m = [[0f64; 7]; 6];
    for p in points {
        let (x, y, h) = (p[0], p[1], p[2]);
        let row = [1., x, y, x * x, x * y, y * y];
        for i in 0..terms {
            for j in 0..terms {
                m[i][j] += row[i] * row[j];
            }
            m[i][6] += row[i] * h;
        }
    }
    for i in 0..terms {
        m[i][i] += 1e-9;
    }
    for col in 0..terms {
        let pivot = (col..terms).max_by(|&a, &b| m[a][col].abs().total_cmp(&m[b][col].abs()))?;
        if m[pivot][col].abs() < 1e-7 {
            return None;
        }
        m.swap(col, pivot);
        for row in 0..terms {
            if row == col {
                continue;
            }
            let k = m[row][col] / m[col][col];
            for j in col..7 {
                m[row][j] -= k * m[col][j];
            }
        }
    }
    let mut out = [0f64; 6];
    for i in 0..terms {
        out[i] = m[i][6] / m[i][i];
    }
    out.iter().all(|c| c.is_finite()).then_some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A square floor of `cells` x `cells` quads, `size` units a side, as
    /// triangles over heights from `height(x, y)`, facing up.
    fn floor(cells: usize, size: f32, height: impl Fn(f32, f32) -> f32) -> Vec<[Vec3; 3]> {
        let step = size / cells as f32;
        let at = |i: usize, j: usize| {
            let x = -size / 2. + i as f32 * step;
            let y = -size / 2. + j as f32 * step;
            Vec3::new(x, y, height(x, y))
        };
        let mut out = Vec::new();
        for i in 0..cells {
            for j in 0..cells {
                let (a, b, c, d) = (at(i, j), at(i + 1, j), at(i + 1, j + 1), at(i, j + 1));
                out.push([a, b, c]);
                out.push([a, c, d]);
            }
        }
        out
    }

    fn region(kind: Kind, radius: f32) -> Region {
        Region {
            kind,
            center: Vec3::ZERO,
            normal: Vec3::Z,
            radius,
            band: 6.,
        }
    }

    fn bumpy(x: f32, y: f32) -> f32 {
        // Deterministic roughness up to about 1.5 units.
        1.5 * ((x * 0.37).sin() * (y * 0.53).cos())
    }

    fn spread(tris: &[[Vec3; 3]], within: f32) -> f32 {
        let zs: Vec<f32> = tris
            .iter()
            .flatten()
            .filter(|v| v.truncate().length() <= within)
            .map(|v| v.z)
            .collect();
        zs.iter().cloned().fold(f32::MIN, f32::max) - zs.iter().cloned().fold(f32::MAX, f32::min)
    }

    #[test]
    fn flat_presses_bumps_onto_a_plane_and_leaves_the_far_map_alone() {
        let map = floor(32, 256., bumpy);
        let fitted = Surfaces {
            regions: vec![region(Kind::Flat, 96.)],
            rails: vec![],
        }
        .fit(&map);
        assert_eq!(fitted.notes.len(), 1, "{:?}", fitted.notes);
        let before = spread(&map, 60.);
        let mut fixed = map.clone();
        fitted.apply(&mut fixed);
        // Fully fixed out to 0.7 of the radius.
        let after = spread(&fixed, 0.7 * 96. - 4.);
        assert!(
            before > 2. && after < 0.15,
            "before {before}, after {after}"
        );
        // Outside the radius nothing moved: the map's own vertices there are
        // all still where they were.
        let after: std::collections::HashSet<[u32; 3]> = fixed
            .iter()
            .flatten()
            .map(|v| v.to_array().map(f32::to_bits))
            .collect();
        for v in map.iter().flatten() {
            if v.truncate().length() >= 96. {
                assert!(
                    after.contains(&v.to_array().map(f32::to_bits)),
                    "{v:?} moved"
                );
            }
        }
    }

    #[test]
    fn a_small_step_between_brushes_goes_flat() {
        // Left half at 0, right half 2 units up, a riser between them.
        let mut map = floor(16, 256., |x, _| if x < 0. { 0. } else { 2. });
        // The grid's own diagonal triangles bridge the step: drop them and
        // lay explicit floors and a riser instead.
        map.clear();
        let quad = |x0: f32, x1: f32, z: f32| {
            let (a, b, c, d) = (
                Vec3::new(x0, -128., z),
                Vec3::new(x1, -128., z),
                Vec3::new(x1, 128., z),
                Vec3::new(x0, 128., z),
            );
            [[a, b, c], [a, c, d]]
        };
        map.extend(quad(-128., 0., 0.));
        map.extend(quad(0., 128., 2.));
        // Riser facing -x at x = 0.
        let (a, b, c, d) = (
            Vec3::new(0., -128., 0.),
            Vec3::new(0., 128., 0.),
            Vec3::new(0., 128., 2.),
            Vec3::new(0., -128., 2.),
        );
        map.push([a, c, b]);
        map.push([a, d, c]);
        let fitted = Surfaces {
            regions: vec![region(Kind::Flat, 120.)],
            rails: vec![],
        }
        .fit(&map);
        let mut fixed = map.clone();
        fitted.apply(&mut fixed);
        // Both sides of the old step now meet at one height: the plane fitted
        // through it is a gentle slope, not a step.
        let mut at_step = std::collections::HashMap::<i32, Vec<f32>>::new();
        for v in fixed
            .iter()
            .flatten()
            .filter(|v| v.x.abs() < 1e-3 && v.y.abs() < 60.)
        {
            at_step
                .entry((v.y * 10.).round() as i32)
                .or_default()
                .push(v.z);
        }
        assert!(!at_step.is_empty());
        for zs in at_step.values() {
            let spread = zs.iter().cloned().fold(f32::MIN, f32::max)
                - zs.iter().cloned().fold(f32::MAX, f32::min);
            assert!(spread < 1e-3, "step is still {spread} units");
        }
        // The riser has no area left.
        let wall: f32 = fixed
            .iter()
            .filter(|t| ((t[0] + t[1] + t[2]) / 3.).truncate().length() < 70.)
            .map(|t| (t[1] - t[0]).cross(t[2] - t[0]))
            .filter(|c| c.z.abs() < 0.01 * c.length())
            .map(|c| c.length() / 2.)
            .sum();
        assert!(wall < 1., "riser area {wall}");
    }

    #[test]
    fn smooth_keeps_a_curve_and_drops_the_noise() {
        // A bowl: z = x^2 / 400, plus roughness.
        let bowl = |x: f32, y: f32| x * x / 400. + y * y / 800.;
        let rough = |x: f32, y: f32| bowl(x, y) + bumpy(x, y);
        let map = floor(32, 256., rough);
        let fitted = Surfaces {
            regions: vec![region(Kind::Smooth, 100.)],
            rails: vec![],
        }
        .fit(&map);
        let mut fixed = map.clone();
        fitted.apply(&mut fixed);
        let worst = fixed
            .iter()
            .flatten()
            .filter(|v| v.truncate().length() < 60.)
            .map(|v| (v.z - bowl(v.x, v.y)).abs())
            .fold(0f32, f32::max);
        assert!(worst < 0.3, "bowl is {worst} units off its curve");
        // A plane would have flattened it: the rim is still higher.
        let rim = fixed
            .iter()
            .flatten()
            .filter(|v| (v.x - 56.).abs() < 1. && v.y.abs() < 1.)
            .map(|v| v.z)
            .next()
            .unwrap();
        assert!(rim > 6., "rim at {rim}");
    }

    /// What a triangle covers seen from above.
    fn shadow(tris: &[[Vec3; 3]]) -> f32 {
        tris.iter()
            .map(|t| (t[1] - t[0]).cross(t[2] - t[0]).z.abs() / 2.)
            .sum()
    }

    #[test]
    fn cutting_and_moving_leaves_no_gap_and_no_overlap() {
        // Two big triangles, one cut diagonal, far larger than the region.
        let (a, b, c, d) = (
            Vec3::new(-500., -500., 0.),
            Vec3::new(500., -500., 0.),
            Vec3::new(500., 500., 0.),
            Vec3::new(-500., 500., 0.),
        );
        let map = vec![[a, b, c], [a, c, d]];
        let fitted = Surfaces {
            regions: vec![Region {
                center: Vec3::new(30., 10., 0.),
                ..region(Kind::Flat, 64.)
            }],
            rails: vec![],
        }
        .fit(&map);
        assert!(
            !fitted.notes[0].contains("did nothing"),
            "{:?}",
            fitted.notes
        );
        let mut fixed = map.clone();
        fitted.apply(&mut fixed);
        assert!(fixed.len() > 100, "only {} pieces", fixed.len());
        let (before, after) = (shadow(&map), shadow(&fixed));
        assert!(
            (before - after).abs() < before * 1e-4,
            "{before} vs {after}"
        );
        // Every edge is shared by exactly two triangles unless it is the
        // outline, so there's no T-junction in the cut.
        let key = |v: Vec3| v.to_array().map(|x| (x * 100.).round() as i64);
        let mut edges = std::collections::HashMap::<([i64; 3], [i64; 3]), i32>::new();
        for t in &fixed {
            for i in 0..3 {
                let (p, q) = (key(t[i]), key(t[(i + 1) % 3]));
                *edges.entry((p.min(q), p.max(q))).or_default() += 1;
            }
        }
        let mut lone_inside = 0;
        for ((p, q), n) in &edges {
            let inside = |k: &[i64; 3]| k[0].abs() < 49_000 && k[1].abs() < 49_000;
            if *n == 1 && inside(p) && inside(q) {
                lone_inside += 1;
            }
        }
        assert_eq!(lone_inside, 0, "edges with no partner inside the outline");
    }

    #[test]
    fn ignore_drops_small_pieces_inside_and_leaves_big_surfaces() {
        let tiles = floor(32, 128., |_, _| 0.);
        let mut map = tiles.clone();
        // A big floor under everything, which runs out of the area.
        map.push([
            Vec3::new(-500., -500., -8.),
            Vec3::new(500., -500., -8.),
            Vec3::new(0., 500., -8.),
        ]);
        let total = map.len();
        let at = Vec3::new(20., 0., 0.);
        let fitted = Surfaces {
            regions: vec![Region {
                center: at,
                ..region(Kind::Ignore, 20.)
            }],
            rails: vec![],
        }
        .fit(&map);
        let mut fixed = map.clone();
        fitted.apply(&mut fixed);
        assert!(
            fixed.len() < total - 40 && fixed.len() > total - 200,
            "{} of {total}",
            fixed.len()
        );
        assert!(
            fixed
                .iter()
                .all(|t| !t.iter().all(|v| v.distance(at) <= 20.))
        );
        // The big triangle is untouched.
        assert_eq!(fixed.last(), map.last());
    }

    #[test]
    fn a_region_with_no_surface_under_it_does_nothing() {
        let map = floor(8, 128., |_, _| 0.);
        let fitted = Surfaces {
            regions: vec![Region {
                center: Vec3::new(0., 0., 500.),
                ..region(Kind::Flat, 60.)
            }],
            rails: vec![],
        }
        .fit(&map);
        assert!(
            fitted.notes[0].contains("did nothing"),
            "{:?}",
            fitted.notes
        );
        let mut fixed = map.clone();
        fitted.apply(&mut fixed);
        assert_eq!(fixed, map);
    }

    #[test]
    fn a_wall_beside_the_floor_is_not_pulled_into_the_fit() {
        let mut map = floor(16, 256., |_, _| 0.);
        // A wall rising from x = 60, 100 units tall.
        let (a, b, c, d) = (
            Vec3::new(60., -128., 0.),
            Vec3::new(60., 128., 0.),
            Vec3::new(60., 128., 100.),
            Vec3::new(60., -128., 100.),
        );
        map.push([a, c, b]);
        map.push([a, d, c]);
        let fitted = Surfaces {
            regions: vec![region(Kind::Flat, 120.)],
            rails: vec![],
        }
        .fit(&map);
        let mut fixed = map.clone();
        fitted.apply(&mut fixed);
        let top = fixed
            .last()
            .unwrap()
            .iter()
            .map(|v| v.z)
            .fold(0f32, f32::max);
        assert!((top - 100.).abs() < 1e-3, "the wall's top moved to {top}");
        assert!(fixed[0].iter().all(|v| v.z.abs() < 1e-3));
    }

    #[test]
    fn reads_the_flat_lists_from_lua() {
        let s = Surfaces::from_flat(
            &[
                1.,
                10.,
                20.,
                30.,
                0.,
                0.,
                1.,
                64.,
                6., // flat
                9.,
                0.,
                0.,
                0.,
                0.,
                0.,
                1.,
                64.,
                6., // unknown kind
                3.,
                0.,
                0.,
                0.,
                0.,
                0.,
                0.,
                64.,
                6., // no direction
                2.,
                0.,
                0.,
                0.,
                0.,
                0.,
                1.,
                f32::NAN,
                6., // bad radius
            ],
            &[
                3., 0., 0., 0., 1., 0., 0., 2., 0., 0., 1., 5., 5., 5., 1., 1., 1.,
            ],
        );
        assert_eq!(s.regions.len(), 1);
        assert_eq!(s.regions[0].kind, Kind::Flat);
        // One three-point rail; the one-point rail is skipped.
        assert_eq!(s.rails.len(), 1);
        assert_eq!(s.rails[0].len(), 3);
    }
}

#[cfg(test)]
mod bench {
    use super::*;

    #[test]
    #[ignore]
    fn big_map_with_many_regions() {
        let n = 400usize;
        let mut tris = Vec::new();
        for i in 0..n {
            for j in 0..n {
                let p = |a: usize, b: usize| {
                    let (x, y) = (a as f32 * 16., b as f32 * 16.);
                    Vec3::new(x, y, ((x * 0.37).sin() * (y * 0.53).cos()) * 1.5)
                };
                tris.push([p(i, j), p(i + 1, j), p(i + 1, j + 1)]);
                tris.push([p(i, j), p(i + 1, j + 1), p(i, j + 1)]);
            }
        }
        let regions: Vec<Region> = (0..60)
            .map(|k| Region {
                kind: if k % 2 == 0 { Kind::Flat } else { Kind::Smooth },
                center: Vec3::new(500. + k as f32 * 90., 3000., 0.),
                normal: Vec3::Z,
                radius: 64.,
                band: 6.,
            })
            .collect();
        let started = std::time::Instant::now();
        let fitted = Surfaces { regions, rails: vec![] }.fit(&tris);
        let fit = started.elapsed();
        let mut copy = tris.clone();
        let started = std::time::Instant::now();
        fitted.apply(&mut copy);
        eprintln!("{} tris: fit {:?}, apply {:?}, {} after", tris.len(), fit, started.elapsed(), copy.len());
    }
}
