# Rebuild

Rebuild is a complete linux image for running on Recore 3D printer control boards.
Rebuild is based on Armbians Build system and is a thin layer of scripts to crate different 
Armbian images for Recore. 
* Rebuild-barebone - No top level applications installed, just a plain Armbian. 
* Rebuild-Mainsail - Comes with Klipper, Moonraker and Mainsail
* Rebuild-Fluidd - Comes with Klipper, Moonraker and Fluidd
* Rebuild-OctoPrint - Comes with Klipper and OctoPrint

To build a barebone version:
`./rebuild barebone`

