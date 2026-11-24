"""Show what is actually in Firestore `train_position` right now.

    venv\\Scripts\\python mobile\\tool\\check_live_trains.py
    venv\\Scripts\\python mobile\\tool\\check_live_trains.py --watch

Two phones only see each other when there are TWO documents in
`train_position`, one per unit id, both recently written. The document id is
the unit id, so two apps signed on with the same unit id overwrite one
document and neither sees a second train. This prints the documents, their
age, and says which of those cases applies.

Reads only. Uses the service-account key at ~/.railguard/firebase-key.json.
"""

import argparse
import datetime as dt
import os
import sys
import time

KEY = os.path.join(os.path.expanduser("~"), ".railguard", "firebase-key.json")

# Thresholds the app itself uses (mobile/lib/trains.dart).
LIVE_S = 60
DROP_S = 300


def client():
    import firebase_admin
    from firebase_admin import credentials, firestore
    if not os.path.exists(KEY):
        sys.exit(f"No service-account key at {KEY}")
    if not firebase_admin._apps:
        firebase_admin.initialize_app(credentials.Certificate(KEY))
    return firestore.client()


def show(db):
    now = dt.datetime.now(dt.timezone.utc)
    docs = list(db.collection("train_position").stream())
    print(f"\n{now.strftime('%H:%M:%S')}  train_position: {len(docs)} document(s)")
    if not docs:
        print("  EMPTY. No app has uploaded a position. Check the app has a GPS fix "
              "and is not a simulated build (sim positions are never uploaded).")
        return
    for d in sorted(docs, key=lambda x: x.id):
        v = d.to_dict() or {}
        ts = v.get("timestamp")
        if ts is None:
            age = None
        else:
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=dt.timezone.utc)
            age = (now - ts).total_seconds()
        if age is None:
            state = "NO TIMESTAMP"
        elif age < LIVE_S:
            state = "live"
        elif age < DROP_S:
            state = "stale (shown faded)"
        else:
            state = "DROPPED (older than 5 min, not shown)"
        lat, lon = v.get("latitude"), v.get("longitude")
        print(f"  {d.id:12s} train {str(v.get('train_no', '?')):6s} "
              f"{str(v.get('service', '?')).upper():5s} "
              f"{str(v.get('driver_name', '?'))[:18]:18s} "
              f"({lat}, {lon})  "
              f"age {'?' if age is None else f'{age:5.0f}s'}  {state}")

    if len(docs) == 1:
        print("\n  >> ONLY ONE DOCUMENT. Both apps are almost certainly signed on with the\n"
              "     same unit id, so they overwrite each other. The document id above IS\n"
              "     the unit id. Change one device to a different unit id and retry.")
    else:
        fresh = 0
        for d in docs:
            ts = (d.to_dict() or {}).get("timestamp")
            if ts is None:
                continue
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=dt.timezone.utc)
            if (now - ts).total_seconds() < DROP_S:
                fresh += 1
        if fresh < 2:
            print("\n  >> Two documents, but fewer than two are recent. The older one's app is\n"
                  "     not uploading: no GPS fix, app not in the foreground, or no network.")
        else:
            print("\n  >> Two or more recent documents. Each app should be showing the other.\n"
                  "     If it is not, the problem is in the app, not the data.")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--watch", action="store_true", help="re-read every 5 s until Ctrl+C")
    args = ap.parse_args()
    db = client()
    if not args.watch:
        show(db)
        return
    try:
        while True:
            show(db)
            time.sleep(5)
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
