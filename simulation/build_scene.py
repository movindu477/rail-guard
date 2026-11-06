"""
Build the RailGuard synthetic railway scene and render it with exact ground truth.

Run headless (Blender 4.x):
    blender --background --python simulation/build_scene.py -- --radius 300 --lens wide
    blender --background --python simulation/build_scene.py -- --sweep
    blender --background --python simulation/build_scene.py -- --radius straight --lens tele --pitch -1.0

A track at exact 1676 mm gauge, straight or curving right with radius R, viewed
by a pinhole camera of known focal length and pitch, so distance ground truth is
exact by construction rather than measured. Rails, ballast and sleepers are
swept along the track centre-line, so they follow the curve.

Each render writes simulation/renders/curve_{lens}_{radius}_{clean.png,truth.csv,camera.txt}:
  truth.csv, one row per sample along the track:
    row_y_px            image row of the track centre-line at that point
    true_alongtrack_m   distance travelled along the track (what braking needs)
    rail_sep_px         gap between the left and right rail on THAT image row
                        (what a per-row detector such as TEP-Net measures)
    track_centre_px     midpoint of the two rails on that row
    formula_distance_m  fx * gauge / rail_sep_px: what a perfect detector would
                        report before any pitch correction, so curve geometry is
                        separable from detection error
Rows are kept while the track is in front of the camera and both rails are
inside the frame (on a curve the track eventually leaves the frame sideways).
"""
import argparse
import csv
import math
import os
import sys

import bpy
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Vector

GAUGE      = 1.676          # Sri Lankan broad gauge, metres (rail centre to rail centre)
HALF       = GAUGE / 2.0
RAIL_Z     = 0.195          # rail top height above ballast
CAM_HEIGHT = 2.0            # locomotive cab eye height
SENSOR_MM  = 6.17
RES_X, RES_Y = 1920, 1080
TRACK_LEN  = 1200.0         # arc length of track built (curves stop at a quarter circle)
LENSES     = {"wide": (5.0, -3.0), "tele": (50.0, -0.5)}   # focal mm, default pitch (best in the sweep)
RADII      = ("straight", "1000", "500", "300", "150")

HERE = os.path.dirname(os.path.abspath(__file__))
OUT  = os.path.join(HERE, "renders")


# ---------------- track geometry ----------------

def track_frame(s, radius):
    """(centre, perpendicular, tangent) at arc distance s; curves turn right (+x).
    radius None = straight along +y."""
    if radius is None:
        return Vector((0.0, s, 0.0)), Vector((1.0, 0.0, 0.0)), Vector((0.0, 1.0, 0.0))
    phi = s / radius
    centre = Vector((radius * (1 - math.cos(phi)), radius * math.sin(phi), 0.0))
    perp = Vector((math.cos(phi), -math.sin(phi), 0.0))       # to the right of travel
    tangent = Vector((math.sin(phi), math.cos(phi), 0.0))
    return centre, perp, tangent


def track_length(radius):
    return TRACK_LEN if radius is None else min(TRACK_LEN, radius * math.pi / 2)


# ---------------- materials ----------------

def noisy_mat(name, c1, c2, scale=40.0, rough=0.95, metal=0.0, bump=0.25):
    m = bpy.data.materials.new(name); m.use_nodes = True
    nt, n = m.node_tree, m.node_tree.nodes
    bsdf = n["Principled BSDF"]
    tex  = n.new("ShaderNodeTexNoise"); tex.inputs["Scale"].default_value = scale
    tex.inputs["Detail"].default_value = 8.0
    ramp = n.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (*c1, 1)
    ramp.color_ramp.elements[1].color = (*c2, 1)
    bmp  = n.new("ShaderNodeBump"); bmp.inputs["Strength"].default_value = bump
    nt.links.new(tex.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(tex.outputs["Fac"], bmp.inputs["Height"])
    nt.links.new(bmp.outputs["Normal"], bsdf.inputs["Normal"])
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value  = metal
    return m


def mesh_object(name, verts, faces, material):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(v) for v in verts], [], faces)
    me.update()
    ob = bpy.data.objects.new(name, me)
    ob.data.materials.append(material)
    bpy.context.collection.objects.link(ob)
    return ob


def sweep(name, radius, profile, material, step=1.0, closed=False):
    """Extrude a cross-section along the track. profile: [(across m, z m)],
    across measured along the local perpendicular. closed: join last to first."""
    length = track_length(radius)
    n_steps = int(math.ceil(length / step))
    k = len(profile)
    verts, faces = [], []
    for i in range(n_steps + 1):
        c, perp, _ = track_frame(min(i * step, length), radius)
        for across, z in profile:
            verts.append(c + perp * across + Vector((0, 0, z)))
    for i in range(n_steps):
        a, b = i * k, (i + 1) * k
        for j in range(k if closed else k - 1):
            j2 = (j + 1) % k
            faces.append((a + j, a + j2, b + j2, b + j))
    return mesh_object(name, verts, faces, material)


