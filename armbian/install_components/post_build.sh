#!/bin/bash

post_build() {
    # Force debian to change password
    chage -d 0 debian
}