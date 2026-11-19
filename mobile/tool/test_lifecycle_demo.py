import json
import os
import sys
import firebase_admin
from firebase_admin import credentials, firestore

key_path = os.path.expanduser('~/.railguard/firebase-key.json')
cred = credentials.Certificate(key_path)
if not firebase_admin._apps:
    firebase_admin.initialize_app(cred)
db = firestore.client()

with open('mobile/assets/railway_routes.json') as f:
    data = json.load(f)

r7 = next(r for r in data['routes'] if r['id'] == 'r7')
pts = r7['points']
h_pt = pts[535]
before_100 = next(p for p in pts if 10 <= (h_pt[2] - p[2]) <= 95)
past_50 = next(p for p in pts if (p[2] - h_pt[2]) >= 25)

print(f'HAZARD_PT:     lat={h_pt[0]}, lon={h_pt[1]}, chainage={h_pt[2]:.1f}')
print(f'BEFORE_100_PT: lat={before_100[0]}, lon={before_100[1]}, chainage={before_100[2]:.1f} (diff={h_pt[2]-before_100[2]:.1f}m)')
print(f'PAST_50_PT:    lat={past_50[0]}, lon={past_50[1]}, chainage={past_50[2]:.1f} (diff={past_50[2]-h_pt[2]:.1f}m)')

mode = sys.argv[1] if len(sys.argv) > 1 else 'seed'

if mode == 'seed':
    # Clear any old test hazards on r7 first (status: cleared, never delete)
    doc_id = 'step5-lifecycle-test'
    db.collection('hazards').document(doc_id).set({
        'latitude': h_pt[0],
        'longitude': h_pt[1],
        'timestamp': firestore.SERVER_TIMESTAMP,
        'object_type': 'animal',
        'severity': 'near',
        'distance_m': 42,
        'confidence': 0.91,
        'status': 'active',
        'reported_by': 'auto',
        'reported_by_uid': 'uid-camera-unit02',
        'unit_id': 'unit-02',
        'confirmed_by_uids': ['uid-driver-a', 'uid-driver-b', 'uid-driver-c'],
        'confirmed_count': 3,
        'not_seen_by_uids': ['uid-driver-d'],
        'not_seen_count': 1,
        'cleared_by_uids': [],
    })
    print(f'Seeded hazard {doc_id} (confirmed by 3 drivers, not seen by 1 driver)')
elif mode == 'cleanup':
    db.collection('hazards').document('step5-lifecycle-test').update({
        'status': 'cleared',
        'cleared_by': 'test-cleanup',
        'cleared_at': firestore.SERVER_TIMESTAMP,
    })
    print('Marked step5-lifecycle-test as cleared')
