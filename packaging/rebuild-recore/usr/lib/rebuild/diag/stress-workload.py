#!/usr/bin/env python3
"""Board-side bounded CPU/GPU/memtester workload; run in a systemd cgroup.

No clock, voltage, governor, display-mode or service changes. Only diagnostic
package installation (explicitly enabled by the UI) and selected loads.
"""
import argparse
import base64
import glob
import json
import os
import pwd
import re
import signal
import subprocess
import threading
import time
import urllib.request
from pathlib import Path


def emit(kind, data):
    print(kind + " " + json.dumps(data, separators=(",", ":")), flush=True)


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def temperatures():
    out = {}
    for zone in sorted(glob.glob("/sys/class/thermal/thermal_zone*")):
        raw = read(zone + "/temp")
        if raw is not None:
            try:
                out[(read(zone + "/type") or Path(zone).name)] = round(int(raw) / 1000, 3)
            except ValueError:
                pass
    return out


def gpu_rate():
    rate = read("/sys/kernel/debug/clk/gpu/clk_rate")
    if rate:
        return int(rate)
    for path in glob.glob("/sys/class/devfreq/*gpu*/cur_freq"):
        rate = read(path)
        if rate:
            return int(rate)
    return None


def printer_idle():
    # Refuse a running print, including OctoPrint images without Moonraker.
    try:
        with urllib.request.urlopen("http://127.0.0.1:7125/printer/objects/query?print_stats", timeout=5) as response:
            state = json.load(response)["result"]["status"]["print_stats"]["state"]
        if state not in ("standby", "complete", "cancelled"):
            raise RuntimeError("printer is not idle: " + state)
        return "moonraker:" + state
    except (OSError, KeyError, ValueError):
        token = None
        for path in ("/home/printer/.octoprint/config.yaml", "/home/printer/OctoPrint/config.yaml"):
            content = read(path) or ""
            match = re.search(r"(?m)^api:\s*\n(?:[ \t]+[^\n]*\n)*?[ \t]+key:\s*['\"]?([a-zA-Z0-9]+)", content)
            if match:
                token = match.group(1)
                break
        if not token:
            raise RuntimeError("cannot confirm printer idle (Moonraker/OctoPrint)")
        request = urllib.request.Request("http://127.0.0.1:5000/api/job", headers={"X-Api-Key": token})
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                state = json.load(response)["state"]
        except (OSError, KeyError, ValueError) as exc:
            raise RuntimeError("cannot confirm OctoPrint idle") from exc
        if state not in ("Operational", "Offline"):
            raise RuntimeError("OctoPrint is not idle: " + state)
        return "octoprint:" + state


def display_session():
    """Use the compositor process's user/environment, never assume a socket."""
    found = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        comm = read(entry / "comm")
        if comm not in ("weston", "Xorg"):
            continue
        uid = entry.stat().st_uid
        env = dict(item.split("=", 1) for item in
                   (entry / "environ").read_bytes().decode(errors="replace").split("\0") if "=" in item)
        user = pwd.getpwuid(uid).pw_name
        if comm == "weston":
            runtime = env.get("XDG_RUNTIME_DIR")
            sockets = sorted(p for p in Path(runtime or "/nonexistent").glob("wayland-*")
                             if p.is_socket())
            if not sockets:
                continue
            socket = env.get("WAYLAND_DISPLAY") or sockets[0].name
            if not (Path(runtime) / socket).is_socket():
                continue
            found.append(("weston", user, {"XDG_RUNTIME_DIR": runtime, "WAYLAND_DISPLAY": socket},
                          "glmark2-es2-wayland", "glmark2-es2-wayland"))
        else:
            args = (entry / "cmdline").read_bytes().decode(errors="replace").split("\0")
            display = next((a for a in args if re.fullmatch(r":\d+(?:\.\d+)?", a)), None)
            if not display:
                continue
            auth = env.get("XAUTHORITY")
            if "-auth" in args:
                auth = args[args.index("-auth") + 1]
            # Xorg may run as root; the desktop/GTK session runs as printer.
            user = "printer" if uid == 0 else user
            pwd.getpwnam(user)
            settings = {"DISPLAY": display}
            if auth:
                settings["XAUTHORITY"] = auth
            found.append(("xorg", user, settings, "glmark2-es2", "glmark2-es2-x11"))
    if len(found) != 1:
        raise RuntimeError("need exactly one active Xorg or Weston session for GPU load")
    return found[0]


