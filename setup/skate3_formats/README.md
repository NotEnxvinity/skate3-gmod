Readers for Skate 3's park and world files (EA "EB" archives, RenderWare 4
arenas, Xbox textures and collision). Read-only; they never write game files.

From NativeX World Studio (https://github.com/NativeXex/nativex-world-studio-skate3,
MIT, LICENSE-NativeX.txt): archive.py, arena.py, geometry.py,
world_materials.py, world_textures.py. archive.py is changed to read stored
(codec 0) chunks and to place each chunk header so its data is aligned, which
parkassets.big needs.

From SK8-Engine (https://github.com/SK8-ENGINE/SK8-Engine, tree 311cd40, MIT,
LICENSE-SK8-ENGINE.txt), as vendored by NativeX: skate3_streams.py and
retail_collision_mesh.py (with NativeX's unsigned 16-bit offset fix; S3GM
adds a mode that skips what it can't read instead of failing the whole mesh,
and reads triangle-list units as strips).
world_textures.py's Xbox tiling math also follows SK8-Engine.
