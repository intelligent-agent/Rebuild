# Controlled Klipper service stop (#119)

The image-generated `klipper.service` invokes the packaged `klipper-stop`
helper before terminating the host. The helper uses Klipper's local API
socket directly (no Moonraker dependency) to turn off heaters, disable
motors and wait for queued moves. It verifies heater targets/power and
logical stepper states, and reads CHOPCONF.TOFF for supported TMC virtual
enables. Dedicated-enable GPIO states are not read back by the helper.

The helper has an eight-second overall deadline. It logs and exits nonzero
when cleanup cannot be confirmed; systemd still proceeds to stop the host.
It refuses overridden cleanup commands rather than invoking arbitrary
user macros. It covers service stops/restarts and orderly OS shutdown,
not a crashed host, lost MCU connection or sudden power loss.

Fans and LEDs are deliberately unchanged. NeoPixels need an explicit
all-black update while MCU communication remains available; their initial
color is not a shutdown color. Power indicators may not be controllable.
LED shutdown policy is separate work, particularly for active templates
or third-party LED effects that can overwrite a manual color.

The service file is generated during image creation. This prototype does
not migrate existing installations via package upgrade. A8 and Voron have
been updated manually for testing, with their original service retained as
`/etc/systemd/system/klipper.service.before-119-execstop`.

## Verification (2026-10-05)

- Six Python tests passed: virtual-driver register retry, macro rejection,
  dedicated-enable exclusion, unsupported-driver rejection, absent socket
  failure and service hook presence.
- A8 bench (0482): three service stop/start cycles passed; cleanup 0.38–0.40 s.
- Voron (0484): one service stop/start passed; cleanup 0.40 s. All six
  virtual-enable axis drivers read back TOFF=0; Klipper returned ready.
- User manually homed Voron to enable motors, then shut down the OS and
  confirmed the motors released. This verifies energized-motor release.
- No heating, motion or motor-enable commands were sent by automated tests.
- LED shutdown, active-heater shutdown and stalled-socket timeout have not
  been hardware-tested. The missing-socket case is covered by a unit test.

Run local tests with:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s packaging/tests -p 'test_klipper_stop.py' -v
```