def box_mesh(name, centres_frames, half, material):
    """One mesh of boxes; centres_frames: [(centre, perp, tangent)], half = (across, along, height)."""
    hx, hy, hz = half
    verts, faces = [], []
    for c, perp, tan in centres_frames:
        base = len(verts)
        for dz in (-hz, hz):
            for dy in (-hy, hy):
                for dx in (-hx, hx):
                    verts.append(c + perp * dx + tan * dy + Vector((0, 0, dz)))
        q = lambda a, b, cc, d: (base + a, base + b, base + cc, base + d)
        faces += [q(0, 1, 3, 2), q(4, 6, 7, 5), q(0, 4, 5, 1), q(2, 3, 7, 6), q(0, 2, 6, 4), q(1, 5, 7, 3)]
    return mesh_object(name, verts, faces, material)


# ---------------- scene ----------------

def build_scene(radius, poles=True):
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    for block in (bpy.data.meshes, bpy.data.materials):
        for item in list(block):
            if item.users == 0:
                block.remove(item)

    bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 600, -0.56))
    g = bpy.context.object; g.name = "Grass"; g.scale = (1600, 1600, 0.5)
    g.data.materials.append(noisy_mat("GrassMat", (0.06, 0.15, 0.03), (0.18, 0.30, 0.07),
                                      scale=90, bump=0.1))

    ballast = noisy_mat("BallastMat", (0.17, 0.16, 0.15), (0.52, 0.49, 0.45), scale=260, bump=0.6)
    sweep("Ballast", radius, [(-2.6, 0.0), (2.6, 0.0)], ballast, step=1.0)

    sleeper = noisy_mat("SleeperMat", (0.08, 0.05, 0.03), (0.24, 0.16, 0.09),
                        scale=70, rough=0.88, bump=0.3)
    length = track_length(radius)
    frames = []
    s = 0.3
    while s < length:
        c, perp, tan = track_frame(s, radius)
        frames.append((c + Vector((0, 0, 0.06)), perp, tan))
        s += 0.6
    box_mesh("Sleepers", frames, (1.25, 0.125, 0.06), sleeper)

    rail = noisy_mat("RailMat", (0.30, 0.22, 0.17), (0.62, 0.62, 0.64),
                     scale=25, rough=0.32, metal=1.0, bump=0.08)
    for side, off in (("L", -HALF), ("R", +HALF)):
        profile = [(off - 0.035, 0.12), (off + 0.035, 0.12), (off + 0.035, 0.27), (off - 0.035, 0.27)]
        sweep(f"Rail_{side}", radius, profile, rail, step=1.0, closed=True)

    pole = noisy_mat("PoleMat", (0.10, 0.07, 0.05), (0.30, 0.24, 0.18), scale=40, rough=0.9, bump=0.2)
    s = 30.0
    while poles and s < length:
        c, perp, _ = track_frame(s, radius)
        bpy.ops.mesh.primitive_cylinder_add(radius=0.11, depth=7.0, vertices=10,
                                            location=tuple(c + perp * 4.2 + Vector((0, 0, 3.5))))
        bpy.context.object.data.materials.append(pole)
        s += 40.0

    cd = bpy.data.cameras.new("CabCam")
    cd.sensor_width = SENSOR_MM; cd.sensor_fit = 'HORIZONTAL'
    cd.clip_start, cd.clip_end = 0.1, 3000.0
    cam = bpy.data.objects.new("CabCam", cd)
    cam.location = (0.0, 0.0, CAM_HEIGHT)
    bpy.context.collection.objects.link(cam)
    bpy.context.scene.camera = cam

    ld = bpy.data.lights.new("Sun", 'SUN'); ld.energy = 4.5
    ld.angle = math.radians(1.0)
    sun = bpy.data.objects.new("Sun", ld)
    sun.location = (50, 200, 80)
    sun.rotation_euler = (math.radians(42), 0, math.radians(150))
    bpy.context.collection.objects.link(sun)

    w = bpy.context.scene.world or bpy.data.worlds.new("World")
    bpy.context.scene.world = w; w.use_nodes = True
    bg = w.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (0.30, 0.48, 0.80, 1.0)
    bg.inputs[1].default_value = 0.9

    sc = bpy.context.scene
    engines = {e.identifier for e in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items}
    sc.render.engine = 'BLENDER_EEVEE_NEXT' if 'BLENDER_EEVEE_NEXT' in engines else 'BLENDER_EEVEE'
    sc.render.resolution_x, sc.render.resolution_y = RES_X, RES_Y
    sc.render.resolution_percentage = 100
    sc.render.image_settings.file_format = 'PNG'
    sc.view_settings.view_transform = 'AgX'
    sc.view_settings.look = 'AgX - Base Contrast'
    sc.view_settings.exposure = 0.4
    return cam


# ---------------- ground truth ----------------

def project(sc, cam, p):
    """(x px, y px from the top, depth m) of a world point."""
    v = world_to_camera_view(sc, cam, p)
    return v.x * RES_X, (1.0 - v.y) * RES_Y, v.z


