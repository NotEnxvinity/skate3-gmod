//! The skater's rig and board mesh, read from the `skater.glb` the setup
//! script writes into the player's own data folder.
//!
//! The board's parts are rigid, so each triangle is stored relative to the bone
//! that carries it (deck, trucks, wheels). Lua builds a mesh per part once and
//! draws it under that bone's matrix every frame.

use std::path::Path;

use glam::{Mat4, Vec3, Vec4};
use serde_json::Value;
use skate_bridge::collision;

/// A rigid piece of the board in Source units, relative to `bone`.
pub struct Part {
    pub bone: String,
    /// The material slot, such as `SkateBoard` or `SkateWheel`.
    pub slot: String,
    pub tint: [f32; 4],
    /// Triangle list: x, y, z, nx, ny, nz, u, v per vertex.
    pub vertices: Vec<f32>,
}

pub struct Skater {
    pub parts: Vec<Part>,
    /// Each joint's bind pose in Source space, as `Session` poses would read.
    pub bind: Vec<(String, Mat4)>,
}

/// The skeleton's Blender basis the exporter wrote into the inverse binds.
fn rig_basis() -> Mat4 {
    Mat4::from_cols(Vec4::X, -Vec4::Z, Vec4::Y, Vec4::W)
}

/// A skate-space bone matrix as a Source-space one.
pub fn to_source(m: Mat4) -> Mat4 {
    let b = collision::basis();
    let mut out = b * m * b.inverse();
    out.w_axis = collision::from_skate(m.w_axis.truncate()).extend(1.);
    out
}

pub fn load(assets: &Path) -> Result<Skater, String> {
    let path = assets.join("private/skater.glb");
    let bytes = std::fs::read(&path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    let glb = Glb::parse(&bytes)?;

    let skin = &glb.json["skins"][0];
    let joints = skin["joints"].as_array().ok_or("skater.glb has no skin")?;
    let names = joints
        .iter()
        .map(|j| {
            let node = index(j)?;
            glb.json["nodes"][node]["name"]
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| format!("joint node {node} has no name"))
        })
        .collect::<Result<Vec<_>, String>>()?;
    let inverse_binds = glb.floats(index(&skin["inverseBindMatrices"])?)?;
    if inverse_binds.len() != names.len() * 16 {
        return Err("skater.glb: inverse binds don't match its joints".into());
    }
    // Skate bone-local frames: a posed bone matrix times this is the skin.
    let local: Vec<Mat4> = inverse_binds
        .chunks_exact(16)
        .map(|m| rig_basis() * Mat4::from_cols_slice(m))
        .collect();
    let bind = names
        .iter()
        .zip(&local)
        .map(|(name, l)| (name.clone(), to_source(l.inverse())))
        .collect();

    let mut parts: Vec<Part> = Vec::new();
    let primitives = glb.json["meshes"][0]["primitives"]
        .as_array()
        .ok_or("skater.glb has no mesh")?;
    for primitive in primitives {
        let material = &glb.json["materials"][index(&primitive["material"])?];
        let name = material["name"].as_str().unwrap_or("");
        // The body's slots are the playermodel's job; only the board is drawn.
        let Some(slot) = name
            .strip_prefix("Retail_")
            .filter(|s| s.starts_with("Skate"))
        else {
            continue;
        };
        let tint = material["pbrMetallicRoughness"]["baseColorFactor"]
            .as_array()
            .map(|c| std::array::from_fn(|i| c.get(i).and_then(Value::as_f64).unwrap_or(1.) as f32))
            .unwrap_or([1.; 4]);
        let a = &primitive["attributes"];
        let positions = glb.floats(index(&a["POSITION"])?)?;
        let normals = glb.floats(index(&a["NORMAL"])?)?;
        let uvs = glb.floats(index(&a["TEXCOORD_0"])?)?;
        let bones = glb.integers(index(&a["JOINTS_0"])?)?;
        let weights = glb.floats(index(&a["WEIGHTS_0"])?)?;
        let count = positions.len() / 3;
        if normals.len() != count * 3
            || uvs.len() != count * 2
            || bones.len() != count * 4
            || weights.len() != count * 4
        {
            return Err(format!("skater.glb: {slot}'s vertex streams disagree"));
        }
        let dominant = |v: usize| {
            (0..4)
                .max_by(|&x, &y| weights[v * 4 + x].total_cmp(&weights[v * 4 + y]))
                .map(|i| bones[v * 4 + i] as usize)
                .unwrap_or(0)
        };
        let indices = glb.integers(index(&primitive["indices"])?)?;
        for tri in indices.chunks_exact(3) {
            let corners = [tri[0] as usize, tri[2] as usize, tri[1] as usize];
            if corners.iter().any(|&v| v >= count) {
                return Err(format!("skater.glb: {slot} indexes past its vertices"));
            }
            // The whole triangle rides the bone carrying its first corner.
            let joint = dominant(corners[0]);
            let l = *local.get(joint).ok_or("skater.glb: joint out of range")?;
            let part = match parts
                .iter()
                .position(|p| p.bone == names[joint] && p.slot == slot)
            {
                Some(i) => &mut parts[i],
                None => {
                    parts.push(Part {
                        bone: names[joint].clone(),
                        slot: slot.to_owned(),
                        tint,
                        vertices: Vec::new(),
                    });
                    parts.last_mut().unwrap()
                }
            };
            for v in corners {
                let p = l.transform_point3(Vec3::from_slice(&positions[v * 3..v * 3 + 3]));
                let n = l.transform_vector3(Vec3::from_slice(&normals[v * 3..v * 3 + 3]));
                let p = collision::from_skate(p);
                let n = collision::basis()
                    .transform_vector3(n)
                    .normalize_or(Vec3::Z);
                part.vertices.extend_from_slice(&[
                    p.x,
                    p.y,
                    p.z,
                    n.x,
                    n.y,
                    n.z,
                    uvs[v * 2],
                    uvs[v * 2 + 1],
                ]);
            }
        }
    }
    if parts.is_empty() {
        return Err(format!("{} has no skateboard in it", path.display()));
    }
    Ok(Skater { parts, bind })
}

