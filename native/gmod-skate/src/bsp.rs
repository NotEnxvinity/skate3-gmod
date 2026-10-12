//! The solid parts of a Source `.bsp`: brushes as plane sets and displacement
//! surfaces as triangles, in map units (Z up, inches).
//!
//! Brushes are the world's plus those of solid brush entities (doors,
//! func_brush, func_wall), which are treated as static where the map compiled
//! them. Triggers and other non-solid brush entities (spawn zones, buy zones,
//! func_illusionary) share the brush list with contents that read as solid, so
//! they're told apart by walking each model's BSP tree and reading the entity
//! that owns it. Static and physics props are not in this data; Lua hands
//! those over separately.

use glam::{Mat3, Vec3};

const HEADER_LUMPS: usize = 64;
const LUMP_ENTITIES: usize = 0;
const LUMP_PLANES: usize = 1;
const LUMP_NODES: usize = 5;
const LUMP_LEAFS: usize = 10;
const LUMP_MODELS: usize = 14;
const LUMP_LEAFBRUSHES: usize = 17;
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
    let owners = bsp.solid_brushes();
    Ok(Solids {
        brushes: bsp.brushes(&planes, owners.as_ref())?,
        triangles: bsp.displacements(&planes)?,
    })
}

struct Bsp<'a> {
    data: &'a [u8],
    /// Where a lump's offset and length sit in its 16-byte header entry.
    /// Left 4 Dead 2's version 21 maps put the lump version first.
    fields: (usize, usize),
}

