#!/bin/sh
/bin/sleep 60 & echo "$$ $!" > "$SIDELOAD_TEST_MARKER"; wait