fn index(v: &Value) -> Result<usize, String> {
    v.as_u64()
        .map(|i| i as usize)
        .ok_or_else(|| "skater.glb: missing index".into())
}

/// A binary glTF: its JSON and its one binary chunk.
struct Glb<'a> {
    json: Value,
    bin: &'a [u8],
}

impl<'a> Glb<'a> {
    fn parse(bytes: &'a [u8]) -> Result<Self, String> {
        let u32_at = |at: usize| {
            bytes
                .get(at..at + 4)
                .map(|b| u32::from_le_bytes(b.try_into().unwrap()) as usize)
                .ok_or("skater.glb is truncated")
        };
        if bytes.get(..4) != Some(b"glTF") {
            return Err("skater.glb isn't a binary glTF".into());
        }
        let (mut json, mut bin) = (None, None);
        let mut at = 12;
        while at + 8 <= bytes.len() {
            let len = u32_at(at)?;
            let kind = u32_at(at + 4)?;
            let chunk = bytes
                .get(at + 8..at + 8 + len)
                .ok_or("skater.glb is truncated")?;
            match kind {
                0x4E4F_534A => json = Some(chunk),
                0x004E_4942 => bin = Some(chunk),
                _ => {}
            }
            at += 8 + len;
        }
        let json = serde_json::from_slice(json.ok_or("skater.glb has no JSON")?)
            .map_err(|e| format!("skater.glb: {e}"))?;
        Ok(Self {
            json,
            bin: bin.ok_or("skater.glb has no binary data")?,
        })
    }

