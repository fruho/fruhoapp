#!/bin/sh
if [ `uname -m` = x86_64 ]; then
    ./base-tcl-x86_64 bootstrap.tcl "$@"
elif [ `uname -m` = armv7l ]; then
    ./base-tcl-armv7l bootstrap.tcl "$@"
else
    ./base-tcl-ix86 bootstrap.tcl "$@"
fi


