# Running RailGuard

## One command

```
npm run dev
```

Starts the Python backend and the web UI together and stops both when either
one exits (`--kill-others`), so a crashed backend does not leave a page that
looks alive and is showing nothing.

| | |
|---|---|
| Backend | http://127.0.0.1:8000 |
| Web UI | http://127.0.0.1:5173 |

First time only:

```
npm run setup
```

## Only one program may hold the camera

`demos/live_app.py` (the PyQt desktop app), `demos/live_demo.py` and the web
backend all open camera index 1. Windows gives it to one process at a time;
the others fail with

```
VIDEOIO(DSHOW): backend is generally available but can't be used to capture by index
```

which reads like a driver fault and is not. **Close the other one first.**

## "Port is already in use"

A previous run is still holding the port. List what is holding them:

```powershell
netstat -ano | findstr ":8000 :5173"
```

The last column is the process id. Stop it:

```powershell
Stop-Process -Id <id> -Force
```

Or stop every stray Python and Node at once:

```powershell
Get-Process python, node -ErrorAction SilentlyContinue | Stop-Process -Force
```

That also kills anything else of yours running in Python or Node, so check
first if something else matters.

## Why two processes and not one

The pipeline needs CUDA and a USB camera, so it runs on this machine as a
Python process. The page is served by Vite in development so that editing a
component reloads the browser without restarting the pipeline - which takes
several seconds to load its models.

For a single-process build, `npm run build` writes `web/dist` and the backend
can serve it statically. That is worth doing once the UI stops changing.
