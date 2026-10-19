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

/// Where a map's pieces nearly meet but don't: vertices within a unit of each
/// other that the engine's 1 mm welding keeps apart, and floor edges with no
/// partner.
#[test]
#[ignore]
fn scan_seams() {
    let Ok(path) = std::env::var("S3GM_SCAN_BSP") else {
        return;
    };
    let data = std::fs::read(path).unwrap();
    let solids = crate::bsp::parse(&data).unwrap();
    let disp = solids.triangles.len();
    let tris = world::collect(&solids.triangles, &solids.brushes);
    let key = |v: Vec3| v.to_array().map(|x| (x * 25.4).round() as i64);
    let mut unique = HashMap::<[i64; 3], Vec3>::new();
    for t in &tris {
        for v in t {
            unique.entry(key(*v)).or_insert(*v);
        }
    }
    let pts: Vec<Vec3> = unique.values().copied().collect();
    eprintln!("{} vertices after 1 mm welding ({} displacement triangles of {})", pts.len(), disp, tris.len());
    let mut grid = HashMap::<[i32; 3], Vec<usize>>::new();
    for (i, p) in pts.iter().enumerate() {
        grid.entry((*p / 2.).floor().to_array().map(|x| x as i32)).or_default().push(i);
    }
    let mut buckets = [0usize; 5]; // <0.1, <0.25, <0.5, <1, <2
    let mut worst = Vec::new();
    for (i, p) in pts.iter().enumerate() {
        let c = (*p / 2.).floor().to_array().map(|x| x as i32);
        for dx in -1..=1 {
            for dy in -1..=1 {
                for dz in -1..=1 {
                    let Some(list) = grid.get(&[c[0] + dx, c[1] + dy, c[2] + dz]) else {
                        continue;
                    };
                    for &j in list {
                        if j <= i {
                            continue;
                        }
                        let d = p.distance(pts[j]);
                        if d < 2. {
                            let b = [0.1, 0.25, 0.5, 1., 2.].iter().position(|m| d < *m).unwrap();
                            buckets[b] += 1;
                            if d < 1. {
                                worst.push((d, *p, pts[j]));
                            }
                        }
                    }
                }
            }
        }
    }
    eprintln!("vertex pairs not welded, by distance <0.1 / <0.25 / <0.5 / <1 / <2 units: {buckets:?}");
    worst.sort_by(|a, b| a.0.total_cmp(&b.0));
    for (d, a, b) in worst.iter().take(12) {
        eprintln!("  {d:.3} apart: ({:.2} {:.2} {:.2}) and ({:.2} {:.2} {:.2})", a.x, a.y, a.z, b.x, b.y, b.z);
    }
    // Vertices not on a whole unit: the grid they were meant to sit on.
    let off = pts.iter().filter(|p| p.to_array().iter().any(|x| (x - x.round()).abs() > 0.02)).count();
    eprintln!("vertices off a whole-unit grid: {off} of {}", pts.len());
}

