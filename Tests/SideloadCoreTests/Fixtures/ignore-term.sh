#!/bin/sh
trap '' TERM; : > "$1"; while :; do /bin/sleep 0.1; done
