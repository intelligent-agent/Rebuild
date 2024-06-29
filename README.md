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
We test software versions Fluidd, Mainsail and OctoPrint.
We test hardware versions Recore A5, A6, A7, A8

### Fluidd on Recore A8
- [x] Wifi comes up as an AP
- [x] Webcam shows a picture
- [x] USB host/device works as expected
- [x] Default Klipper config does not have any errors
- [x] All systemd services are running as they should
- [x] Software updates look functional