/// What the floor edges with no partner are: T-junctions (another piece's
/// corner sits on the edge), near misses (a corner a fraction of a unit
/// away) or true borders. Also where they are, by 256-unit cell.
#[test]
#[ignore]
fn scan_edges() {
    let Ok(path) = std::env::var("S3GM_SCAN_BSP") else {
        return;
    };
    let data = std::fs::read(path).unwrap();
    let solids = crate::bsp::parse(&data).unwrap();
    let tris = world::collect(&solids.triangles, &solids.brushes);
    let normal = |t: &[Vec3; 3]| (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero();
    let key = |v: Vec3| v.to_array().map(|x| (x * 25.4).round() as i64);
    let mut edges = HashMap::<([i64; 3], [i64; 3]), u32>::new();
    let mut grid = HashMap::<[i32; 3], Vec<Vec3>>::new();
    for t in &tris {
        for i in 0..3 {
            *edges.entry((key(t[i]), key(t[(i + 1) % 3]))).or_default() += 1;
            grid.entry((t[i] / 4.).floor().to_array().map(|x| x as i32)).or_default().push(t[i]);
        }
    }
    let near = |p: Vec3, r: f32, f: &mut dyn FnMut(Vec3)| {
        let c = (p / 4.).floor().to_array().map(|x| x as i32);
        let k = (r / 4.).ceil() as i32;
        for dx in -k..=k {
            for dy in -k..=k {
                for dz in -k..=k {
                    if let Some(l) = grid.get(&[c[0] + dx, c[1] + dy, c[2] + dz]) {
                        l.iter().for_each(|v| f(*v));
                    }
                }
            }
        }
    };
    let mut counts = [0usize; 4];
    let mut cells: [HashMap<(i32, i32), usize>; 4] = Default::default();
    let mut shown = [0usize; 4];
    let names = ["T-junction", "near miss", "free border", "total up-facing"];
    for t in tris.iter().filter(|t| normal(t).z > 0.7) {
        for i in 0..3 {
            let (a, b) = (t[i], t[(i + 1) % 3]);
            counts[3] += 1;
            if edges.contains_key(&(key(b), key(a))) {
                continue;
            }
            let ab = b - a;
            let len = ab.length();
            let mut tj = false;
            let mut nm = f32::MAX;
            near((a + b) / 2., len / 2. + 1.1, &mut |v| {
                let s = (v - a).dot(ab) / (len * len);
                let d = (a + ab * s - v).length();
                if s > 0.01 && s < 0.99 && d < 0.1 {
                    tj = true;
                }
                for e in [a, b] {
                    let d = v.distance(e);
                    if d > 0.04 && d < nm {
                        nm = d;
                    }
                }
            });
            let class = if tj { 0 } else if nm < 1. { 1 } else { 2 };
            counts[class] += 1;
            let c = ((a.x / 256.).floor() as i32, (a.y / 256.).floor() as i32);
            *cells[class].entry(c).or_default() += 1;
            if shown[class] < 6 {
                shown[class] += 1;
                eprintln!("  {}: ({:.2} {:.2} {:.2}) -> ({:.2} {:.2} {:.2}) len {len:.1}", names[class], a.x, a.y, a.z, b.x, b.y, b.z);
            }
        }
    }
    for c in 0..3 {
        let mut top: Vec<_> = cells[c].iter().collect();
        top.sort_by_key(|(_, n)| std::cmp::Reverse(**n));
        eprintln!("{}: {} edges; busiest 256-cells (x,y)->n: {:?}", names[c], counts[c], &top[..top.len().min(10)]);
    }
    eprintln!("up-facing triangle edges in all: {}", counts[3]);
}

/// The collision and rails inside a box: `S3GM_SCAN_BOX=x0,y0,z0,x1,y1,z1`.
#[test]
#[ignore]
fn scan_region() {
    let (Ok(path), Ok(boxed)) = (std::env::var("S3GM_SCAN_BSP"), std::env::var("S3GM_SCAN_BOX")) else {
        return;
    };
    let b: Vec<f32> = boxed.split(',').map(|x| x.trim().parse().unwrap()).collect();
    let (lo, hi) = (Vec3::new(b[0], b[1], b[2]), Vec3::new(b[3], b[4], b[5]));
    let data = std::fs::read(path).unwrap();
    let solids = crate::bsp::parse(&data).unwrap();
    let tris = world::collect(&solids.triangles, &solids.brushes);
    let inside = |t: &[Vec3; 3]| {
        let (a, c) = (t[0].min(t[1]).min(t[2]), t[0].max(t[1]).max(t[2]));
        a.cmplt(hi).all() && c.cmpgt(lo).all()
    };
    let here: Vec<_> = tris.iter().filter(|t| inside(t)).collect();
    eprintln!("{} triangles in the box (of {})", here.len(), tris.len());
    for t in here.iter().take(60) {
        let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero();
        eprintln!(
            "  n({:.2} {:.2} {:.2}) ({:.2} {:.2} {:.2}) ({:.2} {:.2} {:.2}) ({:.2} {:.2} {:.2})",
            n.x, n.y, n.z, t[0].x, t[0].y, t[0].z, t[1].x, t[1].y, t[1].z, t[2].x, t[2].y, t[2].z
        );
    }
    for n in [2., 3., 3.5] {
        let ramps = skate_bridge::surfaces::lips(&tris, n);
        let near = ramps.iter().filter(|t| inside(t)).count();
        eprintln!("lip forgiveness up to {n}: {near} ramp triangles in the box ({} on the map)", ramps.len());
    }
    let (rails, census) = skate_bridge::rails::find(&tris);
    eprintln!("whole map: {} candidates, {} lips, {} runs, {} rails", census.candidates, census.lips, census.runs, census.rails);
    if let Ok(dump) = std::env::var("S3GM_SCAN_DUMP") {
        let lines: Vec<String> = rails
            .iter()
            .map(|r| r.iter().map(|p| format!("{:.2},{:.2},{:.2}", p.x, p.y, p.z)).collect::<Vec<_>>().join(" "))
            .collect();
        std::fs::write(dump, lines.join("\n")).unwrap();
    }
    for r in rails.iter().filter(|r| r.iter().any(|p| p.cmpgt(lo).all() && p.cmplt(hi).all())) {
        let pts: Vec<String> = r.iter().map(|p| format!("({:.1} {:.1} {:.1})", p.x, p.y, p.z)).collect();
        eprintln!("  rail {}", pts.join(" "));
    }
}
