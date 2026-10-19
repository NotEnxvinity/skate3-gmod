//! Turns Source collision (Z up, inches) into what a Skate session rides:
//! triangles and grind rails in Skate space.

use std::collections::HashSet;

use glam::Vec3;

use crate::surfaces::Fitted;
use crate::{collision, rails};

/// Collision ready for `Session::new` or `CollisionBuilder::build`.
pub struct World {
    pub triangles: Vec<[[f32; 3]; 3]>,
    /// Grind rails, each a polyline of two or more points.
    pub rails: Vec<Vec<[f32; 3]>>,
    pub census: rails::RailCensus,
}

/// Source collision triangles plus brushes given as planes. Triangles must be
/// wound counterclockwise seen from outside; degenerate and duplicate faces
/// are dropped.
pub fn build(triangles: &[[Vec3; 3]], brushes: &[Vec<[f32; 4]>]) -> World {
    finish(&collect(triangles, brushes), &Fitted::default())
}

/// The map's solid faces as triangles (Source units), brushes cut into
/// faces, slivers and duplicates dropped: what the players' surface fixes
/// are fitted to and applied over.
pub fn collect(triangles: &[[Vec3; 3]], brushes: &[Vec<[f32; 4]>]) -> Vec<[Vec3; 3]> {
    let mut out = Vec::<[Vec3; 3]>::new();
    let mut push = |p: [Vec3; 3]| {
        if usable(&p) {
            out.push(p);
        }
    };
    for tri in triangles {
        push(*tri);
    }
    for planes in brushes {
        for face in collision::brush_faces(planes) {
            for i in 1..face.len() - 1 {
                push([face[0], face[i], face[i + 1]]);
            }
        }
    }
    dedupe(&mut out);
    drop_internal(&mut out);
    out
}

