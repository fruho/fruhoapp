#!/bin/sh
LOGFILE=/var/log/fruhod.log
touch $LOGFILE >> /dev/null 2>&1
OUT=$?
if [ "$OUT" -ne "0" ]; then
    echo "You need to be root. Try with sudo."
    exit 1
fi


if [ `uname -m` = x86_64 ]; then
    arch="x86_64"
elif [ `uname -m` = armv7l ]; then
    arch="armv7l"
else
    arch="ix86"
fi

. ./fruhod/exclude/fruhod.preinst

cp -r fruhod/exclude/etc/* /etc/
cp -r fruho/exclude/usr/* /usr/

mkdir -p /usr/local/sbin
cp build/fruhod/linux-$arch/fruhod.bin /usr/local/sbin/
mkdir -p /usr/local/bin
cp build/fruho/linux-$arch/fruho.bin /usr/local/bin/
cp fruho/exclude/fruho /usr/local/bin/

. ./fruhod/exclude/fruhod.postinst