def ensure_packages(packages, allow):
    missing = [pkg for binary, pkg in packages if not subprocess.run(
        ["sh", "-c", 'command -v "$1" >/dev/null', "sh", binary], check=False).returncode == 0]
    if missing:
        if not allow:
            raise RuntimeError("missing diagnostic packages: " + ", ".join(missing))
        print("SETUP installing diagnostic packages (changes installed packages): " + ", ".join(missing), flush=True)
        subprocess.run(["apt-get", "install", "-y", "--no-install-recommends", *missing], check=True, timeout=120)


class Workloads:
    def __init__(self):
        self.procs = {}
        self.threads = []
        self.failures = 0
        self.loops = 0
        self.renderer = None
        self.fps = None
        self.memory_locked = False
        self.cancelled = False
        self.lock = threading.Lock()

    def line(self, name, line):
        line = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", line).strip()
        # Interpret memtester's in-place counters before matching final results.
        visible = []
        for char in line:
            if char == "\b":
                if visible:
                    visible.pop()
            elif char == "\r":
                visible.clear()
            else:
                visible.append(char)
        line = "".join(visible).strip()
        if "FAILURE:" in line:
            self.failures += 1
        if name == "memory" and "trying mlock" in line and "locked." in line:
            self.memory_locked = True
        loop = re.match(r"Loop (\d+)(?:/\d+)?:", line) if name == "memory" else None
        if loop:
            # Starting another pass also proves completion of the previous
            # pass, including one whose final pattern reported mismatches.
            self.loops = max(self.loops, int(loop.group(1)) - 1)
        if name == "memory" and re.search(r"16-bit Writes\s*:\s*ok", line):
            self.loops += 1
        if name == "gpu":
            renderer = re.search(r"GL_RENDERER:\s*(.*)", line)
            if renderer:
                self.renderer = renderer.group(1)
            fps = re.search(r"FPS:\s*([0-9.]+)", line)
            if fps:
                self.fps = float(fps.group(1))
        if any(s in line for s in ("FAILURE", ": ok", "Loop ", "locked", "Done.",
                                    "GL_RENDERER", "FPS:", "stress-ng:", "Error:", "Unsupported")):
            print("LOAD " + name + " " + line[-4000:], flush=True)

    def start(self, name, argv, env=None):
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                env=env, start_new_session=True)
        self.procs[name] = proc
        def consume():
            # memtester redraws counters with carriage returns/backspaces.
            buffer = b""
            while True:
                chunk = os.read(proc.stdout.fileno(), 4096)
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    with self.lock:
                        self.line(name, line.decode(errors="replace"))
                if len(buffer) > 65536:
                    buffer = buffer[-8192:]
            if buffer:
                with self.lock:
                    self.line(name, buffer.decode(errors="replace"))
        thread = threading.Thread(target=consume, daemon=True)
        thread.start()
        self.threads.append(thread)

    def stop(self):
        for proc in self.procs.values():
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        until = time.monotonic() + 5
        for proc in self.procs.values():
            try:
                proc.wait(timeout=max(.1, until - time.monotonic()))
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()
        for thread in self.threads:
            thread.join(timeout=2)


