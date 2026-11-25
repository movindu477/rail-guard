"""Drawing a RailGuard FrameResult onto a frame.
Moved to railguard.ui.overlay so the desktop app and the CLI demos share one
implementation without drift.
"""
from railguard.ui.overlay import (  # noqa: F401
    BANNER,
    CORRIDOR,
    CORRIDOR_BAD,
    FONT,
    OFF_TRACK,
    ON_TRACK,
    UNKNOWN,
    draw,
    draw_stale,
    put_label,
)
