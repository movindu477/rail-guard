"""YOLO hazard detector loading."""

from ultralytics import YOLO


def load_yolo(weights):
    """Load a YOLO detector from a weights file."""
    return YOLO(weights)
