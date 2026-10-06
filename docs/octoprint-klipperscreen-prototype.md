# OctoPrint + Moonraker + KlipperScreen prototype (#126)

This branch replaces Toggle only in the OctoPrint image. It uses the same
Moonraker, native Weston/KlipperScreen, runtime-only mpv, and camera playback
setup as Fluidd/Mainsail. OctoPrint and its existing plugins remain installed.
The kernel, device trees, simpledrm, GPU clock, and build cache options are
unchanged. There is no separate Klipper instance and no status bridge plugin.

## Connections

- OctoPrint: serial `/tmp/printer`, web port 80 redirected to 5000 as before.
- Moonraker: `/tmp/klippy_uds`, HTTP/WebSocket port 7125.
- KlipperScreen: local Moonraker on port 7125, native Weston.
- Files: both use `/home/printer/printer_data/gcodes`.
- Camera: existing ustreamer on port 8080. Moonraker's camera URL is loopback
  for KlipperScreen; OctoPrint retains its browser-facing webcam configuration.

Moonraker trusts loopback only in this prototype. Remote diagnostic requests
need authentication or must run over SSH on the board. OctoPrint still uses
its normal wizard/account setup; the former Toggle autologin is disabled.

## Provisioning Voron

The image installs `printer_data/config/octoprint-moonraker.cfg` and includes
it in its initially empty `printer.cfg`. Reflash/CI provisioning replaces
`printer.cfg`, so **check the final provisioned config** and add:

```ini
[include octoprint-moonraker.cfg]
```

Do not duplicate an existing `virtual_sdcard`, `pause_resume`, `display_status`,
`rebuild_firmware`, or `CANCEL_PRINT` definition. Merge the required settings
into existing definitions instead where necessary. Restart Klipper only while
idle. Keep the existing Voron motor/heater configuration, shutdown macro, and
Weston rotation. Confirm the actual Weston output transform after provisioning;
the shared image does not hard-code Voron's orientation.

## What is not solved yet

An OctoPrint **serial-streamed** job is not a Klipper virtual-SD job. Sharing
the upload directory does not synchronize `print_stats`, job ownership,
progress, or pause/cancel actions. Do not assume the touchscreen controls an
OctoPrint streamed job correctly. OctoPrint plugins may also expect streamed
jobs. Do not start two jobs independently from the two frontends.

The experiment compares normal streaming with Klipper virtual-SD playback
(for example `SDCARD_PRINT_FILE FILENAME=prototype-status.gcode`). We have not
enabled OctoPrint's SD upload path: Klipper's virtual SD is read-only and
already sees files in the shared local directory.

## Validation after the image is ready

1. Flash/provision only after agreeing to replace the current Voron image.
2. Check `klipper`, `octoprint`, `moonraker`, and `KlipperScreen` are active,
   only one Klipper process exists, and Klipper reports ready.
3. Confirm screen rotation, touch, responsiveness, camera latency, and memory.
4. Use a timed G-code file containing only `G4 P1000` waits and progress
   markers, with no heaters or motion. Compare streaming versus virtual SD.
5. Check both frontends' start, progress, pause/resume, cancel, completion,
   and error behavior. Record gaps instead of treating connectivity as success.
6. Check software upgrades, reboot, and the existing graceful shutdown hook.
7. Compare compressed image size, eMMC usage, memory, and CPU to Toggle.

Build with the usual Recore-CI **Rebuild / octoprint** action using branch
`test/octoprint-moonraker-klipperscreen`. Do not flash automatically.
