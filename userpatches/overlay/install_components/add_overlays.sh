#!/bin/bash

add_overlays(){
    mkdir -p /boot/overlay-user
    cp /tmp/overlay/dts/* /boot/overlay-user
}