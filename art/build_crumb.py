"""Build Crumb, the chibi black puppy, as a jointed model.

Run:  /Applications/Blender.app/Contents/MacOS/Blender -b -P art/build_crumb.py
Out:  art/crumb.glb, art/crumb.blend, art/previews/*.png

Every moving part hangs off a named pivot empty (HeadPivot, JawPivot, EarL...)
so the app can animate joints in code. The dog faces -Y in Blender, which
becomes +Z (toward the viewer) in glTF.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
PREVIEWS = os.path.join(HERE, "previews")
os.makedirs(PREVIEWS, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
col = scene.collection


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


MATS = {}


def mat(name, hex_color, rough=0.7):
    if name in MATS:
        return MATS[name]
    m = bpy.data.materials.new(name)
    try:
        m.use_nodes = True
    except Exception:
        pass
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    h = hex_color.lstrip("#")
    rgb = [srgb_to_linear(int(h[i:i + 2], 16) / 255) for i in (0, 2, 4)]
    bsdf.inputs["Base Color"].default_value = (*rgb, 1)
    bsdf.inputs["Roughness"].default_value = rough
    m.diffuse_color = (*rgb, 1)
    MATS[name] = m
    return m


def empty(name, loc, parent=None):
    o = bpy.data.objects.new(name, None)
    o.empty_display_type = "PLAIN_AXES"
    o.empty_display_size = 0.05
    col.objects.link(o)
    o.parent = parent
    o.location = loc
    return o


def blob(name, material, loc, scale, parent=None, rot=(0, 0, 0), segs=32):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=segs // 2, radius=1.0)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = True
    me.materials.append(material)
    o = bpy.data.objects.new(name, me)
    col.objects.link(o)
    o.parent = parent
    o.location = loc
    o.scale = scale
    o.rotation_euler = rot
    return o


def torus(name, material, loc, major, minor, parent=None, rot=(0, 0, 0)):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    seg_u, seg_v = 40, 12
    verts = []
    for i in range(seg_u):
        a = 2 * math.pi * i / seg_u
        ring = []
        for j in range(seg_v):
            b = 2 * math.pi * j / seg_v
            r = major + minor * math.cos(b)
            ring.append(bm.verts.new((r * math.cos(a), r * math.sin(a), minor * math.sin(b))))
        verts.append(ring)
    for i in range(seg_u):
        for j in range(seg_v):
            a, b = verts[i][j], verts[(i + 1) % seg_u][j]
            c, d = verts[(i + 1) % seg_u][(j + 1) % seg_v], verts[i][(j + 1) % seg_v]
            bm.faces.new((a, b, c, d))
    bm.normal_update()
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = True
    me.materials.append(material)
    o = bpy.data.objects.new(name, me)
    col.objects.link(o)
    o.parent = parent
    o.location = loc
    o.rotation_euler = rot
    return o


# ---------- Palette (matches the reference: black pup, cream chest, orange collar) ----------
FUR = mat("Fur", "#2e3038")
FUR_LIGHT = mat("FurLight", "#454852")
CREAM = mat("Cream", "#f1d9b5")
NOSE = mat("Nose", "#141418", 0.35)
EYE_WHITE = mat("EyeWhite", "#ffffff", 0.3)
PUPIL = mat("Pupil", "#17171c", 0.25)
MOUTH = mat("Mouth", "#5c1f27")
TONGUE = mat("Tongue", "#ef7f92", 0.5)
COLLAR = mat("Collar", "#e8832c", 0.5)
TAG = mat("Tag", "#f3c64a", 0.3)

# ---------- Skeleton of pivots + parts ----------
root = empty("Root", (0, 0, 0))
body_pivot = empty("BodyPivot", (0, 0.30, 0), root)          # rear, on the ground: sitting tips the front up
body = empty("BodyGroup", (0, -0.30, 0), body_pivot)        # undo the pivot offset

blob("Body", FUR, (0, 0.04, 0.40), (0.25, 0.34, 0.25), body)
blob("Chest", CREAM, (0, -0.26, 0.40), (0.10, 0.08, 0.12), body)

def leg(name, x, y):
    p = empty(name, (x, y, 0.32), body)
    blob(name + "Mesh", FUR, (0, 0, -0.15), (0.08, 0.08, 0.17), p)
    blob(name + "Paw", FUR_LIGHT, (0, -0.025, -0.285), (0.09, 0.105, 0.05), p)
    return p

leg("LegFL", 0.13, -0.16)
leg("LegFR", -0.13, -0.16)
leg("LegBL", 0.13, 0.24)
leg("LegBR", -0.13, 0.24)

def tube(name, material, pts, radii, parent):
    """Tapered round tube along a polyline (used for the tail)."""
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = 1.0
    cu.bevel_resolution = 6
    cu.use_fill_caps = True
    sp = cu.splines.new("NURBS")
    sp.points.add(len(pts) - 1)
    for p, (x, y, z), r in zip(sp.points, pts, radii):
        p.co = (x, y, z, 1)
        p.radius = r
    sp.use_endpoint_u = True
    sp.order_u = 3
    sp.resolution_u = 10
    tmp = bpy.data.objects.new(name + "Tmp", cu)
    col.objects.link(tmp)
    me = bpy.data.meshes.new_from_object(tmp.evaluated_get(bpy.context.evaluated_depsgraph_get()))
    bpy.data.objects.remove(tmp)
    for p in me.polygons:
        p.use_smooth = True
    me.materials.clear()
    me.materials.append(material)
    o = bpy.data.objects.new(name, me)
    col.objects.link(o)
    o.parent = parent
    return o


tail = empty("TailPivot", (0, 0.36, 0.50), body)
tube("Tail", FUR, [(0, 0, 0), (0, 0.08, 0.08), (0, 0.12, 0.2), (0, 0.08, 0.3)], [0.05, 0.045, 0.038, 0.03], tail)

torus("Collar", COLLAR, (0, -0.20, 0.60), 0.18, 0.038, body, rot=(math.radians(68), 0, 0))
blob("CollarTag", TAG, (0, -0.36, 0.545), (0.04, 0.018, 0.045), body)

head_pivot = empty("HeadPivot", (0, -0.18, 0.60), body)    # the neck
blob("Head", FUR, (0, -0.06, 0.28), (0.34, 0.31, 0.31), head_pivot)
blob("Muzzle", FUR_LIGHT, (0, -0.30, 0.18), (0.15, 0.12, 0.105), head_pivot)
blob("Nose", NOSE, (0, -0.415, 0.225), (0.062, 0.04, 0.045), head_pivot)
blob("MouthInside", MOUTH, (0, -0.33, 0.10), (0.09, 0.07, 0.035), head_pivot)

jaw = empty("JawPivot", (0, -0.22, 0.12), head_pivot)
blob("Jaw", FUR_LIGHT, (0, -0.09, -0.015), (0.11, 0.10, 0.045), jaw)
blob("Tongue", TONGUE, (0, -0.135, -0.03), (0.058, 0.05, 0.07), jaw, rot=(math.radians(20), 0, 0))

for side, x in (("L", 1), ("R", -1)):
    # Big chibi eyes sitting on the head surface (surface is at y ~ -0.34 here).
    eye = empty("Eye" + side, (0.13 * x, -0.315, 0.33), head_pivot)
    blob("EyeWhite" + side, EYE_WHITE, (0, 0, 0), (0.095, 0.05, 0.115), eye)
    blob("Pupil" + side, PUPIL, (0.006 * x, -0.03, -0.012), (0.075, 0.035, 0.092), eye)
    blob("Glint" + side, EYE_WHITE, (-0.022 * x, -0.062, 0.03), (0.026, 0.012, 0.026), eye, segs=16)
    blob("GlintSmall" + side, EYE_WHITE, (0.024 * x, -0.06, -0.04), (0.012, 0.008, 0.012), eye, segs=12)
    # Floppy ears: thin sideways, broad front-to-back, hanging down the sides of the head.
    ear = empty("Ear" + side, (0.27 * x, -0.02, 0.47), head_pivot)
    blob("EarMesh" + side, FUR, (0.06 * x, 0.01, -0.2), (0.07, 0.13, 0.21), ear, rot=(math.radians(8), math.radians(-16 * x), 0))

# ---------- Export ----------
bpy.ops.export_scene.gltf(
    filepath=os.path.join(HERE, "crumb.glb"),
    export_format="GLB",
    export_yup=True,
    export_apply=False,
    export_animations=False,
)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(HERE, "crumb.blend"))

# ---------- Preview renders ----------
for eng in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT", "BLENDER_WORKBENCH"):
    try:
        scene.render.engine = eng
        break
    except TypeError:
        continue
scene.render.resolution_x = scene.render.resolution_y = 520
scene.render.film_transparent = False
world = bpy.data.worlds.new("World")
scene.world = world
try:
    world.use_nodes = True
except Exception:
    pass
bg = world.node_tree.nodes.get("Background")
if bg:
    bg.inputs["Color"].default_value = (0.55, 0.62, 0.72, 1)
    bg.inputs["Strength"].default_value = 0.9

sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
sun.data.energy = 3.5
sun.rotation_euler = (math.radians(50), math.radians(-20), math.radians(-35))
col.objects.link(sun)

cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
cam.data.type = "ORTHO"
cam.data.ortho_scale = 1.75
col.objects.link(cam)
scene.camera = cam
look = Vector((0, -0.05, 0.55))

for name, pos in (("front", (0, -3, 1.0)), ("three_quarter", (2.0, -2.3, 1.1)), ("side", (3, 0, 0.75))):
    cam.location = pos
    cam.rotation_euler = (look - Vector(pos)).to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = os.path.join(PREVIEWS, name + ".png")
    bpy.ops.render.render(write_still=True)

print("BUILD_OK", scene.render.engine)
