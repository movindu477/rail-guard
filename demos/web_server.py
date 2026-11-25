"""Start the RailGuard web backend.

    python demos/web_server.py

Then in another terminal:

    cd web
    npm run dev

The browser page talks to this process. Both run on this machine because the
camera and the GPU are on this machine.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import uvicorn


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8000)
    args = ap.parse_args()
    print(f"RailGuard backend on http://127.0.0.1:{args.port}")
    print("Frontend: cd web && npm run dev")
    uvicorn.run("railguard.web.server:app", host="127.0.0.1", port=args.port, reload=False)


if __name__ == "__main__":
    main()
