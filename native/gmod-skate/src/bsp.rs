//! The solid parts of a Source `.bsp`: brushes as plane sets and displacement
//! surfaces as triangles, in map units (Z up, inches).
//!
//! Brushes come from the world's brush list, so brush entities (doors,
//! func_brush) are treated as static where the map compiled them. Static and
//! physics props are not in this data; Lua hands those over separately.

use glam::Vec3;

const HEADER_LUMPS: usize = 64;
const LUMP_PLANES: usize = 1;
const LUMP_VERTEXES: usize = 3;
const LUMP_FACES: usize = 7;
const LUMP_EDGES: usize = 12;
const LUMP_SURFEDGES: usize = 13;
const LUMP_BRUSHES: usize = 18;
const LUMP_BRUSHSIDES: usize = 19;
const LUMP_DISPINFO: usize = 26;
const LUMP_DISP_VERTS: usize = 33;

/// Contents a skater collides with: solid, window, grate and player clip.
pub const SOLID_CONTENTS: i32 = 0x1 | 0x2 | 0x8 | 0x10000;

pub struct Solids {
    /// Each brush as `[nx, ny, nz, dist]` planes, inside where `n . p <= dist`.
    pub brushes: Vec<Vec<[f32; 4]>>,
    /// Displacement triangles, wound counterclockwise seen from their top.
    pub triangles: Vec<[Vec3; 3]>,
}

pub fn parse(data: &[u8]) -> Result<Solids, String> {
    let bsp = Bsp::new(data)?;
    let planes = bsp.planes()?;
    Ok(Solids {
        brushes: bsp.brushes(&planes)?,
        triangles: bsp.displacements(&planes)?,
    })
}

struct Bsp<'a> {
    data: &'a [u8],
}

#[derive(Clone, Copy)]
struct Plane {
    normal: Vec3,
    dist: f32,
}

impl<'a> Bsp<'a> {
    fn new(data: &'a [u8]) -> Result<Self, String> {
        if data.len() < 8 + HEADER_LUMPS * 16 + 4 || &data[..4] != b"VBSP" {
            return Err("not a Source BSP (missing VBSP header)".into());
        }
        let version = i32_at(data, 4);
        if !(19..=21).contains(&version) {
            return Err(format!("unsupported BSP version {version}"));
        }
        Ok(Self { data })
    }