/// Faces that sit exactly against an opposite-facing face are inside the
/// solid, not on it: where separate brushes or models meet (a pipe built from
/// wedges, floor tiles side by side) each leaves a wall at the seam. Left in,
/// the engine's edge logic sees the wall's top edge under every seam and
/// pushes a rolling wheel back with a sideways normal. Floors and ceilings
/// (flatter than about 25 degrees) stay, so ledges still find their lips.
fn drop_internal(tris: &mut Vec<[Vec3; 3]>) {
    const CELL: f32 = 32.;
    const FAR: usize = 512;
    let normal = |t: &[Vec3; 3]| (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero();
    let normals: Vec<Vec3> = tris.iter().map(normal).collect();
    let cell = |v: f32| (v / CELL).floor() as i32;
    let mut grid = std::collections::HashMap::<(i32, i32, i32), Vec<u32>>::new();
    let mut big = Vec::<u32>::new();
    for (i, t) in tris.iter().enumerate() {
        if normals[i] == Vec3::ZERO {
            continue;
        }
        let lo = t[0].min(t[1]).min(t[2]) - Vec3::splat(0.2);
        let hi = t[0].max(t[1]).max(t[2]) + Vec3::splat(0.2);
        let (a, b) = ((cell(lo.x), cell(lo.y), cell(lo.z)), (cell(hi.x), cell(hi.y), cell(hi.z)));
        let count = (b.0 - a.0 + 1) as usize * (b.1 - a.1 + 1) as usize * (b.2 - a.2 + 1) as usize;
        if count > FAR {
            big.push(i as u32);
            continue;
        }
        for x in a.0..=b.0 {
            for y in a.1..=b.1 {
                for z in a.2..=b.2 {
                    grid.entry((x, y, z)).or_default().push(i as u32);
                }
            }
        }
    }
    let covered = |i: usize, p: Vec3| {
        let near = grid
            .get(&(cell(p.x), cell(p.y), cell(p.z)))
            .into_iter()
            .flatten()
            .chain(&big);
        near.into_iter().any(|&j| {
            let j = j as usize;
            let (n, u) = (normals[j], &tris[j]);
            if j == i || n.dot(normals[i]) > -0.999 || (p - u[0]).dot(n).abs() > 0.1 {
                return false;
            }
            (0..3).all(|k| {
                let (a, b) = (u[k], u[(k + 1) % 3]);
                let edge = b - a;
                edge.cross(p - a).dot(n) >= -0.2 * edge.length()
            })
        })
    };
    let drop: Vec<bool> = (0..tris.len())
        .map(|i| {
            if normals[i] == Vec3::ZERO || normals[i].z.abs() > 0.9 {
                return false;
            }
            let t = &tris[i];
            let c = (t[0] + t[1] + t[2]) / 3.;
            covered(i, c) && t.iter().all(|v| covered(i, (c + *v) / 2.))
        })
        .collect();
    let mut i = 0;
    tris.retain(|_| {
        i += 1;
        !drop[i - 1]
    });
}

fn dedupe(out: &mut Vec<[Vec3; 3]>) {
    let mut seen = HashSet::new();
    out.retain(|p| {
        let mut k = p.map(|v| v.to_array().map(|x| (x * 8.).round() as i32));
        k.sort();
        seen.insert(k)
    });
}

/// `collect`'s triangles with the players' surface fixes applied, and the
/// rails found on the result.
pub fn finish(collected: &[[Vec3; 3]], fixes: &Fitted) -> World {
    let mut fixed;
    let out: &[[Vec3; 3]] = if fixes.edits_triangles() {
        fixed = collected.to_vec();
        fixes.apply(&mut fixed);
        fixed.retain(usable);
        dedupe(&mut fixed);
        drop_internal(&mut fixed);
        &fixed
    } else {
        collected
    };
    let (found, census) = rails::find(out);
    let mut all_rails: Vec<Vec<[f32; 3]>> = fixes
        .grinds()
        .iter()
        .map(|rail| {
            rail.iter()
                .map(|p| collision::to_skate(*p).to_array())
                .collect()
        })
        .collect();
    let room = u16::MAX as usize - all_rails.len().min(u16::MAX as usize);
    all_rails.extend(found.into_iter().take(room).map(|rail| {
        rail.into_iter()
            .map(|p| collision::to_skate(p).to_array())
            .collect()
    }));
    // Ramps at small steps go in after the rails are found, so they hide none.
    let ramps = if fixes.lip() > 0. {
        let mut ramps = crate::surfaces::lips(out, fixes.lip());
        ramps.retain(usable);
        ramps
    } else {
        Vec::new()
    };
    World {
        triangles: out
            .iter()
            .chain(&ramps)
            .map(|p| p.map(|v| collision::to_skate(v).to_array()))
            .collect(),
        rails: all_rails,
        census,
    }
}

/// Tiny or needle-thin triangles give the contact solver normals it can't
/// trust, so they go.
fn usable(p: &[Vec3; 3]) -> bool {
    let cross = (p[1] - p[0]).cross(p[2] - p[0]).length();
    let longest = [p[1] - p[0], p[2] - p[1], p[0] - p[2]]
        .iter()
        .map(|e| e.length_squared())
        .fold(0., f32::max);
    p.iter().all(|v| v.is_finite()) && cross > 0.03 && cross > 1e-3 * longest
}

/// Collision for objects added on top of a built map, such as the props
/// players spawn: their triangles and the rails on them, in Skate space.
pub struct Extra {
    pub triangles: Vec<[[f32; 3]; 3]>,
    pub rails: Vec<Vec<[f32; 3]>>,
}

/// `extra` (Source units, counterclockwise from outside) laid over `map`, the
/// triangles of a built [`World`]. Rails grow only on the extra objects; the
/// map is there so a prop standing on the floor doesn't count its bottom
/// edges as lips.
pub fn extra(map: &[[[f32; 3]; 3]], extra: &[[Vec3; 3]], fixes: &Fitted) -> Extra {
    let mut tris: Vec<[Vec3; 3]> = extra.iter().copied().filter(usable).collect();
    if fixes.edits_triangles() {
        fixes.apply(&mut tris);
        tris.retain(usable);
    }
    drop_internal(&mut tris);
    let own = tris.len();
    if own == 0 {
        return Extra {
            triangles: Vec::new(),
            rails: Vec::new(),
        };
    }
    tris.extend(
        map.iter()
            .map(|t| t.map(|v| collision::from_skate(Vec3::from_array(v)))),
    );
    let (found, _) = rails::find_among(&tris, own);
    tris.truncate(own);
    Extra {
        triangles: tris
            .into_iter()
            .map(|p| p.map(|v| collision::to_skate(v).to_array()))
            .collect(),
        rails: found
            .into_iter()
            .map(|rail| {
                rail.into_iter()
                    .map(|p| collision::to_skate(p).to_array())
                    .collect()
            })
            .collect(),
    }
}

/// An axis-aligned box brush, `min..max` in Source units.
pub fn box_brush(min: Vec3, max: Vec3) -> Vec<[f32; 4]> {
    vec![
        [1., 0., 0., max.x],
        [-1., 0., 0., -min.x],
        [0., 1., 0., max.y],
        [0., -1., 0., -min.y],
        [0., 0., 1., max.z],
        [0., 0., -1., -min.z],
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::surfaces::{Kind, Region, Surfaces};

    #[test]
    fn ledge_on_a_floor_grows_rails_on_its_top_edges() {
        let world = build(
            &[],
            &[
                box_brush(Vec3::new(-1024., -1024., -16.), Vec3::new(1024., 1024., 0.)),
                box_brush(Vec3::new(-128., -16., 0.), Vec3::new(128., 16., 16.)),
            ],
        );
        assert!(!world.triangles.is_empty());
        // The ledge's two long top edges are lips; the floor's outer edges are too.
        let ledge_rails = world
            .rails
            .iter()
            .filter(|r| r.iter().all(|p| (p[1] - 16. * 0.0254).abs() < 1e-3))
            .count();
        assert!(ledge_rails >= 2, "found {} ledge rails", ledge_rails);
    }

    #[test]
    fn walls_between_touching_brushes_go_but_floors_stay() {
        let a = box_brush(Vec3::new(0., 0., 0.), Vec3::new(64., 64., 64.));
        let b = box_brush(Vec3::new(64., 0., 0.), Vec3::new(128., 64., 64.));
        let one = collect(&[], &[a.clone()]).len();
        let both = collect(&[], &[a, b]);
        // Each box is 12 triangles; the two touching walls (4) are gone.
        assert_eq!(one, 12);
        assert_eq!(both.len(), 24 - 4);
        assert!(both.iter().all(|t| {
            let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
            !(n.x.abs() > 0.99 && t.iter().all(|v| (v.x - 64.).abs() < 1e-3))
        }));
    }

    fn ledge_map() -> Vec<[Vec3; 3]> {
        collect(
            &[],
            &[
                box_brush(Vec3::new(-1024., -1024., -16.), Vec3::new(1024., 1024., 0.)),
                box_brush(Vec3::new(-40., -16., 0.), Vec3::new(40., 16., 4.)),
            ],
        )
    }

    fn ledge_rails(world: &World) -> usize {
        world
            .rails
            .iter()
            .filter(|r| r.iter().all(|p| (p[1] - 4. * 0.0254).abs() < 1e-3))
            .count()
    }

    #[test]
    fn a_four_unit_lip_is_a_rail_until_the_player_flattens_it() {
        let map = ledge_map();
        assert!(ledge_rails(&finish(&map, &Fitted::default())) >= 2);
        let fixes = Surfaces {
            regions: vec![Region {
                kind: Kind::Flat,
                center: Vec3::new(0., 0., 1.),
                normal: Vec3::Z,
                radius: 200.,
                band: 6.,
            }],
            rails: vec![],
            ..Default::default()
        }
        .fit(&map);
        let world = finish(&map, &fixes);
        assert_eq!(ledge_rails(&world), 0);
        // The floor is still there, now with no step in it.
        assert!(!world.triangles.is_empty());
    }

    #[test]
    fn ignoring_the_ledge_removes_it_and_a_drawn_rail_is_added() {
        let map = ledge_map();
        let fixes = Surfaces {
            regions: vec![Region {
                kind: Kind::Ignore,
                center: Vec3::new(0., 0., 1.),
                normal: Vec3::Z,
                radius: 60.,
                band: 6.,
            }],
            rails: vec![vec![Vec3::new(0., 100., 5.), Vec3::new(100., 100., 5.)]],
            ..Default::default()
        }
        .fit(&map);
        let world = finish(&map, &fixes);
        assert_eq!(ledge_rails(&world), 0);
        // The drawn rail comes first.
        assert_eq!(world.rails[0].len(), 2);
        assert!((world.rails[0][0][1] - 5. * 0.0254).abs() < 1e-5);
    }

    #[test]
    fn small_steps_get_a_ramp_only_when_asked_and_nothing_is_taken_away() {
        // Two floors 2 units out of line, as two brushes that meet.
        let map = collect(
            &[],
            &[
                box_brush(Vec3::new(-512., -512., -16.), Vec3::new(0., 512., 0.)),
                box_brush(Vec3::new(0., -512., -16.), Vec3::new(512., 512., 2.)),
            ],
        );
        let plain = finish(&map, &Fitted::default());
        let fixes = Surfaces {
            lip: 3.,
            ..Default::default()
        }
        .fit(&map);
        let ramped = finish(&map, &fixes);
        assert!(ramped.triangles.len() > plain.triangles.len());
        assert_eq!(&ramped.triangles[..plain.triangles.len()], &plain.triangles[..]);
        let sorted = |w: &World| {
            let mut rails: Vec<String> = w.rails.iter().map(|r| format!("{r:?}")).collect();
            rails.sort();
            rails
        };
        assert_eq!(sorted(&ramped), sorted(&plain));
        for t in &ramped.triangles[plain.triangles.len()..] {
            let n = (glam::Vec3::from_array(t[1]) - glam::Vec3::from_array(t[0]))
                .cross(glam::Vec3::from_array(t[2]) - glam::Vec3::from_array(t[0]))
                .normalize();
            // Faces the way the step does and leans back: up, not under.
            assert!(n.y > 0.3 && n.y < 0.95, "{n:?}");
            // Never below the lower floor.
            assert!(t.iter().all(|p| p[1] >= -0.001));
        }
        // A step taller than asked for gets none.
        let tall = Surfaces {
            lip: 1.,
            ..Default::default()
        }
        .fit(&map);
        assert_eq!(finish(&map, &tall).triangles.len(), plain.triangles.len());
    }

    #[test]
    fn drops_needle_thin_and_tiny_triangles() {
        let keep = [Vec3::ZERO, Vec3::new(64., 0., 0.), Vec3::new(0., 64., 0.)];
        let needle = [
            Vec3::ZERO,
            Vec3::new(512., 0., 0.),
            Vec3::new(256., 0.01, 0.),
        ];
        let tiny = [Vec3::ZERO, Vec3::new(0.1, 0., 0.), Vec3::new(0., 0.1, 0.)];
        let world = build(&[keep, needle, tiny], &[]);
        assert_eq!(world.triangles.len(), 1);
    }

    /// A box's triangles, counterclockwise from outside.
    fn box_tris(min: Vec3, max: Vec3) -> Vec<[Vec3; 3]> {
        let mut out = Vec::new();
        for face in collision::brush_faces(&box_brush(min, max)) {
            for i in 1..face.len() - 1 {
                out.push([face[0], face[i], face[i + 1]]);
            }
        }
        out
    }

    #[test]
    fn a_crate_on_the_floor_is_solid_and_grows_rails_only_on_top() {
        let map = build(
            &[],
            &[box_brush(
                Vec3::new(-1024., -1024., -16.),
                Vec3::new(1024., 1024., 0.),
            )],
        );
        let crate_ = box_tris(Vec3::new(-64., -16., 0.), Vec3::new(64., 16., 32.));
        let extra = extra(&map.triangles, &crate_, &Fitted::default());
        assert_eq!(extra.triangles.len(), crate_.len());
        assert!(extra.rails.len() >= 2, "found {} rails", extra.rails.len());
        for rail in &extra.rails {
            for p in rail {
                assert!((p[1] - 32. * 0.0254).abs() < 1e-3, "rail point {:?} isn't on the top", p);
            }
        }
    }

    #[test]
    fn nothing_extra_is_nothing() {
        let extra = extra(&[], &[], &Fitted::default());
        assert!(extra.triangles.is_empty() && extra.rails.is_empty());
    }

    #[test]
    fn flat_floor_alone_has_no_rails_inside() {
        let world = build(
            &[],
            &[box_brush(
                Vec3::new(-512., -512., -16.),
                Vec3::new(512., 512., 0.),
            )],
        );
        // Only the floor's own perimeter may count as lips.
        for rail in &world.rails {
            for p in rail {
                let on_edge = (p[0].abs() - 512. * 0.0254).abs() < 1e-3
                    || (p[2].abs() - 512. * 0.0254).abs() < 1e-3;
                assert!(on_edge, "rail point {:?} is inside the floor", p);
            }
        }
    }
}
