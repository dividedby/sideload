#!/bin/sh
# Ignores SIGTERM and outlives its closed pipes (yes exits on EPIPE), so only SIGKILL stops it.
trap '' TERM PIPE; /usr/bin/yes; while :; do /bin/sleep 0.1; done