    /// One lump's bytes, checked for bounds and compression.
    fn lump(&self, index: usize, stride: usize) -> Result<&'a [u8], String> {
        let at = 8 + index * 16;
        let offset = i32_at(self.data, at).max(0) as usize;
        let len = i32_at(self.data, at + 4).max(0) as usize;
        let lump = self
            .data
            .get(offset..offset + len)
            .ok_or_else(|| format!("lump {index} runs past the end of the file"))?;
        if lump.starts_with(b"LZMA") {
            return Err(format!(
                "lump {index} is LZMA-compressed, which isn't supported yet"
            ));
        }
        Ok(&lump[..len - len % stride])
    }

    fn planes(&self) -> Result<Vec<Plane>, String> {
        Ok(self
            .lump(LUMP_PLANES, 20)?
            .chunks_exact(20)
            .map(|p| Plane {
                normal: vec_at(p, 0),
                dist: f32_at(p, 12),
            })
            .collect())
    }

    fn brushes(&self, planes: &[Plane]) -> Result<Vec<Vec<[f32; 4]>>, String> {
        let sides = self.lump(LUMP_BRUSHSIDES, 8)?;
        let mut out = Vec::new();
        for brush in self.lump(LUMP_BRUSHES, 12)?.chunks_exact(12) {
            let first = i32_at(brush, 0).max(0) as usize;
            let count = i32_at(brush, 4).max(0) as usize;
            if i32_at(brush, 8) & SOLID_CONTENTS == 0 {
                continue;
            }
            let mut brush_planes = Vec::with_capacity(count);
            for side in first..first + count {
                let Some(side) = sides.get(side * 8..side * 8 + 8) else {
                    continue;
                };
                if let Some(p) = planes.get(u16_at(side, 0) as usize) {
                    brush_planes.push([p.normal.x, p.normal.y, p.normal.z, p.dist]);
                }
            }
            if brush_planes.len() >= 4 {
                out.push(brush_planes);
            }
        }
        Ok(out)
    }

    fn displacements(&self, planes: &[Plane]) -> Result<Vec<[Vec3; 3]>, String> {
        let infos = self.lump(LUMP_DISPINFO, 176)?;
        if infos.is_empty() {
            return Ok(Vec::new());
        }
        let faces = self.lump(LUMP_FACES, 56)?;
        let surfedges = self.lump(LUMP_SURFEDGES, 4)?;
        let edges = self.lump(LUMP_EDGES, 4)?;
        let vertexes = self.lump(LUMP_VERTEXES, 12)?;
        let verts = self.lump(LUMP_DISP_VERTS, 20)?;
        let vertex = |i: usize| vertexes.get(i * 12..i * 12 + 12).map(|v| vec_at(v, 0));

        let mut out = Vec::new();
        for info in infos.chunks_exact(176) {
            let start = vec_at(info, 0);
            let first_vert = i32_at(info, 12).max(0) as usize;
            let power = i32_at(info, 20);
            let face_index = u16_at(info, 36) as usize;
            if !(2..=4).contains(&power) {
                continue;
            }
            let Some(face) = faces.get(face_index * 56..face_index * 56 + 56) else {
                continue;
            };
            let first_edge = i32_at(face, 4).max(0) as usize;
            if i16_at(face, 8) != 4 {
                continue;
            }
            // The face's four corners, in surfedge order.
            let mut corners = [Vec3::ZERO; 4];
            let mut ok = true;
            for (k, corner) in corners.iter_mut().enumerate() {
                let Some(se) = surfedges.get((first_edge + k) * 4..(first_edge + k) * 4 + 4) else {
                    ok = false;
                    break;
                };
                let se = i32_at(se, 0);
                let edge = se.unsigned_abs() as usize;
                let Some(e) = edges.get(edge * 4..edge * 4 + 4) else {
                    ok = false;
                    break;
                };
                let v = if se >= 0 { u16_at(e, 0) } else { u16_at(e, 2) };
                match vertex(v as usize) {
                    Some(p) => *corner = p,
                    None => ok = false,
                }
            }
            if !ok {
                continue;
            }
            // The grid starts at the corner nearest the stored start position.
            let first = (0..4)
                .min_by(|&a, &b| {
                    corners[a]
                        .distance_squared(start)
                        .total_cmp(&corners[b].distance_squared(start))
                })
                .unwrap_or(0);
            corners.rotate_left(first);

            let size = (1usize << power) + 1;
            let Some(grid_verts) = verts.get(first_vert * 20..(first_vert + size * size) * 20)
            else {
                continue;
            };
            let mut grid = Vec::with_capacity(size * size);
            let step = 1. / (size - 1) as f32;
            for i in 0..size {
                let left = corners[0].lerp(corners[1], i as f32 * step);
                let right = corners[3].lerp(corners[2], i as f32 * step);
                for j in 0..size {
                    let v = &grid_verts[(i * size + j) * 20..(i * size + j) * 20 + 20];
                    grid.push(left.lerp(right, j as f32 * step) + vec_at(v, 0) * f32_at(v, 12));
                }
            }

            // Wind every triangle to face the same side as the face's plane.
            let up = planes
                .get(u16_at(face, 0) as usize)
                .map(|p| if face[2] != 0 { -p.normal } else { p.normal })
                .unwrap_or(Vec3::Z);
            let mut push = |mut t: [Vec3; 3]| {
                if (t[1] - t[0]).cross(t[2] - t[0]).dot(up) < 0. {
                    t.swap(1, 2);
                }
                out.push(t);
            };
            for i in 0..size - 1 {
                for j in 0..size - 1 {
                    let a = grid[i * size + j];
                    let b = grid[i * size + j + 1];
                    let c = grid[(i + 1) * size + j];
                    let d = grid[(i + 1) * size + j + 1];
                    // Source alternates the diagonal per cell.
                    if (i + j) % 2 == 0 {
                        push([a, c, d]);
                        push([a, d, b]);
                    } else {
                        push([a, c, b]);
                        push([b, c, d]);
                    }
                }
            }
        }
        Ok(out)
    }
}

