import os
import sys
import firebase_admin
from firebase_admin import credentials, firestore

key_path = os.path.expanduser('~/.railguard/firebase-key.json')
cred = credentials.Certificate(key_path)
if not firebase_admin._apps:
    firebase_admin.initialize_app(cred)
db = firestore.client()

def set_train(unit_id, train_no, driver_name, service, lat, lon, heading, speed_mps):
    db.collection('train_position').document(unit_id).set({
        'unit_id': unit_id,
        'train_no': train_no,
        'driver_name': driver_name,
        'service': service,
        'latitude': lat,
        'longitude': lon,
        'heading': heading,
        'speed_mps': speed_mps,
        'accuracy_m': 5.0,
        'timestamp': firestore.SERVER_TIMESTAMP,
    })
    print(f'Set {unit_id} ({train_no} {service}) at {lat:.5f}, {lon:.5f}, speed={speed_mps} mps, heading={heading}')

if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'approaching'
    if mode == 'approaching':
        # unit-01 at Curve 1 start on r7: 6.95653, 80.65955, chainage 75375.8, service DOWN (facing increasing chainage)
        set_train('unit-01', '1005', 'Nehan Perera', 'down', 6.95653, 80.65955, 99.0, 10.0)
        # unit-02 at index 545 on r7: 6.95866, 80.66062, chainage 77166.9, service UP (facing decreasing chainage towards unit-01)
        set_train('unit-02', '1006', 'P. Perera', 'up', 6.95866, 80.66062, 279.4, 15.0)
    elif mode == 'other_line':
        # unit-01 on r7: 6.95653, 80.65955
        set_train('unit-01', '1005', 'Nehan Perera', 'down', 6.95653, 80.65955, 99.0, 0.0)
        # unit-02 on r0 (Southern Line, Galle): 5.97583, 80.42686
        set_train('unit-02', '1006', 'P. Perera', 'up', 5.97583, 80.42686, 270.0, 12.0)
