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
        if p.iter().all(|v| v.is_finite())
            && (p[1] - p[0]).cross(p[2] - p[0]).length_squared() > 0.001
        {
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
