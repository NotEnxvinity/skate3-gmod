"""Renders the spawn menu icon, materials/entities/weapon_skate3.png: a plain
skateboard built here from primitives (nothing from Skate 3), lit and framed
like Garry's Mod's own spawn icons, on a transparent background.

    python workshop/render_icon.py addon/materials/entities/weapon_skate3.png

Needs Blender's Python module (pip install bpy).
"""
import math, sys
import bpy, bmesh
from mathutils import Vector

out = sys.argv[-1]
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def material(name, color, rough=0.6, metal=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    p = m.node_tree.nodes["Principled BSDF"]
    p.inputs["Base Color"].default_value = (*color, 1)
    p.inputs["Roughness"].default_value = rough
    p.inputs["Metallic"].default_value = metal
    return m


GRIP = material("grip", (0.02, 0.02, 0.022), 0.95)
WOOD = material("wood", (0.62, 0.42, 0.22), 0.55)
GRAPHIC = material("graphic", (0.85, 0.12, 0.08), 0.45)
METAL = material("metal", (0.55, 0.56, 0.58), 0.3, 1.0)
WHEEL = material("wheel", (0.93, 0.92, 0.86), 0.45)

# Deck: 80 x 21 cm, rounded ends, nose and tail kicked up 14 degrees.
L, W, T = 0.80, 0.21, 0.012
FLAT = 0.25  # half-length of the flat middle
bm = bmesh.new()
seg_x, seg_y = 96, 24
verts = {}
for i in range(seg_x + 1):
    for j in range(seg_y + 1):
        x = -L / 2 + L * i / seg_x
        y = -W / 2 + W * j / seg_y
        # Round the ends: pull the corners in along a half-circle.
        end = abs(x) - (L / 2 - W / 2)
        if end > 0:
            half = math.sqrt(max((W / 2) ** 2 - end ** 2, 0))
            y = y / (W / 2) * half
        kick = max(abs(x) - FLAT, 0)
        z = kick * math.tan(math.radians(14)) + 0.004 * (abs(y) / (W / 2)) ** 2  # slight concave
        verts[i, j] = bm.verts.new((x, y, z))
for i in range(seg_x):
    for j in range(seg_y):
        bm.faces.new((verts[i, j], verts[i + 1, j], verts[i + 1, j + 1], verts[i, j + 1]))
mesh = bpy.data.meshes.new("deck")
bm.to_mesh(mesh)
deck = bpy.data.objects.new("deck", mesh)
scene.collection.objects.link(deck)
solid = deck.modifiers.new("solid", "SOLIDIFY")
solid.thickness = T
solid.offset = -1
solid.material_offset = 1
solid.material_offset_rim = 2
deck.data.materials.append(GRIP)
deck.data.materials.append(GRAPHIC)
deck.data.materials.append(WOOD)
bevel = deck.modifiers.new("bevel", "BEVEL")
bevel.width = 0.003
bevel.segments = 2
for p in deck.data.polygons:
    p.use_smooth = True


def add(obj, mat):
    obj.data.materials.append(mat)
    for p in obj.data.polygons:
        p.use_smooth = True
    return obj


# Trucks and wheels, under the deck at both ends of the flat part.
for side in (-1, 1):
    x = side * (FLAT - 0.035)
    bpy.ops.mesh.primitive_cube_add(size=1, location=(x, 0, -T - 0.012))
    base = bpy.context.object
    base.scale = (0.06, 0.08, 0.02)
    add(base, METAL)
    bpy.ops.mesh.primitive_cylinder_add(radius=0.012, depth=0.20, location=(x, 0, -T - 0.042),
                                        rotation=(math.pi / 2, 0, 0))
    add(bpy.context.object, METAL)
    bpy.ops.mesh.primitive_cone_add(radius1=0.022, radius2=0.012, depth=0.03, location=(x, 0, -T - 0.03))
    add(bpy.context.object, METAL)
    for y in (-0.105, 0.105):
        bpy.ops.mesh.primitive_cylinder_add(vertices=48, radius=0.027, depth=0.032, location=(x, y, -T - 0.042),
                                            rotation=(math.pi / 2, 0, 0))
        w = bpy.context.object
        b = w.modifiers.new("bevel", "BEVEL")
        b.width = 0.006
        b.segments = 4
        add(w, WHEEL)

# Three-quarter view from above the nose, like Garry's Mod's prop icons.
cam_data = bpy.data.cameras.new("cam")
cam_data.lens = 64
cam = bpy.data.objects.new("cam", cam_data)
scene.collection.objects.link(cam)
cam.location = Vector((0.7, -1.15, 0.6))
direction = Vector((0, 0, -0.02)) - cam.location
cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
scene.camera = cam

for name, energy, rot in (("key", 4.0, (50, 10, 30)), ("fill", 1.5, (60, -20, 200)), ("rim", 2.5, (120, 0, 110))):
    light = bpy.data.objects.new(name, bpy.data.lights.new(name, "SUN"))
    light.data.energy = energy
    light.rotation_euler = [math.radians(a) for a in rot]
    scene.collection.objects.link(light)
world = bpy.data.worlds.new("world")
world.use_nodes = True
world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.35, 0.35, 0.38, 1)
world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.6
scene.world = world

scene.render.engine = "CYCLES"
scene.cycles.samples = 96
scene.cycles.device = "CPU"
scene.render.film_transparent = True
scene.render.resolution_x = scene.render.resolution_y = 512
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.view_settings.view_transform = "Standard"
scene.render.filepath = out
bpy.ops.render.render(write_still=True)
