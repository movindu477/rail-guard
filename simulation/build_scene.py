"""
Build the RailGuard synthetic railway scene.

Run headless:
    blender --background --python simulation/build_scene.py

Produces a straight track at exact 1676 mm gauge viewed by a pinhole camera of
known focal length, so distance ground truth is exact by construction rather
than measured. Used to validate the gauge-referenced distance formula and to
characterise track-detection error independently of it.
"""
import bpy, os, math, csv
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Vector

GAUGE      = 1.676          # Sri Lankan broad gauge, metres
HALF       = GAUGE / 2.0
RAIL_Z     = 0.195          # rail top height above ballast
CAM_HEIGHT = 2.0            # locomotive cab eye height
SENSOR_MM  = 6.17
RES_X, RES_Y = 1920, 1080
TRACK_LEN  = 600.0

HERE = os.path.dirname(os.path.abspath(__file__))
OUT  = os.path.join(HERE, "renders")


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


def build_scene():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)

    bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 800, -0.56))
    g = bpy.context.object; g.name = "Grass"; g.scale = (120, 1100, 0.5)
    g.data.materials.append(noisy_mat("GrassMat", (0.06,0.15,0.03), (0.18,0.30,0.07),
                                      scale=90, bump=0.1))

    bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 800, -0.5))
    b = bpy.context.object; b.name = "Ballast"; b.scale = (2.6, 1100, 0.5)
    b.data.materials.append(noisy_mat("BallastMat", (0.17,0.16,0.15), (0.52,0.49,0.45),
                                      scale=260, bump=0.6))

    bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 0, 0.06))
    s = bpy.context.object; s.name = "Sleeper"; s.scale = (1.25, 0.125, 0.06)
    s.data.materials.append(noisy_mat("SleeperMat", (0.08,0.05,0.03), (0.24,0.16,0.09),
                                      scale=70, rough=0.88, bump=0.3))
    a = s.modifiers.new("Array", 'ARRAY')
    a.count = 1000
    a.relative_offset_displace = (0.0, 2.4, 0.0)     # 0.25 m * 2.4 = 0.6 m pitch

    rail = noisy_mat("RailMat", (0.30,0.22,0.17), (0.62,0.62,0.64),
                     scale=25, rough=0.32, metal=1.0, bump=0.08)
    for side, x in (("L", -HALF), ("R", +HALF)):
        bpy.ops.mesh.primitive_cube_add(size=2, location=(x, TRACK_LEN/2, RAIL_Z))
        r = bpy.context.object; r.name = f"Rail_{side}"
        r.scale = (0.035, TRACK_LEN/2, 0.075)
        r.data.materials.append(rail)

    pole = noisy_mat("PoleMat", (0.10,0.07,0.05), (0.30,0.24,0.18),
                     scale=40, rough=0.9, bump=0.2)
    bpy.ops.mesh.primitive_cylinder_add(radius=0.11, depth=7.0,
                                        location=(4.2, 30, 3.5), vertices=10)
    p = bpy.context.object; p.name = "Pole"; p.data.materials.append(pole)
    pa = p.modifiers.new("Array", 'ARRAY'); pa.count = 25
    pa.use_relative_offset = False; pa.use_constant_offset = True
    pa.constant_offset_displace = (0, 40.0, 0)

    cd = bpy.data.cameras.new("CabCam")
    cd.lens = 5.0; cd.sensor_width = SENSOR_MM; cd.sensor_fit = 'HORIZONTAL'
    cd.clip_start, cd.clip_end = 0.1, 3000.0
    cam = bpy.data.objects.new("CabCam", cd)
    cam.location = (0.0, 0.0, CAM_HEIGHT)
    cam.rotation_euler = (math.radians(90), 0.0, 0.0)
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
    sc.render.engine = 'BLENDER_EEVEE_NEXT'
    sc.render.resolution_x, sc.render.resolution_y = RES_X, RES_Y
    sc.render.resolution_percentage = 100
    sc.render.image_settings.file_format = 'PNG'
    sc.view_settings.view_transform = 'AgX'
    sc.view_settings.look = 'AgX - Base Contrast'
    sc.view_settings.exposure = 0.4
    return cam


def render_with_truth(cam, tag, focal_mm):
    """Render at this focal length and write exact per-row ground truth."""
    os.makedirs(OUT, exist_ok=True)
    sc = bpy.context.scene
    cam.data.lens = focal_mm
    fx = (focal_mm / SENSOR_MM) * RES_X

    rows, D = [], 3.0
    while D <= 600.0:
        pL = world_to_camera_view(sc, cam, Vector((-HALF, D, RAIL_Z)))
        pR = world_to_camera_view(sc, cam, Vector((+HALF, D, RAIL_Z)))
        sep   = abs(pR.x - pL.x) * RES_X
        row_y = (1.0 - pL.y) * RES_Y
        cx    = ((pL.x + pR.x) / 2.0) * RES_X
        if 0 <= row_y < RES_Y and sep < RES_X:
            rows.append((round(row_y, 3), round(D, 3), round(sep, 4), round(cx, 3)))
        D += 0.25 if D < 50 else (1.0 if D < 200 else 5.0)

    with open(os.path.join(OUT, f"{tag}_truth.csv"), "w", newline="") as f:
        wtr = csv.writer(f)
        wtr.writerow(["row_y_px", "true_distance_m", "true_rail_sep_px", "track_centre_px"])
        wtr.writerows(rows)
    with open(os.path.join(OUT, f"{tag}_camera.txt"), "w") as f:
        f.write(f"focal_mm={focal_mm}\nsensor_mm={SENSOR_MM}\nres={RES_X}x{RES_Y}\n"
                f"fx_px={fx:.6f}\ngauge_m={GAUGE}\ncam_height_m={CAM_HEIGHT}\n"
                f"rail_top_z={RAIL_Z}\n")

    sc.render.filepath = os.path.join(OUT, f"{tag}_clean.png")
    bpy.ops.render.render(write_still=True)
    print(f"{tag}: focal={focal_mm}mm  fx={fx:.2f}px  rows={len(rows)}")
    return fx


if __name__ == "__main__":
    cam = build_scene()
    render_with_truth(cam, "wide", 5.0)
    render_with_truth(cam, "tele", 50.0)
    cam.data.lens = 5.0
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(HERE, "railguard_scene.blend"))
    print("scene saved")
