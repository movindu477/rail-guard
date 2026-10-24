"""Temporal persistence: an on-track object must be seen in several frames
before it can raise an alert. Single-frame false detections (a pipe read as a
cow, a parked bus whose box edge touches the corridor) never do.

Standard track bookkeeping (as in SORT):
  hits               frames the track has been matched in; never resets
  time_since_update  frames since it was last matched
  confirmed          hits >= min_hits
  deleted            time_since_update > max_age
so a detector that flickers (seen at frames 1, 3, 5) still confirms the object
instead of restarting its count on every miss.

Tracks are matched by box overlap only, not by class, so an object whose
class flickers between frames (e.g. a three-wheeler read as car, then
motorcycle) keeps its track.
"""


def box_iou(a, b):
    """IoU of two (x1, y1, x2, y2) boxes."""
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


class _Track:
    __slots__ = ("box", "hits", "time_since_update")

    def __init__(self, box):
        self.box, self.hits, self.time_since_update = box, 1, 0


class PersistenceTracker:
    """Counts how many frames each on-track object has been seen in."""

    def __init__(self, min_iou=0.3, max_age=5):
        self.min_iou = min_iou
        self.max_age = max_age
        self._tracks = []

    def update(self, boxes):
        """boxes: on-track (x1, y1, x2, y2) boxes in this frame.
        Returns each box's hit count (frames seen, including this one), in the
        same order. A box continues the best-overlapping live track (greedy,
        highest IoU first, against the track's last matched box); unmatched
        boxes start new tracks at 1. Tracks unmatched for more than max_age
        frames are deleted."""
        pairs = sorted(((box_iou(b, t.box), i, j)
                        for i, b in enumerate(boxes) for j, t in enumerate(self._tracks)),
                       reverse=True)
        matched = {}   # box index -> track
        used_t = set()
        for iou, i, j in pairs:
            if iou < self.min_iou:
                break
            if i in matched or j in used_t:
                continue
            matched[i] = self._tracks[j]
            used_t.add(j)

        for j, t in enumerate(self._tracks):
            if j not in used_t:
                t.time_since_update += 1
        hits = []
        for i, b in enumerate(boxes):
            t = matched.get(i)
            if t is None:
                t = _Track(b)
                self._tracks.append(t)
            else:
                t.box, t.hits, t.time_since_update = b, t.hits + 1, 0
            hits.append(t.hits)
        self._tracks = [t for t in self._tracks if t.time_since_update <= self.max_age]
        return hits

    def reset(self):
        self._tracks = []