def run(config):
    loads = Workloads()
    started = None
    peak = {}
    memory_warning = False
    result = {"status": "error", "reason": "setup incomplete", "config": config}
    def cancel(signum, frame):
        loads.cancelled = True
        raise InterruptedError("cancelled")
    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    try:
        idle = printer_idle()
        for comm in ("memtester", "stress-ng", "glmark2-es2", "glmark2-es2-wayland"[:15]):
            if subprocess.run(["pgrep", "-x", comm], stdout=subprocess.DEVNULL).returncode == 0:
                raise RuntimeError("existing stress workload detected: " + comm)
        packages = []
        session = display_session() if config["gpu"] else None
        if session:
            packages.append((session[3], session[4]))
        if config["cpu"]:
            packages.append(("stress-ng", "stress-ng"))
            if config["cpu_workers"] > (os.cpu_count() or 1):
                raise RuntimeError("CPU workers exceed this board's CPU count")
        if config["memory"]:
            packages.append(("memtester", "memtester"))
        temps = temperatures()
        if not temps:
            raise RuntimeError("no readable temperature sensor; thermal safeguard unavailable")
        if max(temps.values()) >= config["thermal_limit_c"]:
            raise RuntimeError("board already exceeds thermal limit")
        ensure_packages(packages, config["install_tools"])
        # Package setup can take time: recheck before starting any load.
        printer_idle()
        emit("SETTINGS", {"kernel": os.uname().release, "model": read("/proc/device-tree/model"),
                          "idle": idle, "session": session[0] if session else None,
                          "gpu_hz": gpu_rate(), "config": config,
                          "thermal_sensors": list(temps), "memory_mode": "continuous"})
        duration = config["duration_seconds"]
        if session:
            backend, user, settings, binary, package = session
            args = [binary, "--run-forever"]
            args.append("--fullscreen" if config["gpu_mode"] == "onscreen" else "--off-screen")
            loads.start("gpu", ["runuser", "-u", user, "--", "env",
                                *[k + "=" + v for k, v in settings.items()], *args])
            deadline = time.monotonic() + 15
            while not loads.renderer and time.monotonic() < deadline:
                if loads.procs["gpu"].poll() is not None:
                    break
                time.sleep(.2)
            if not loads.renderer or "Mali" not in loads.renderer:
                raise RuntimeError("GPU load did not start with a Mali hardware renderer")
        if config["memory"]:
            info = read("/proc/meminfo") or ""
            avail = re.search(r"MemAvailable:\s*(\d+)", info)
            if not avail or config["memory_mb"] > int(avail.group(1)) // 1024 - 128:
                raise RuntimeError("memory allocation must leave at least 128 MiB available")
            # Zero means repeat indefinitely. The supervisor owns the deadline
            # and kills the group; memory_loops is the minimum coverage target.
            loads.start("memory", ["memtester", str(config["memory_mb"]) + "M", "0"])
        if config["cpu"]:
            loads.start("cpu", ["stress-ng", "--cpu", str(config["cpu_workers"]), "--verify",
                                "--timeout", str(duration) + "s", "--metrics-brief"])
        started = time.monotonic()
        result = {"status": "passed", "reason": "duration complete", "config": config}
        while True:
            elapsed = time.monotonic() - started
            temps = temperatures()
            for name, value in temps.items():
                peak[name] = max(peak.get(name, value), value)
            emit("TELEMETRY", {"elapsed_seconds": round(elapsed, 1),
                              "remaining_seconds": max(0, round(duration - elapsed, 1)),
                              "temperatures_c": temps, "gpu_hz": gpu_rate(),
                              "cpu_khz": read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"),
                              "gpu_fps": loads.fps, "memory_loops_completed": loads.loops,
                              "memory_failures": loads.failures,
                              "loads": {n: "running" if p.poll() is None else "finished" for n, p in loads.procs.items()}})
            if not temps or max(temps.values()) >= config["thermal_limit_c"]:
                result.update(status="thermal-stop", reason="temperature limit reached or sensor disappeared")
                break
            if loads.failures and not memory_warning:
                print("WARNING memory mismatches detected; continuing selected loads to the deadline. Final result will not pass.", flush=True)
                memory_warning = True
            for name, proc in loads.procs.items():
                code = proc.poll()
                if code is None:
                    continue
                if name == "gpu" or (name == "cpu" and (code != 0 or elapsed < duration - 3)):
                    raise RuntimeError(name + " workload stopped early/failed, exit=" + str(code))
                if name == "memory":
                    raise RuntimeError("continuous memtester stopped unexpectedly, exit=" + str(code))
            if elapsed >= duration:
                break
            time.sleep(min(config["sample_seconds"], duration - elapsed))
    except InterruptedError:
        result.update(status="cancelled", reason="operator cancellation")
    except Exception as exc:
        result.update(status="error", reason=str(exc))
    finally:
        # Do not allow a second signal to interrupt group cleanup.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        if result["status"] == "passed" and config["cpu"]:
            # stress-ng's timeout and our sample deadline can differ slightly.
            # Give verified CPU workers time to finish, rather than counting a
            # forcefully terminated worker as a clean verification pass.
            try:
                code = loads.procs["cpu"].wait(timeout=3)
                if code != 0:
                    result.update(status="failed", reason="CPU verification failed")
            except subprocess.TimeoutExpired:
                result.update(status="incomplete", reason="CPU verification did not finish")
        loads.stop()
        if loads.failures and result["status"] in ("passed", "incomplete"):
            result.update(status="failed", reason="memory pattern mismatches")
        elif result["status"] == "passed" and config["memory"] and (
                loads.loops < config["memory_loops"] or not loads.memory_locked):
            result.update(status="incomplete", reason="duration ended before requested locked-memory passes completed")
        result.update(elapsed_seconds=round(time.monotonic() - started, 1) if started is not None else 0,
                      memory_mode="continuous", memory_stopped_at_deadline=config["memory"] and started is not None and time.monotonic() - started >= config["duration_seconds"],
                      peak_temperatures_c=peak, memory_failures=loads.failures,
                      memory_loops_completed=loads.loops, renderer=loads.renderer,
                      exit_codes={n: p.returncode for n, p in loads.procs.items()})
        emit("RESULT", result)
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    raise SystemExit(run(json.loads(base64.b64decode(args.config))))
