//! Turns Source collision (Z up, inches) into what a Skate session rides:
//! triangles and grind rails in Skate space.

use std::collections::HashSet;

use glam::Vec3;

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
    let mut seen = HashSet::new();
    out.retain(|p| {
        let mut k = p.map(|v| v.to_array().map(|x| (x * 8.).round() as i32));
        k.sort();
        seen.insert(k)
    });
    let (found, census) = rails::find(&out);
    World {
        triangles: out
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
pub fn extra(map: &[[[f32; 3]; 3]], extra: &[[Vec3; 3]]) -> Extra {
    let mut tris: Vec<[Vec3; 3]> = extra.iter().copied().filter(usable).collect();
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
        let extra = extra(&map.triangles, &crate_);
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
        let extra = extra(&[], &[]);
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
