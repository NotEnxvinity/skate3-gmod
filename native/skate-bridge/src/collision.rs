// Unit conversion and brush faces ported from chasmlol/2010-rust-rewrite-mashup
// (Apache-2.0) at f608f85, crates/render_anim/src/skate/collision.rs. MW2 and
// Source are both Z-up with 1 unit = 1 inch, so the conversion carries over.

use glam::{Mat3, Mat4, Vec3, Vec4};

/// Source units (Z up, inches) to Skate space (Y up, metres).
pub fn to_skate(p: Vec3) -> Vec3 {
    Vec3::new(p.x, p.z, -p.y) * 0.0254
}
/// Skate space back to Source units.
pub fn from_skate(p: Vec3) -> Vec3 {
    Vec3::new(p.x, -p.z, p.y) / 0.0254
}
/// Skate axes expressed in Source axes.
pub fn basis() -> Mat4 {
    Mat4::from_cols(Vec4::X, Vec4::Z, -Vec4::Y, Vec4::W)
}

/// Convex polygons of a brush given as `[nx, ny, nz, dist]` planes (outward
/// normals, `n . p <= dist` inside), wound for outward faces.
pub fn brush_faces(planes: &[[f32; 4]]) -> Vec<Vec<Vec3>> {
    let mut points = Vec::<Vec3>::new();
    for a in 0..planes.len() {
        for b in a + 1..planes.len() {
            for c in b + 1..planes.len() {
                let m = Mat3::from_cols(
                    Vec3::from_slice(&planes[a][..3]),
                    Vec3::from_slice(&planes[b][..3]),
                    Vec3::from_slice(&planes[c][..3]),
                )
                .transpose();
                if m.determinant().abs() < 1e-6 {
                    continue;
                }
                let p = m.inverse() * Vec3::new(planes[a][3], planes[b][3], planes[c][3]);
                if p.is_finite()
                    && planes
                        .iter()
                        .all(|v| Vec3::from_slice(&v[..3]).dot(p) <= v[3] + 0.05)
                    && points.iter().all(|v| v.distance_squared(p) > 0.01)
                {
                    points.push(p);
                }
            }
        }
    }
    planes
        .iter()
        .filter_map(|plane| {
            let n = Vec3::from_slice(&plane[..3]);
            let mut face: Vec<_> = points
                .iter()
                .copied()
                .filter(|p| (n.dot(*p) - plane[3]).abs() < 0.1)
                .collect();
            if face.len() < 3 {
                return None;
            }
            let center = face.iter().copied().sum::<Vec3>() / face.len() as f32;
            let x = n.normalize().any_orthonormal_vector();
            let y = n.cross(x).normalize();
            face.sort_by(|a, b| {
                let a = *a - center;
                let b = *b - center;
                a.dot(y)
                    .atan2(a.dot(x))
                    .total_cmp(&b.dot(y).atan2(b.dot(x)))
            });
            Some(face)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cube_collision_has_outward_faces_and_roundtrips_units() {
        let faces = brush_faces(&[
            [1., 0., 0., 16.],
            [-1., 0., 0., 16.],
            [0., 1., 0., 16.],
            [0., -1., 0., 16.],
            [0., 0., 1., 16.],
            [0., 0., -1., 16.],
        ]);
        assert_eq!(faces.len(), 6);
        for f in faces {
            assert_eq!(f.len(), 4);
            assert!((f[1] - f[0]).cross(f[2] - f[0]).dot(f[0]) > 0.);
        }
        let p = Vec3::new(1234., -456., 72.);
        assert!(from_skate(to_skate(p)).distance(p) < 0.001);
    }
}
