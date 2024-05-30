# Rebuild

Rebuild is a complete linux image for running on Recore 3D printer control boards.
Rebuild is based on Armbians Build system and is a thin layer of scripts to crate different 
Armbian images for Recore. 
* Rebuild-barebone - No top level applications installed, just a plain Armbian. 
* Rebuild-Mainsail - Comes with Klipper, Moonraker and Mainsail
* Rebuild-Fluidd - Comes with Klipper, Moonraker and Fluidd
* Rebuild-OctoPrint - Comes with Klipper and OctoPrint

To build a version, run the script in this folder:
`./rebuild <barebone|fluidd|mainsail|octoprint>`

## Manual tests to run before a release
* Test Recore hardware revisions A6, A7, A8
* Test Fluidd, Mainsail, OctoPrint
* Check that Wifi comes up as an AP
* Check that Webcam works as expected
* Check that USB host/device works as expected
* Check that Klipper runs without config errors
* Check that there all systemd services are running as they should
