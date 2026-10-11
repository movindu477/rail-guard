"""Hazard classes RailGuard detects, and their indices in a given model."""

# Filter by name, not index: COCO and the fine-tuned model number these differently.
ALLOWED_NAMES = {"person", "car", "motorcycle", "bus", "truck", "cow", "elephant"}


def class_ids(model, names=ALLOWED_NAMES):
    """Indices in this model's own class list for the given class names."""
    ids = [i for i, n in model.names.items() if n in names]
    missing = set(names) - {model.names[i] for i in ids}
    if missing:
        print(f"WARNING: model has no class(es) {sorted(missing)}")
    return ids
