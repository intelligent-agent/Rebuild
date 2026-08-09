#!/bin/bash

install_plymouth() {
    echo "🍰 install Plymouth"
    apt install -y plymouth plymouth-themes

    # Use Recore's own watermark as the spinner theme's logo. The
    # theme's default WatermarkVerticalAlignment (.96) puts it right
    # near the bottom of the screen - center it instead.
    cp /tmp/overlay/plymouth/watermark.png /usr/share/plymouth/themes/spinner/watermark.png
    sed -i 's/^WatermarkVerticalAlignment=.*/WatermarkVerticalAlignment=.5/' /usr/share/plymouth/themes/spinner/spinner.plymouth

    plymouth-set-default-theme -R spinner
}
