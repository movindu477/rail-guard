# rail-guard

## Setup

```
python -m venv venv
venv\Scripts\pip install -e .
git submodule update --init
```

`pip install -e .` makes `import railguard` work from any folder. TEP-Net weights are not in git; see `third_party/README.md`.
