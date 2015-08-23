#!/bin/sh
if [ `uname -p` = x86_64 ]; then
    ./base-tcl-x86_64 bootstrap.tcl "$@"
else
    ./base-tcl-ix86 bootstrap.tcl "$@"
fi


