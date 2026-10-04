"""Use the tested live-camera panel without modifying KlipperScreen's checkout."""
import hashlib
import importlib.util
import os
from pathlib import Path
import runpy
import sys

CAMERA_SHA256 = "6e6484906315e877600c81375fd2a665cbf5e8946a5651bc66b9b556fccbeea2"


def main():
    root = Path(os.environ.get("KLIPPERSCREEN_DIR", "/home/printer/KlipperScreen"))
    sys.path.insert(0, str(root))
    original = root / "panels/camera.py"
    if hashlib.sha256(original.read_bytes()).hexdigest() == CAMERA_SHA256:
        path = Path(__file__).with_name("weston-camera.py")
        spec = importlib.util.spec_from_file_location("panels.camera", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        sys.modules["panels.camera"] = module
    else:
        print("Rebuild: upstream camera panel changed; using stock camera until "
              "the live-preview override is reviewed", file=sys.stderr, flush=True)
    script = str(root / "screen.py")
    sys.argv[0] = script
    runpy.run_path(script, run_name="__main__")


if __name__ == "__main__":
    main()
