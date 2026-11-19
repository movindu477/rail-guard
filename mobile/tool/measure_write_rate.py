"""Measures actual live Firestore write rate on train_position/unit-01
standing (65 s) and moving (25 s, > 15 m every 5 s) using adb geo fix."""
import os
import subprocess
import time
import firebase_admin
from firebase_admin import credentials, firestore

ADB = os.path.expandvars(r"%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe")

cred = credentials.Certificate(os.path.expanduser("~/.railguard/firebase-key.json"))
if not firebase_admin._apps:
    firebase_admin.initialize_app(cred)
db = firestore.client()

writes = []

def on_snap(doc_snapshot, changes, read_time):
    for doc in doc_snapshot:
        d = doc.to_dict() or {}
        ts = d.get("timestamp")
        writes.append((time.monotonic(), ts, d.get("latitude"), d.get("longitude")))

doc_ref = db.collection("train_position").document("unit-01")
watch = doc_ref.on_snapshot(on_snap)

# Allow initial snapshot to settle
time.sleep(2)
writes.clear()

print("=== Phase 1: STANDING (65 s) ===")
t_stand_start = time.monotonic()
time.sleep(65)
t_stand_end = time.monotonic()
standing_writes = list(writes)
stand_elapsed = t_stand_end - t_stand_start
stand_intervals = [
    standing_writes[i][0] - standing_writes[i - 1][0]
    for i in range(1, len(standing_writes))
]
print(f"Standing writes in {stand_elapsed:.1f} s: {len(standing_writes)}")
if stand_intervals:
    avg_stand_s = sum(stand_intervals) / len(stand_intervals)
    print(f"Standing intervals (s): {[round(x, 2) for x in stand_intervals]}, avg={avg_stand_s:.2f} s -> {3600/avg_stand_s:.1f} writes/hr")
else:
    print(f"Standing rate: {len(standing_writes) * 3600 / stand_elapsed:.1f} writes/hr")

writes.clear()
print("\n=== Phase 2: MOVING (> 20 m every 5 s for 25 s) ===")
lat = 6.95653
lon = 80.65955
t_move_start = time.monotonic()
for step in range(1, 6):
    lat += 0.00025  # ~28 m north per step
    subprocess.run(
        [ADB, "-s", "emulator-5554", "emu", "geo", "fix", f"{lon:.5f}", f"{lat:.5f}"],
        capture_output=True,
    )
    time.sleep(5)
time.sleep(1)
t_move_end = time.monotonic()
moving_writes = list(writes)
move_elapsed = t_move_end - t_move_start
move_intervals = [
    moving_writes[i][0] - moving_writes[i - 1][0]
    for i in range(1, len(moving_writes))
]
print(f"Moving writes in {move_elapsed:.1f} s: {len(moving_writes)}")
if move_intervals:
    avg_move_s = sum(move_intervals) / len(move_intervals)
    print(f"Moving intervals (s): {[round(x, 2) for x in move_intervals]}, avg={avg_move_s:.2f} s -> {3600/avg_move_s:.1f} writes/hr")
else:
    print(f"Moving rate: {len(moving_writes) * 3600 / move_elapsed:.1f} writes/hr")

watch.unsubscribe()