fn i32_at(b: &[u8], at: usize) -> i32 {
    i32::from_le_bytes(b[at..at + 4].try_into().unwrap())
}
fn i16_at(b: &[u8], at: usize) -> i16 {
    i16::from_le_bytes(b[at..at + 2].try_into().unwrap())
}
fn u16_at(b: &[u8], at: usize) -> u16 {
    u16::from_le_bytes(b[at..at + 2].try_into().unwrap())
}
fn f32_at(b: &[u8], at: usize) -> f32 {
    f32::from_le_bytes(b[at..at + 4].try_into().unwrap())
}
fn vec_at(b: &[u8], at: usize) -> Vec3 {
    Vec3::new(f32_at(b, at), f32_at(b, at + 4), f32_at(b, at + 8))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// Writes a minimal v20 BSP holding the given lumps.
    pub fn build(lumps: &[(usize, Vec<u8>)]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(b"VBSP");
        out.extend_from_slice(&20i32.to_le_bytes());
        out.resize(8 + HEADER_LUMPS * 16 + 4, 0);
        for (index, data) in lumps {
            let offset = out.len() as i32;
            out[8 + index * 16..12 + index * 16].copy_from_slice(&offset.to_le_bytes());
            out[12 + index * 16..16 + index * 16]
                .copy_from_slice(&(data.len() as i32).to_le_bytes());
            out.extend_from_slice(data);
        }
        out
    }

    fn plane(n: [f32; 3], d: f32) -> Vec<u8> {
        let mut b = Vec::new();
        for c in n {
            b.extend_from_slice(&c.to_le_bytes());
        }
        b.extend_from_slice(&d.to_le_bytes());
        b.extend_from_slice(&0i32.to_le_bytes());
        b
    }

    #[test]
    fn rejects_files_that_are_not_bsps() {
        assert!(parse(b"nope").is_err());
        let mut wrong = build(&[]);
        wrong[4] = 99;
        assert!(parse(&wrong).is_err());
    }

    #[test]
    fn reads_a_solid_box_brush_and_skips_water() {
        let mut planes = Vec::new();
        for (n, d) in [
            ([1., 0., 0.], 64.),
            ([-1., 0., 0.], 64.),
            ([0., 1., 0.], 64.),
            ([0., -1., 0.], 64.),
            ([0., 0., 1.], 16.),
            ([0., 0., -1.], 0.),
        ] {
            planes.extend(plane(n, d));
        }
        let mut sides = Vec::new();
        for i in 0..6u16 {
            sides.extend_from_slice(&i.to_le_bytes());
            sides.extend_from_slice(&[0; 6]);
        }
        let mut brushes = Vec::new();
        for contents in [0x1i32, 0x20] {
            brushes.extend_from_slice(&0i32.to_le_bytes());
            brushes.extend_from_slice(&6i32.to_le_bytes());
            brushes.extend_from_slice(&contents.to_le_bytes());
        }
        let data = build(&[
            (LUMP_PLANES, planes),
            (LUMP_BRUSHSIDES, sides),
            (LUMP_BRUSHES, brushes),
        ]);
        let solids = parse(&data).unwrap();
        assert_eq!(solids.brushes.len(), 1, "the water brush is skipped");
        let faces = skate_bridge::collision::brush_faces(&solids.brushes[0]);
        assert_eq!(faces.len(), 6);
        assert!(solids.triangles.is_empty());
    }

    #[test]
    fn builds_an_upward_displacement_grid() {
        // One 128x128 quad face at z=0, displaced up by 8 everywhere.
        let corners = [
            [0., 0., 0.],
            [0., 128., 0.],
            [128., 128., 0.],
            [128., 0., 0.],
        ];
        let mut vertexes = Vec::new();
        for c in corners {
            for x in c {
                vertexes.extend_from_slice(&(x as f32).to_le_bytes());
            }
        }
        let mut edges = Vec::new();
        for (a, b) in [(0u16, 1u16), (1, 2), (2, 3), (3, 0)] {
            edges.extend_from_slice(&a.to_le_bytes());
            edges.extend_from_slice(&b.to_le_bytes());
        }
        let mut surfedges = Vec::new();
        for i in 0..4i32 {
            surfedges.extend_from_slice(&i.to_le_bytes());
        }
        let mut face = vec![0u8; 56];
        face[0..2].copy_from_slice(&0u16.to_le_bytes());
        face[4..8].copy_from_slice(&0i32.to_le_bytes());
        face[8..10].copy_from_slice(&4i16.to_le_bytes());
        let mut info = vec![0u8; 176];
        info[20..24].copy_from_slice(&2i32.to_le_bytes());
        let size = 5;
        let mut verts = Vec::new();
        for _ in 0..size * size {
            for x in [0f32, 0., 1., 8., 0.] {
                verts.extend_from_slice(&x.to_le_bytes());
            }
        }
        let data = build(&[
            (LUMP_PLANES, plane([0., 0., 1.], 0.)),
            (LUMP_VERTEXES, vertexes),
            (LUMP_EDGES, edges),
            (LUMP_SURFEDGES, surfedges),
            (LUMP_FACES, face),
            (LUMP_DISPINFO, info),
            (LUMP_DISP_VERTS, verts),
        ]);
        let solids = parse(&data).unwrap();
        assert_eq!(solids.triangles.len(), 2 * 4 * 4);
        for t in &solids.triangles {
            assert!(t.iter().all(|v| (v.z - 8.).abs() < 1e-4));
            let n = (t[1] - t[0]).cross(t[2] - t[0]);
            assert!(n.z > 0., "triangle faces down: {t:?}");
        }
    }
}
