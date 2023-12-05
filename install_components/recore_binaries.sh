#!/bin/bash

install_bins(){
    cp /tmp/overlay/bins/* /usr/local/bin
    chmod +x /usr/local/bin/*
}