#!/bin/sh
/bin/sleep 30 & echo $! > "$1"; wait
