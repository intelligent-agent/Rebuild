#!/bin/bash

add_overlays(){
    mkdir /boot/overlay-user
    cp /tmp/overlay/dts/* /boot/overlay-user
}