def rail_x_at_row(sc, cam, radius, offset, row, s_hint):
    """x where the rail at `offset` crosses image row `row` (bisection along s;
    rows decrease monotonically as the rail recedes). None if it does not."""
    def row_of(s):
        c, perp, _ = track_frame(s, radius)
        return project(sc, cam, c + perp * offset + Vector((0, 0, RAIL_Z)))
    lo, hi = max(1.0, s_hint * 0.5 - 2.0), min(track_length(radius), s_hint * 1.5 + 2.0)
    if not (row_of(lo)[1] >= row >= row_of(hi)[1]):
        return None
    for _ in range(50):
        mid = (lo + hi) / 2
        if row_of(mid)[1] > row:
            lo = mid
        else:
            hi = mid
    x, _, depth = row_of((lo + hi) / 2)
    return x if depth > 0 else None


def render_with_truth(cam, radius, lens, suffix=""):
    os.makedirs(OUT, exist_ok=True)
    sc = bpy.context.scene
    focal_mm, pitch_deg = lens["focal_mm"], lens["pitch_deg"]
    cam.data.lens = focal_mm
    cam.rotation_euler = (math.radians(90.0 + pitch_deg), 0.0, 0.0)   # 90 = level, looking +y
    bpy.context.view_layer.update()
    fx = (focal_mm / SENSOR_MM) * RES_X
    tag = f"curve_{lens['name']}_{'straight' if radius is None else f'r{int(radius)}'}{suffix}"

    rows, s = [], 3.0
    length = track_length(radius)
    while s <= length:
        c, _, _ = track_frame(s, radius)
        cx_px, row, depth = project(sc, cam, c + Vector((0, 0, RAIL_Z)))
        if depth > 0 and 0 <= row < RES_Y:
            xl = rail_x_at_row(sc, cam, radius, -HALF, row, s)
            xr = rail_x_at_row(sc, cam, radius, +HALF, row, s)
            if xl is not None and xr is not None and 0 <= xl < RES_X and 0 <= xr < RES_X:
                sep = xr - xl
                rows.append((round(row, 3), round(s, 3), round(sep, 4), round((xl + xr) / 2, 3),
                             round(fx * GAUGE / sep, 3)))
            elif rows:
                break                      # the track has left the frame
        s += 0.25 if s < 50 else (1.0 if s < 200 else 5.0)

    with open(os.path.join(OUT, f"{tag}_truth.csv"), "w", newline="") as f:
        wtr = csv.writer(f)
        wtr.writerow(["row_y_px", "true_alongtrack_m", "rail_sep_px", "track_centre_px", "formula_distance_m"])
        wtr.writerows(rows)
    with open(os.path.join(OUT, f"{tag}_camera.txt"), "w") as f:
        f.write(f"focal_mm={focal_mm}\nsensor_mm={SENSOR_MM}\nres={RES_X}x{RES_Y}\n"
                f"fx_px={fx:.6f}\ngauge_m={GAUGE}\ncam_height_m={CAM_HEIGHT}\n"
                f"rail_top_z={RAIL_Z}\npitch_deg={pitch_deg}\n"
                f"curve_radius_m={'straight' if radius is None else float(radius)}\n")

    sc.render.filepath = os.path.join(OUT, f"{tag}_clean.png")
    bpy.ops.render.render(write_still=True)
    far = rows[-1][1] if rows else 0
    print(f"{tag}: focal {focal_mm} mm, pitch {pitch_deg:+g} deg, fx {fx:.1f} px, "
          f"{len(rows)} truth rows, track in frame to {far:g} m")
    return tag


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser(prog="build_scene.py")
    ap.add_argument("--radius", choices=RADII, default="straight")
    ap.add_argument("--lens", choices=list(LENSES), default="wide")
    ap.add_argument("--pitch", type=float, help="camera pitch in deg, negative = down (default: per lens)")
    ap.add_argument("--sweep", action="store_true", help="every radius with both lenses")
    ap.add_argument("--save-blend", action="store_true", help="also save the last scene as a .blend")
    ap.add_argument("--no-poles", action="store_true", help="leave out the trackside poles")
    ap.add_argument("--suffix", default="", help="added to the output names, e.g. _nopoles")
    return ap.parse_args(argv)


if __name__ == "__main__":
    args = parse_args()
    jobs = ([(r, l) for r in RADII for l in LENSES] if args.sweep else [(args.radius, args.lens)])
    built = None
    for radius_s, lens_name in jobs:
        radius = None if radius_s == "straight" else float(radius_s)
        if built != radius_s:
            cam = build_scene(radius, poles=not args.no_poles)
            built = radius_s
        focal, default_pitch = LENSES[lens_name]
        pitch = args.pitch if args.pitch is not None else default_pitch
        render_with_truth(cam, radius, {"name": lens_name, "focal_mm": focal, "pitch_deg": pitch},
                          suffix=args.suffix)
    if args.save_blend:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.join(HERE, "railguard_scene_built.blend"))
    print("done")
