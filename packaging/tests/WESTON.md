# Native Weston KlipperScreen image trial

Branch `test/klipperscreen-weston` starts from main and changes only the
KlipperScreen revision, graphical backend and compositor configuration.
It retains main's kernel, SimpleDRM and GPU clock. It now combines native Weston
with the tested live-camera fix and runtime-only mpv dependencies (#110).
No Reflash changes are included.

KlipperScreen is pinned to `973c95dd4d8a5c98b77cd94c48dde667048d43e9`
(`v0.4.7-195-g973c95dd`), the immediate parent of tested `f2eb6919`. This
deliberately lets the full CI software-upgrade step perform a real Git update
to `f2eb6919`, not just report an already-current checkout. Unlike v0.4.7,
this revision supports Weston through the upstream installer with `BACKEND=W
COMPOSITOR=weston` and the unmodified upstream launcher. `START=0` avoids starting
the graphical session while constructing the image; the installed service is
enabled by the upstream installer. GTK is explicitly native Wayland; seatd is
used for local DRM/input access. No separate Weston service is installed.

Configuration lives at `/etc/xdg/weston/weston.ini`, the standard path used by
Reflash's existing WESTON rotation step. Both HDMI-A-1 and Unknown-1 use their
preferred mode. No fixed resolution or rotation is imposed on other rigs.
For the current Voron screen, set its matching output's transform to `rotate-90`
before testing after flashing. Reflash's Fluidd rotation integration is deferred.
There is no user-level weston.ini in a fresh image to shadow the global file.

## Existing on-board evidence, not fresh-image validation

Voron was switched to native Weston DRM/kiosk shell with Mali400 GL acceleration,
using the separate sun4i test kernel. User confirmed responsive UI and working
touch. Logical resolution was 1920x1080 on the rotated native 1080x1920 panel.
Klipper and Moonraker stayed active; no Xorg or Xwayland process remained.

Bounded fullscreen stock-style mpv playback improved from approximately 8 fps
under rotated X11 to approximately 21 fps under Weston, still below the 24 fps
MJPEG source. The packet backlog and default rewind cache therefore still grow.
The fresh Weston image was subsequently tested on Voron. Its stock camera still
played in slow motion. A live panel change capped frames at 15 fps before
rotation, disabled cache and rewind history, and used transpose/flips for exact
quarter turns while retaining general rotate for arbitrary angles. The user
reported snappy playback. During the first 50 seconds, forward/history buffers
were zero and RSS increased only about 0.6 MiB; longer stability is not proven.

This branch now includes those settings in a packaged camera override, selected
through upstream's KS_XCLIENT hook. The checkout remains unchanged. A checksum
guard rejects mismatched source during image construction; if a later upstream
update changes the camera panel, the launcher warns and falls back to stock.
Review/remove the override when an upstream camera fix becomes available.
Temporary on-board telemetry threads are not shipped.

The upstream installer runs from a temporary adjacent copy with only libmpv-dev
replaced by libmpv2. CJK fonts are still removed as before. The original installer
is unchanged, and the temporary copy is deleted. Re-test image size and runtime
loading; earlier pruning measurements are not a controlled Weston comparison.

The initial image failed both real-upgrade and dependency-refresh restart tests:
PAM moved Weston into a separate session scope, outside the service cgroup.
The stock launcher execs the application and loses its EXIT cleanup trap.

Rebuild now clears PAMName and explicitly retains KillMode=control-group in a
generated drop-in. It derives printer's UID for the standard user-runtime-dir
unit and enables printer lingering, so logind does not remove that directory
when the last login session ends. The drop-in alone was insufficient: without
linger the runtime directory stopped and pulled down the display service.
No upstream launcher or service source is modified.

On Voron the combined fix passed five normal service restarts, the actual
973c95dd-to-f2eb6919 Moonraker upgrade, and recovery with update_deps=true.
Every previous Weston PID disappeared; one replacement remained in
/system.slice/KlipperScreen.service, and the camera launcher reinitialized.
libmpv2 remained installed, libmpv-dev remained absent, and native mpv loaded.
The user confirmed the screen/camera looked good. Klipper stayed running.
Fresh-image boot and CI validation of this packaged setup are still pending.

The session configurator ships in rebuild-printer and is called by the image
installer and by package configuration on existing native-Weston installations.
It does not restart the screen from a maintainer script or convert X11 systems.

## Fresh-image checks still required

- Main uses SimpleDRM; the on-board Weston trial used sun4i-drm. Verify compositor
  startup on this image independently and record the actual renderer (Mali400
  versus software fallback). Do not assume the on-board performance carries over.
- Verify preferred resolution, rotation and touch on each panel size; no universal
  1080x1920 assumption, particularly for A7.
- Confirm native Wayland, no competing compositor, printer ready and camera
  open/close behavior. Keep arbitrary camera rotation supported.
- Test KlipperScreen restart, cold/warm boots, blanking/wake and HDMI reseating.
  Wayland display-power behavior differs from X11 DPMS.
- Verify an upstream KlipperScreen update does not replace the backend choice or
  invalidate the compositor configuration. Keep stock launcher/installer flow.

References: [KlipperScreen backends](https://klipperscreen.readthedocs.io/en/latest/Backends/),
[Weston configuration](https://manpages.debian.org/trixie/weston/weston.ini.5.en.html).
