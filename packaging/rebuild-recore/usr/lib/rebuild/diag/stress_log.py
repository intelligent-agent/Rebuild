"""Readable run-log presentation; structured telemetry remains separate."""
def duration(value):
    seconds = max(0, int(round(value or 0)))
    return f"{seconds // 60:02d}:{seconds % 60:02d}"


def temperatures(values):
    return " | ".join(f"{name}: {value:.1f} C" for name, value in values.items()) or "unavailable"


def clock(value, scale):
    try:
        return f"{float(value) / scale:g} MHz"
    except (TypeError, ValueError):
        return "unavailable"


def format_record(kind, record):
    cfg = record.get("config", {})
    if kind == "SETTINGS":
        selected = []
        if cfg.get("cpu"):
            selected.append(f"CPU ({cfg['cpu_workers']} workers, verification on)")
        if cfg.get("gpu"):
            selected.append(f"GPU ({cfg['gpu_mode']})")
        if cfg.get("memory"):
            selected.append(f"Memory ({cfg['memory_mb']} MiB, continuous, minimum {cfg['memory_loops']} completed passes)")
        return (f"SETTINGS | {str(record.get('model', 'unknown board')).rstrip(chr(0))} | kernel {record.get('kernel', 'unknown')}\n"
                f"Loads: {', '.join(selected)}\n"
                f"Duration: {duration(cfg.get('duration_seconds'))} | sample every {cfg.get('sample_seconds')} s"
                f" | temperature cutoff: {cfg.get('thermal_limit_c')} C\n"
                f"Display: {record.get('session') or 'not used'} | GPU clock: {clock(record.get('gpu_hz'), 1000000)}"
                f" | printer: {record.get('idle', 'unknown')}")
    if kind == "TELEMETRY":
        fps = record.get("gpu_fps")
        return (f"[{duration(record.get('elapsed_seconds'))} elapsed / {duration(record.get('remaining_seconds'))} left] "
                f"{temperatures(record.get('temperatures_c', {}))}"
                f" | CPU {clock(record.get('cpu_khz'), 1000)} | GPU {clock(record.get('gpu_hz'), 1000000)}"
                f" | GPU FPS: {fps if fps is not None else 'unavailable'}"
                f" | memory passes: {record.get('memory_loops_completed', 0)}, errors: {record.get('memory_failures', 0)}"
                f" | loads: {', '.join(f'{name} {state}' for name, state in record.get('loads', {}).items())}")
    if kind == "RESULT":
        codes = record.get('exit_codes', {})
        return (f"RESULT: {record.get('status', 'unknown').upper()} — {record.get('reason', '')}\n"
                f"Elapsed: {duration(record.get('elapsed_seconds'))}"
                f" | memory passes: {record.get('memory_loops_completed', 'unavailable')}"
                f" | memory errors: {record.get('memory_failures', 'unavailable')}\n"
                f"Peak temperatures: {temperatures(record.get('peak_temperatures_c', {}))}\n"
                f"GPU renderer: {record.get('renderer') or 'unavailable'}"
                f" | exit codes: {', '.join(f'{name}={code}' for name, code in codes.items()) or 'unavailable'}"+
                ("\nMemory repeated until deadline; the interrupted final partial pass is not counted. Memory/GPU exit -15 is expected supervisor cleanup." if record.get('memory_stopped_at_deadline') else ""))
    raise ValueError("unknown stress record: " + kind)