    /// An accessor's components as raw little-endian values, with their type.
    fn components(&self, accessor: usize) -> Result<(Vec<&'a [u8]>, u64), String> {
        let a = &self.json["accessors"][accessor];
        let view = &self.json["bufferViews"][index(&a["bufferView"])?];
        let count = index(&a["count"])?;
        let kind = a["componentType"].as_u64().ok_or("accessor has no type")?;
        let size = match kind {
            5120 | 5121 => 1,
            5122 | 5123 => 2,
            5125 | 5126 => 4,
            _ => return Err(format!("unsupported accessor type {kind}")),
        };
        let width = match a["type"].as_str() {
            Some("SCALAR") => 1,
            Some("VEC2") => 2,
            Some("VEC3") => 3,
            Some("VEC4") => 4,
            Some("MAT4") => 16,
            other => return Err(format!("unsupported accessor shape {other:?}")),
        };
        let start = view["byteOffset"].as_u64().unwrap_or(0) as usize
            + a["byteOffset"].as_u64().unwrap_or(0) as usize;
        let stride = view["byteStride"]
            .as_u64()
            .map_or(size * width, |s| s as usize);
        let mut out = Vec::with_capacity(count * width);
        for i in 0..count {
            for c in 0..width {
                let at = start + i * stride + c * size;
                out.push(
                    self.bin
                        .get(at..at + size)
                        .ok_or("skater.glb accessor runs past its data")?,
                );
            }
        }
        Ok((out, kind))
    }

    fn floats(&self, accessor: usize) -> Result<Vec<f32>, String> {
        let (raw, kind) = self.components(accessor)?;
        if kind != 5126 {
            return Err("expected float data".into());
        }
        Ok(raw
            .iter()
            .map(|b| f32::from_le_bytes((*b).try_into().unwrap()))
            .collect())
    }