const STANDARD: (usize, usize) = (0, 4);
const LEFT4DEAD2: (usize, usize) = (4, 8);

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
        // Version 21 is both Portal 2 / CS:GO and Left 4 Dead 2, which differ
        // only in the header's field order: take L4D2's when only it reads
        // sensibly.
        let standard = Self {
            data,
            fields: STANDARD,
        };
        let left4dead2 = Self {
            data,
            fields: LEFT4DEAD2,
        };
        if version == 21 && !standard.header_fits() && left4dead2.header_fits() {
            return Ok(left4dead2);
        }
        Ok(standard)
    }

    /// Every lump's offset and length, unchecked.
    fn span(&self, index: usize) -> (usize, usize) {
        let at = 8 + index * 16;
        let offset = i32_at(self.data, at + self.fields.0).max(0) as usize;
        let len = i32_at(self.data, at + self.fields.1).max(0) as usize;
        (offset, len)
    }

    /// Whether every lump with data lies after the header and inside the file.
    fn header_fits(&self) -> bool {
        let header = 8 + HEADER_LUMPS * 16 + 4;
        (0..HEADER_LUMPS).all(|index| {
            let (offset, len) = self.span(index);
            len == 0 || (offset >= header && offset + len <= self.data.len())
        })
    }

    /// One lump's bytes, checked for bounds and compression.
    fn lump(&self, index: usize, stride: usize) -> Result<&'a [u8], String> {
        let (offset, len) = self.span(index);
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

    /// Where each brush of the world or a solid brush entity sits (None for
    /// the rest), or None when the map's tree can't be read, in which case
    /// every brush counts where it was compiled.
    fn solid_brushes(&self) -> Option<Vec<Option<Place>>> {
        let count = self.lump(LUMP_BRUSHES, 12).ok()?.len() / 12;
        let models = self.lump(LUMP_MODELS, 48).ok()?;
        let nodes = self.lump(LUMP_NODES, 32).ok()?;
        // Version 19 leaves still carry their ambient light cube.
        let stride = if i32_at(self.data, 4) == 19 { 56 } else { 32 };
        let leaves = self.lump(LUMP_LEAFS, stride).ok()?;
        let leaf_brushes = self.lump(LUMP_LEAFBRUSHES, 2).ok()?;
        let solid_models = self
            .lump(LUMP_ENTITIES, 1)
            .map(solid_brush_models)
            .unwrap_or_default();
        let mut keep = vec![None; count];
        let mut seen = vec![false; nodes.len() / 32];
        for (model, place) in std::iter::once((0, Place::default())).chain(solid_models) {
            let Some(m) = models.get(model * 48..model * 48 + 48) else {
                continue;
            };
            let mut stack = vec![i32_at(m, 36)];
            while let Some(child) = stack.pop() {
                if child >= 0 {
                    let node = child as usize;
                    // A node visited twice would mean a cycle in a bad file.
                    if node >= seen.len() || std::mem::replace(&mut seen[node], true) {
                        continue;
                    }
                    let n = &nodes[node * 32..node * 32 + 32];
                    stack.extend([i32_at(n, 4), i32_at(n, 8)]);
                } else {
                    let leaf = (-1 - child) as usize;
                    let Some(l) = leaves.get(leaf * stride..leaf * stride + stride) else {
                        continue;
                    };
                    let first = u16_at(l, 24) as usize;
                    for i in first..first + u16_at(l, 26) as usize {
                        if let Some(b) = leaf_brushes.get(i * 2..i * 2 + 2)
                            && let Some(k) = keep.get_mut(u16_at(b, 0) as usize)
                        {
                            *k = Some(place);
                        }
                    }
                }
            }
        }
        // A world with no brushes at all means the tree didn't read right.
        keep.iter().any(Option::is_some).then_some(keep)
    }

    fn brushes(
        &self,
        planes: &[Plane],
        keep: Option<&Vec<Option<Place>>>,
    ) -> Result<Vec<Vec<[f32; 4]>>, String> {
        let sides = self.lump(LUMP_BRUSHSIDES, 8)?;
        let mut out = Vec::new();
        for (index, brush) in self.lump(LUMP_BRUSHES, 12)?.chunks_exact(12).enumerate() {
            let place = match keep {
                Some(k) => match k.get(index).copied().flatten() {
                    Some(place) => place,
                    None => continue,
                },
                None => Place::default(),
            };
            let first = i32_at(brush, 0).max(0) as usize;
            // Never trust a count past the sides that exist: a bad one would
            // reserve gigabytes and take the game down with it.
            let count =
                (i32_at(brush, 4).max(0) as usize).min((sides.len() / 8).saturating_sub(first));
            if i32_at(brush, 8) & SOLID_CONTENTS == 0 {
                continue;
            }
            let mut brush_planes = Vec::with_capacity(count);
            for side in first..first + count {
                let Some(side) = sides.get(side * 8..side * 8 + 8) else {
                    continue;
                };
                // Bevel planes only help Source's own traces; as faces they'd
                // be slivers along edges and corners.
                if side[6] != 0 {
                    continue;
                }
                if let Some(p) = planes.get(u16_at(side, 0) as usize) {
                    let (normal, dist) = place.plane(p.normal, p.dist);
                    brush_planes.push([normal.x, normal.y, normal.z, dist]);
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

/// Where a brush entity puts its model. An entity with an "origin" (rotating
/// doors, many func_brushes) has its brushes compiled around that point
/// instead of where they show up in the map; left as they were, they stood
/// as invisible walls around the map's centre (the box by gm_construct's
/// spawn).
#[derive(Clone, Copy, Default)]
struct Place {
    origin: Vec3,
    /// Pitch, yaw and roll in degrees.
    angles: Vec3,
}

impl Place {
    fn turn(&self) -> Mat3 {
        let [sp, sy, sr] =
            [self.angles.x, self.angles.y, self.angles.z].map(|a| a.to_radians().sin());
        let [cp, cy, cr] =
            [self.angles.x, self.angles.y, self.angles.z].map(|a| a.to_radians().cos());
        // Source's AngleMatrix: forward, left and up as the columns.
        Mat3::from_cols(
            Vec3::new(cp * cy, cp * sy, -sp),
            Vec3::new(sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, sr * cp),
            Vec3::new(cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp),
        )
    }

    /// A model-space plane (`n . p <= d` inside) in the map.
    fn plane(&self, normal: Vec3, dist: f32) -> (Vec3, f32) {
        if self.origin == Vec3::ZERO && self.angles == Vec3::ZERO {
            return (normal, dist);
        }
        let n = self.turn() * normal;
        (n, dist + n.dot(self.origin))
    }
}

fn three(value: &str) -> Option<Vec3> {
    let mut parts = value.split_whitespace().map(|v| v.parse::<f32>().ok());
    let v = Vec3::new(parts.next()??, parts.next()??, parts.next()??);
    v.is_finite().then_some(v)
}

/// Brush entities a skater should hit, by model number (`"model" "*3"`),
/// with where they sit: the func_ ones that stay solid. Triggers and the
/// rest are zones.
fn solid_brush_models(entities: &[u8]) -> Vec<(usize, Place)> {
    const NOT_SOLID: &[&str] = &[
        "func_illusionary",
        "func_areaportal",
        "func_areaportalwindow",
        "func_clip_vphysics",
        "func_occluder",
        "func_dustmotes",
        "func_dustcloud",
        "func_smokevolume",
        "func_precipitation",
        "func_buyzone",
        "func_bomb_target",
        "func_hostage_rescue",
        "func_no_defuse",
        "func_nav_blocker",
        "func_nav_avoid",
        "func_nav_prefer",
        "func_ladder",
        "func_ladderendpoint",
        "func_water_analog",
        "func_physbox",
        "func_physbox_multiplayer",
        "func_vehicleclip",
        "func_fish_pool",
        "func_respawnroom",
        "func_respawnroomvisualizer",
        "func_nobuild",
        "func_regenerate",
        "func_capturezone",
        "func_upgradestation",
    ];
    let text = String::from_utf8_lossy(entities);
    let mut out = Vec::new();
    for block in text.split('{').skip(1) {
        let block = block.split('}').next().unwrap_or("");
        let mut fields = block.split('"').skip(1).step_by(2);
        let (mut class, mut model, mut never_solid) = ("", None, false);
        let mut place = Place::default();
        while let (Some(key), Some(value)) = (fields.next(), fields.next()) {
            match key.to_ascii_lowercase().as_str() {
                "classname" => class = value,
                "model" => model = value.strip_prefix('*').and_then(|n| n.parse().ok()),
                // func_brush set to "Never Solid".
                "solidity" => never_solid = value == "1",
                "origin" => place.origin = three(value).unwrap_or_default(),
                "angles" => place.angles = three(value).unwrap_or_default(),
                _ => {}
            }
        }
        let class = class.to_ascii_lowercase();
        // These read "angles" as the way they move, not as a turn.
        if [
            "func_door",
            "func_movelinear",
            "func_button",
            "func_conveyor",
        ]
        .contains(&class.as_str())
        {
            place.angles = Vec3::ZERO;
        }
        if let Some(model) = model
            && class.starts_with("func_")
            && !NOT_SOLID.contains(&class.as_str())
            && !never_solid
        {
            out.push((model, place));
        }
    }
    out
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
        build_as(20, STANDARD, lumps)
    }

    fn build_as(version: i32, fields: (usize, usize), lumps: &[(usize, Vec<u8>)]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(b"VBSP");
        out.extend_from_slice(&version.to_le_bytes());
        out.resize(8 + HEADER_LUMPS * 16 + 4, 0);
        for (index, data) in lumps {
            let offset = out.len() as i32;
            let at = 8 + index * 16;
            out[at + fields.0..at + fields.0 + 4].copy_from_slice(&offset.to_le_bytes());
            out[at + fields.1..at + fields.1 + 4]
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

    fn box_brush(contents: i32, count: i32) -> Vec<(usize, Vec<u8>)> {
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
        brushes.extend_from_slice(&0i32.to_le_bytes());
        brushes.extend_from_slice(&count.to_le_bytes());
        brushes.extend_from_slice(&contents.to_le_bytes());
        vec![
            (LUMP_PLANES, planes),
            (LUMP_BRUSHSIDES, sides),
            (LUMP_BRUSHES, brushes),
        ]
    }

    /// Two box brushes: the world's (model 0) and model 1's, owned by the
    /// entity in `entities`.
    fn world_and_entity(entities: &str) -> Vec<u8> {
        let mut lumps = box_brush(0x1, 6);
        let brushes = lumps[2].1.clone();
        lumps[2].1.extend(brushes);
        let mut models = vec![0u8; 96];
        models[36..40].copy_from_slice(&0i32.to_le_bytes());
        models[48 + 36..48 + 40].copy_from_slice(&(-2i32).to_le_bytes());
        // Node 0, the world's head, has leaf 0 on both sides.
        let mut node = vec![0u8; 32];
        node[4..8].copy_from_slice(&(-1i32).to_le_bytes());
        node[8..12].copy_from_slice(&(-1i32).to_le_bytes());
        let mut leaves = vec![0u8; 64];
        for (leaf, brush) in [(0usize, 0u16), (1, 1)] {
            leaves[leaf * 32 + 24..leaf * 32 + 26].copy_from_slice(&brush.to_le_bytes());
            leaves[leaf * 32 + 26..leaf * 32 + 28].copy_from_slice(&1u16.to_le_bytes());
        }
        let leaf_brushes = [0u16, 1].iter().flat_map(|b| b.to_le_bytes()).collect();
        lumps.extend([
            (LUMP_ENTITIES, entities.as_bytes().to_vec()),
            (LUMP_MODELS, models),
            (LUMP_NODES, node),
            (LUMP_LEAFS, leaves),
            (LUMP_LEAFBRUSHES, leaf_brushes),
        ]);
        build(&lumps)
    }

    #[test]
    fn keeps_solid_brush_entities_and_drops_zones() {
        let world = "{\n\"classname\" \"worldspawn\"\n}\n";
        let with = |entity: &str| {
            let data = world_and_entity(&format!("{world}{{\n{entity}\n}}\n"));
            parse(&data).unwrap().brushes.len()
        };
        assert_eq!(with(r#""classname" "trigger_multiple" "model" "*1""#), 1);
        assert_eq!(with(r#""model" "*1" "classname" "func_respawnroom""#), 1);
        assert_eq!(
            with(r#""classname" "func_brush" "Solidity" "1" "model" "*1""#),
            1
        );
        assert_eq!(with(r#""classname" "func_wall" "model" "*1""#), 2);
        assert_eq!(
            with(r#""classname" "func_brush" "Solidity" "0" "model" "*1""#),
            2
        );
    }

    #[test]
    fn moves_brush_entities_to_their_origin() {
        let world = "{\n\"classname\" \"worldspawn\"\n}\n";
        let data = world_and_entity(&format!(
            "{world}{{\n\"classname\" \"func_brush\" \"origin\" \"1000 -500 32\" \"angles\" \"0 90 0\" \"model\" \"*1\"\n}}\n"
        ));
        let brushes = parse(&data).unwrap().brushes;
        assert_eq!(brushes.len(), 2);
        // The world's box stays round the centre, the entity's moves with it:
        // +x side (64 out) turned to face +y, 64 past the origin's y.
        let inside = |b: &Vec<[f32; 4]>, p: Vec3| {
            b.iter()
                .all(|q| Vec3::new(q[0], q[1], q[2]).dot(p) <= q[3] + 0.01)
        };
        assert!(inside(&brushes[0], Vec3::new(0., 0., 8.)));
        assert!(!inside(&brushes[1], Vec3::new(0., 0., 8.)));
        assert!(inside(&brushes[1], Vec3::new(1000., -500., 40.)));
        assert!(inside(&brushes[1], Vec3::new(1060., -440., 40.)));
        assert!(!inside(&brushes[1], Vec3::new(1000., -500., 20.)));
        let up = brushes[1].iter().find(|q| q[1] > 0.99).unwrap();
        assert!((up[3] - (-500. + 64.)).abs() < 0.01);
    }

    #[test]
    fn keeps_every_brush_when_the_tree_is_missing() {
        let mut lumps = box_brush(0x1, 6);
        let brushes = lumps[2].1.clone();
        lumps[2].1.extend(brushes);
        assert_eq!(parse(&build(&lumps)).unwrap().brushes.len(), 2);
    }

    #[test]
    fn reads_left_4_dead_2_maps() {
        let data = build_as(21, LEFT4DEAD2, &box_brush(0x1, 6));
        let solids = parse(&data).unwrap();
        assert_eq!(solids.brushes.len(), 1);
        assert_eq!(solids.brushes[0].len(), 6);
        // Portal 2 and CS:GO maps share the version and keep the usual order.
        let data = build_as(21, STANDARD, &box_brush(0x1, 6));
        assert_eq!(parse(&data).unwrap().brushes.len(), 1);
    }

    #[test]
    fn survives_a_brush_claiming_billions_of_sides() {
        let data = build(&box_brush(0x1, i32::MAX));
        let solids = parse(&data).unwrap();
        assert_eq!(solids.brushes[0].len(), 6);
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
            // A bevel cutting the corner; Source only uses it for traces.
            ([0.707, 0.707, 0.], 60.),
        ] {
            planes.extend(plane(n, d));
        }
        let mut sides = Vec::new();
        for i in 0..7u16 {
            sides.extend_from_slice(&i.to_le_bytes());
            sides.extend_from_slice(&[0, 0, 0, 0, u8::from(i == 6), 0]);
        }
        let mut brushes = Vec::new();
        for contents in [0x1i32, 0x20] {
            brushes.extend_from_slice(&0i32.to_le_bytes());
            brushes.extend_from_slice(&7i32.to_le_bytes());
            brushes.extend_from_slice(&contents.to_le_bytes());
        }
        let data = build(&[
            (LUMP_PLANES, planes),
            (LUMP_BRUSHSIDES, sides),
            (LUMP_BRUSHES, brushes),
        ]);
        let solids = parse(&data).unwrap();
        assert_eq!(solids.brushes.len(), 1, "the water brush is skipped");
        assert_eq!(solids.brushes[0].len(), 6, "the bevel side is skipped");
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
