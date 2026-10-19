//! A look at a real map's collision, for working out what stops a board:
//! `S3GM_SCAN_BSP=map.bsp cargo test -p gmod-skate scan -- --ignored --nocapture`.

use std::collections::HashMap;

use glam::Vec3;
use skate_bridge::world;

#[test]
#[ignore]
fn scan_a_map() {
    let Ok(path) = std::env::var("S3GM_SCAN_BSP") else {
        return;
    };
    let data = std::fs::read(path).unwrap();
    let solids = crate::bsp::parse(&data).unwrap();
    let disp = solids.triangles.len();
    let tris = world::collect(&solids.triangles, &solids.brushes);
    eprintln!("displacement triangles {disp}, collision triangles {}", tris.len());
    let normal = |t: &[Vec3; 3]| (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero();
    let up = tris.iter().filter(|t| normal(t).z > 0.7).count();
    let down = tris.iter().filter(|t| normal(t).z < -0.7).count();
    let wall: Vec<&[Vec3; 3]> = tris.iter().filter(|t| normal(t).z.abs() < 0.2).collect();
    eprintln!("up-facing {up}, down-facing {down}, wall {}", wall.len());
    // Wall triangles by how tall they are.
    let bins = [(0., 1.), (1., 2.), (2., 3.), (3., 4.), (4., 6.), (6., 12.), (12., 1e9)];
    for (lo, hi) in bins {
        let n = wall
            .iter()
            .filter(|t| {
                let h = t.iter().map(|v| v.z).fold(f32::MIN, f32::max)
                    - t.iter().map(|v| v.z).fold(f32::MAX, f32::min);
                h >= lo && h < hi
            })
            .count();
        eprintln!("  wall triangles {lo}..{hi} units tall: {n}");
    }
    // Edges of up-facing triangles with no partner at the engine's welding.
    let key = |v: Vec3| v.to_array().map(|x| (x * 25.4).round() as i64);
    let mut edges = HashMap::<([i64; 3], [i64; 3]), u32>::new();
    for t in &tris {
        for i in 0..3 {
            *edges.entry((key(t[i]), key(t[(i + 1) % 3]))).or_default() += 1;
        }
    }
    let (mut total, mut lone) = (0, 0);
    for t in tris.iter().filter(|t| normal(t).z > 0.7) {
        for i in 0..3 {
            total += 1;
            if !edges.contains_key(&(key(t[(i + 1) % 3]), key(t[i]))) {
                lone += 1;
            }
        }
    }
    eprintln!("up-facing edges {total}, with no partner at 1 mm welding {lone}");
    // Small steps: a short wall with a floor at its top behind it and a
    // floor at its foot in front of it.
    let mut cells = HashMap::<(i32, i32), Vec<usize>>::new();
    let ups: Vec<&[Vec3; 3]> = tris.iter().filter(|t| normal(t).z > 0.7).collect();
    for (i, t) in ups.iter().enumerate() {
        let lo = t[0].min(t[1]).min(t[2]);
        let hi = t[0].max(t[1]).max(t[2]);
        for x in (lo.x / 64.).floor() as i32..=(hi.x / 64.).floor() as i32 {
            for y in (lo.y / 64.).floor() as i32..=(hi.y / 64.).floor() as i32 {
                cells.entry((x, y)).or_default().push(i);
            }
        }
    }
    let heights = |p: Vec3, near: f32| -> bool {
        let Some(list) = cells.get(&((p.x / 64.).floor() as i32, (p.y / 64.).floor() as i32)) else {
            return false;
        };
        list.iter().any(|&i| {
            let t = ups[i];
            let n = normal(t);
            let z = t[0].z - (n.x * (p.x - t[0].x) + n.y * (p.y - t[0].y)) / n.z;
            let inside = (0..3).all(|k| {
                let (a, b) = (t[k], t[(k + 1) % 3]);
                ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) * n.z.signum() >= -0.01
            });
            inside && (z - near).abs() < 0.6
        })
    };
    let mut by_height = [0usize; 5];
    for t in &wall {
        let (zmin, zmax) = (
            t.iter().map(|v| v.z).fold(f32::MAX, f32::min),
            t.iter().map(|v| v.z).fold(f32::MIN, f32::max),
        );
        let h = zmax - zmin;
        if !(0.3..4.).contains(&h) {
            continue;
        }
        let n = normal(t);
        let c = (t[0] + t[1] + t[2]) / 3.;
        let (behind, front) = (c - n * 1.5, c + n * 1.5);
        if heights(behind, zmax) && heights(front, zmin) {
            by_height[(h as usize).min(3)] += 1;
        }
    }
    eprintln!("real steps (floor on top behind, floor at the foot in front), triangles by height 0-1 / 1-2 / 2-3 / 3-4: {:?}", &by_height[..4]);
    for max in [2., 3., 4.] {
        let started = std::time::Instant::now();
        let ramps = skate_bridge::surfaces::lips(&tris, max);
        eprintln!("ramps for steps up to {max} units: {} triangles ({:?})", ramps.len(), started.elapsed());
    }
}
