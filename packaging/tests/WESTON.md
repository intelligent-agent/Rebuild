# Native Weston KlipperScreen image trial

Branch `test/klipperscreen-weston` starts from main and changes only the
KlipperScreen revision, graphical backend and compositor configuration.
It retains main's kernel, SimpleDRM, GPU clock and stock camera implementation.
No Reflash changes, mpv dependency pruning or camera fps/cache patches are included.

KlipperScreen is pinned to `f2eb6919c0fcbcd4bab91ba59a5708415963d2ac`
(`v0.4.7-196-gf2eb6919`), the clean checkout tested on Voron. Unlike v0.4.7,
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
This branch does not claim to fix the camera bug. Separate diagnostic 15 fps
caps with caching disabled kept memory and queues stable while retaining the
general rotate filter, including a genuine 37-degree angle. These settings have
not been installed into the camera panel and are intentionally absent here.

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