    fn integers(&self, accessor: usize) -> Result<Vec<u32>, String> {
        let (raw, kind) = self.components(accessor)?;
        raw.iter()
            .map(|b| match kind {
                5121 => Ok(u32::from(b[0])),
                5123 => Ok(u32::from(u16::from_le_bytes([b[0], b[1]]))),
                5125 => Ok(u32::from_le_bytes((*b).try_into().unwrap())),
                _ => Err("expected integer data".to_string()),
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A one-triangle board on one joint, laid out as the exporter writes it.
    fn tiny_glb(dir: &Path) {
        let mut bin = Vec::new();
        let mut views = Vec::new();
        let mut put = |data: Vec<u8>| {
            views.push(
                serde_json::json!({"buffer": 0, "byteOffset": bin.len(), "byteLength": data.len()}),
            );
            bin.extend(data);
            views.len() - 1
        };
        let f = |v: &[f32]| v.iter().flat_map(|x| x.to_le_bytes()).collect::<Vec<u8>>();
        // Bound at 1 m up (skate Y); the inverse bind undoes that.
        let ibm = put(f(&Mat4::from_translation(Vec3::new(0., 1., 0.))
            .inverse()
            .to_cols_array()));
        let pos = put(f(&[0., 1., 0., 1., 1., 0., 0., 1., 1.]));
        let nrm = put(f(&[0., 1., 0., 0., 1., 0., 0., 1., 0.]));
        let uv = put(f(&[0., 0., 1., 0., 0., 1.]));
        let joints = put([0u16; 12].iter().flat_map(|x| x.to_le_bytes()).collect());
        let weights = put(f(&[1., 0., 0., 0., 1., 0., 0., 0., 1., 0., 0., 0.]));
        let idx = put([0u32, 1, 2].iter().flat_map(|x| x.to_le_bytes()).collect());
        let acc = |view: usize, count: usize, kind: u32, shape: &str| serde_json::json!({"bufferView": view, "count": count, "componentType": kind, "type": shape});
        let json = serde_json::json!({
            "asset": {"version": "2.0"},
            "nodes": [{"name": "SKATEBOARD_ROOT"}, {"name": "mesh", "mesh": 0, "skin": 0}],
            "skins": [{"joints": [0], "inverseBindMatrices": 0}],
            "materials": [{"name": "Retail_SkateBoard", "pbrMetallicRoughness": {"baseColorFactor": [0.5, 1, 1, 1]}}],
            "meshes": [{"primitives": [{"material": 0, "indices": 6, "attributes": {
                "POSITION": 1, "NORMAL": 2, "TEXCOORD_0": 3, "JOINTS_0": 4, "WEIGHTS_0": 5}}]}],
            "accessors": [acc(ibm, 1, 5126, "MAT4"), acc(pos, 3, 5126, "VEC3"), acc(nrm, 3, 5126, "VEC3"),
                acc(uv, 3, 5126, "VEC2"), acc(joints, 3, 5123, "VEC4"), acc(weights, 3, 5126, "VEC4"),
                acc(idx, 3, 5125, "SCALAR")],
            "bufferViews": views,
            "buffers": [{"byteLength": bin.len()}],
        });
        let mut text = serde_json::to_vec(&json).unwrap();
        while text.len() % 4 != 0 {
            text.push(b' ');
        }
        let mut glb = Vec::new();
        glb.extend(b"glTF");
        glb.extend(2u32.to_le_bytes());
        glb.extend(((12 + 8 + text.len() + 8 + bin.len()) as u32).to_le_bytes());
        glb.extend((text.len() as u32).to_le_bytes());
        glb.extend(0x4E4F_534Au32.to_le_bytes());
        glb.extend(text);
        glb.extend((bin.len() as u32).to_le_bytes());
        glb.extend(0x004E_4942u32.to_le_bytes());
        glb.extend(bin);
        std::fs::create_dir_all(dir.join("private")).unwrap();
        std::fs::write(dir.join("private/skater.glb"), glb).unwrap();
    }

    #[test]
    fn reads_the_board_relative_to_its_bone() {
        let dir = std::env::temp_dir().join(format!("skate3-glb-{}", std::process::id()));
        tiny_glb(&dir);
        let skater = load(&dir).unwrap();
        std::fs::remove_dir_all(&dir).ok();
        assert_eq!(skater.parts.len(), 1);
        let part = &skater.parts[0];
        assert_eq!(
            (part.bone.as_str(), part.slot.as_str()),
            ("SKATEBOARD_ROOT", "SkateBoard")
        );
        assert_eq!(part.tint, [0.5, 1., 1., 1.]);
        assert_eq!(part.vertices.len(), 3 * 8);
        // Drawn under its bone at the bind pose, each corner lands where the
        // file put it (wound the other way for Source).
        let (_, bind) = &skater.bind[0];
        let file = [[0., 1., 0.], [0., 1., 1.], [1., 1., 0.]];
        for (v, expected) in part.vertices.chunks_exact(8).zip(file) {
            let world = bind.transform_point3(Vec3::from_slice(&v[..3]));
            let expected = collision::from_skate(Vec3::from_array(expected));
            assert!((world - expected).length() < 1e-3, "{world} vs {expected}");
            let normal = bind.transform_vector3(Vec3::from_slice(&v[3..6]));
            assert!((normal - Vec3::Z).length() < 1e-4, "{normal}");
        }
    }

    #[test]
    fn rejects_files_that_arent_glb() {
        assert!(Glb::parse(b"nope").is_err());
    }

    #[test]
    fn source_conversion_keeps_rotations_rigid() {
        // A skate bone turned 90 degrees about skate up (Y) turns about Source Z.
        let m = to_source(Mat4::from_rotation_y(std::f32::consts::FRAC_PI_2));
        let x = m.transform_vector3(Vec3::X);
        assert!((x - Vec3::Y).length() < 1e-5, "{x}");
        let t = to_source(Mat4::from_translation(Vec3::new(0., 1., 0.)));
        assert!((t.w_axis.truncate() - Vec3::new(0., 0., 1. / 0.0254)).length() < 1e-3);
    }
}
