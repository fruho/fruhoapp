#
# fruhod/main.tcl
# fruhod should be as close to plain OpenVPN functionality as possible. keep only current openvpn config, don't save fruhod model, should be stateless across fruhod reboots
#
# This should be the preamble to every application
# It makes it possible to run as starpack or as a sourced script
if {![catch {package require starkit}]} {
  #this is to initialize starkit variables
  starkit::startup
}

# package vs source principle: sourced file may have back/circular references to the caller (to be avoided)
package require cmd
package require ovconf
# Tclx for signal trap
package require Tclx
# Tclx litters global namespace. Need to clean up to avoid conflict with csp
rename ::select ""
package require linuxdeps
# skutil must be last required package in order to overwrite the log proc from Tclx
# using skutil log to stdout
package require skutil

source [file join [file dir [info script]] model.tcl]
source [file join [file dir [info script]] omgmt.tcl]

proc background-error {msg e} {
    set pref [lindex [info level 0] 0]
    log $pref: $msg
    dict for {k v} $e {
        log $pref: $k: $v
    }
}

interp bgerror "" background-error

proc main {} {
    try {
        if {![unix has-root]} {
            puts stderr "You need to be root. Try again with sudo."
            exit 0
        }
        log Starting fruhod server with PID [pid]
        log fruhod build version: [build-version]
        log fruhod build date: [build-date]
        # intercept termination signals
        signal trap {SIGTERM SIGINT SIGQUIT} main-exit
        # ignore disconnecting terminal - it's supposed to be a daemon. This is causing problem - do not enable. Use linux nohup
        #signal ignore SIGHUP


        # when starting fix resolv.conf if needed
        #TODO restore only if not connected, so mgmt check for ovpn connection status first
        #TODO call it after delay
        dns-restore
        
        log [create-pidfile "/var/run/fruhod.pid"]


    
        #TODO check if openvpn installed, install otherwise, retry if needed
        #TODO check if X11 running, if so try Tk. If a problem install deps, retry if needed
        #TODO make it after a delay to allow previous dpkg terminate

        #linuxdeps openvpn-install
        #linuxdeps tkdeps-install
    
        model reset-ovpn-state
        # call after reseting model state
        MgmtConnectionMonitor
        MgmtStatusMonitor
        socket -server daemon-new-connection -myaddr 127.0.0.1 7777
        log Listening on 127.0.0.1:7777
        cyclic-daemon-model-report
        if {! $::model::ovpn_installing} {
            cyclic-linuxdeps-check
        }
    } on error {e1 e2} {
        log ERROR in main: $e1 $e2
    }
}


# TODO how it works on Windows? Also pidfile
proc main-exit {} {
    log Gracefully exiting fruhod
    #TODO wind up
    delete-pidfile /var/run/fruhod.pid
    exit 0
}

proc daemon-version-report {} {
    catch {ffwrite ctrl "version [build-version] [build-date]"}
}

proc daemon-model-report {} {
    ovpn-pid
    catch {ffwrite stat [model model2dict] 0}
} 

proc cyclic-daemon-model-report {} {
    # report interval in ms
    set interval 400

    # fix openvpn bug: when disconnecting underlying connection (tested with wi-fi) openvpn enters busy loop, consumes 100% CPU, and shows high rrwrite transfer on tun0
    # detect the incident = bug manifestation
    # mgmt_rread is constant and mgmt_rwrite is growing fast (at least 10MB/s)
    if {$::model::Prev_mgmt_rwrite > 0 && ($::model::mgmt_rwrite - $::model::Prev_mgmt_rwrite)/$interval > 10000 && $::model::Prev_mgmt_rread == $::model::mgmt_rread} {
        log "Detected OpenVPN bug: busy loop with high transfer on mgmt_rwrite. Killing OpenVPN."
        log "mgmt_rread: $::model::mgmt_rread" 
        log "mgmt_rwrite: $::model::mgmt_rwrite" 
        log "mgmt_vread: $::model::mgmt_vread" 
        log "mgmt_vwrite: $::model::mgmt_vwrite" 
        kill-ovpn-by-saved-pid
        OvpnExit 0
    }
    set ::model::Prev_mgmt_rwrite $::model::mgmt_rwrite
    set ::model::Prev_mgmt_rread $::model::mgmt_rread

    daemon-model-report
    after 400 cyclic-daemon-model-report
} 

proc cyclic-linuxdeps-check {} {
    # try 7 times every 5 seconds
    if {$::model::Linuxdeps_count < 7} {
        incr ::model::Linuxdeps_count
        log "cyclic-linuxdeps-check # $::model::Linuxdeps_count"
        if {![linuxdeps is-openvpn-installed]} {
            log "No OpenVPN installed"
            set ::model::ovpn_installing 1
            if {[catch {linuxdeps openvpn-install} out err]} {
                log $err
            }
            after 5000 cyclic-linuxdeps-check
        } else {
            set ::model::ovpn_installing 0
            log "OpenVPN OK"
        }
    } else {
        set ::model::ovpn_installing 0
    }
}



# On new connection to the daemon, close the previous one
proc daemon-new-connection {sock peerhost peerport} {
    model print 
    if {$::model::Ffconn_sock ne ""} {
        ffwrite ctrl "Closing connection to fruho client $::model::Ffconn_sock. Superseded by $sock $peerhost $peerport"
        ffconn-close
    }
    set ::model::Ffconn_sock $sock
    fconfigure $sock -blocking 0 -buffering line
    fileevent $sock readable ffread
    # report fruhod version when fruho client connects
    daemon-version-report
    daemon-model-report
    if {! $::model::ovpn_installing} {
        set ::model::Linuxdeps_count 0
        cyclic-linuxdeps-check
    }
}


proc ffconn-close {} {
    if {$::model::Ffconn_sock eq ""} {
        return
    }
    log ffconn-close $::model::Ffconn_sock
    catch {close $::model::Ffconn_sock}
    set ::model::Ffconn_sock ""
}

proc ffwrite {prefix msg {dolog 1}} {
    set sock $::model::Ffconn_sock
    if {$sock eq ""} {
        return
    }
    if {[catch {puts $sock "$prefix: $msg"; flush $sock;} out err]} {
        log $err
        log Because of error could not ffwrite: $prefix: $msg
        ffconn-close
    } else {
        if {$dolog} {
            log ffwrite: $prefix: $msg
        }
    }
}

# ::model::ovpn_config stores the full config with meta info and custom fruho options which is not correct openvpn config
# adjust-config should strip the ovpn config of this data to make the result suitable to pass to openvpn
# Also it should add missing options
# It should produce legal openvpn config
# Also replace -ca -cert and -key paths from homedir to /etc/fruhod/current based to workaround SELinux problem on Fedora
proc adjust-config {conf} {
    # adjust management port
    set mgmt [::ovconf::get $conf management]
    #TODO replace port to specific number
    if {[lindex $mgmt 0] in {localhost 127.0.0.1} && [lindex $mgmt 1]>0 && [lindex $mgmt 1]<65536} {
        # it's OK
    } else {
        set conf [::ovconf::cset $conf management [list 127.0.0.1 $::model::mgmt_port]]
    }
    # adjust verbosity
    set conf [::ovconf::cset $conf verb 3]
    # add suppressing timestamps
    set conf [::ovconf::cset $conf suppress-timestamps]
    # adjust windows specific options
    if {$::tcl_platform(platform) ne "windows"} {
        set conf [::ovconf::del-win-specific $conf]
    }
    # adjust deprecated options
    set conf [::ovconf::del-deprecated $conf]
    
    # If hostname resolve fails for --remote, retry resolve for 5 seconds before failing.
    set conf [::ovconf::cset $conf --resolv-retry 5]

    # For --proto tcp-client, take 1 as the number of retries of connection attempt (default=infinite).
    set conf [::ovconf::cset $conf --connect-retry-max 1]

    # For auth-user-pass interactive authentication enforce prompting from mgmt console
    if {[::ovconf::index $conf --auth-user-pass] != -1} {
        set conf [::ovconf::cset $conf --management-query-passwords]
    }

    # Remove custom authentication options 
    set conf [::ovconf::del $conf --custom-auth-user]
    set conf [::ovconf::del $conf --custom-auth-pass]

    # delete meta info
    set conf [::ovconf::del-meta $conf]

    # replace -ca -cert and -key paths to /etc/fruhod/current as a workaround for SELinux problem on Fedora
    set conf [copy-replace-path-current $conf --ca]
    set conf [copy-replace-path-current $conf --cert]
    set conf [copy-replace-path-current $conf --key]

    return $conf
}

proc copy-replace-path-current {conf opt} {
    file mkdir /etc/fruhod/current
    set path [lindex [::ovconf::get $conf $opt] 0]
    if {$path ne ""} {
        set tail [file tail $path]
        set new [file join /etc/fruhod/current $tail]
        file copy -force $path $new
        set conf [::ovconf::cset $conf $opt $new]
    }
    return $conf
}



# validate config paths and store config in state
proc load-config {conf} {
    # every attempt to load config should reset the previous one
    set ::model::ovpn_config ""
    # sanitize config input - DON'T. It may contain custom-auth-user and custom-auth-pass with any character
    if 0 {
        if {![regexp {^[\d\w\s@_:/\-.\{\}"]*$} $conf]} {
            log "CONF:\n$conf"
            return "Config contains illegal characters"
        }
    }
    set patherror [::ovconf::check-paths-exist $conf]
    if {$patherror ne ""} {
        return $patherror
    }
    set ::model::ovpn_config $conf
    return ""
}


proc kill-ovpn-by-saved-pid {} {
    set ovpnpid [ovpn-pid]
    if {$ovpnpid != 0} {
        if {[catch {exec kill $ovpnpid} out err]} {
            log "kill $ovpnpid failed"
            log $out \n $err
        } else {
            log "killed ovpn with pid $ovpnpid"
        }
    }
}



proc ffread {} {
    try {
        set sock $::model::Ffconn_sock
        if {$sock eq ""} {
            return
        }
        if {[gets $sock line] < 0} {
            if {[eof $sock]} {
                ffconn-close
            }
            return
        }
        
        log ffread: $line
        switch -regexp -matchvar tokens $line {
            {^stop$} {
                if {[ovpn-pid] != 0} {
                    kill-ovpn-by-saved-pid
                    OvpnExit 0
                } else {
                    ffwrite ctrl "Nothing to be stopped"
                    return
                }
            }
            {^start$} {
                if {$::model::ovpn_config eq ""} {
                    ffwrite ctrl "No OpenVPN config loaded"
                    return
                }
                if {[ovpn-pid] != 0} {
                    ffwrite ctrl "OpenVPN already running with pid [ovpn-pid]"
                    return
                } else {
                    ovpn-start
                    return
                }
            }
            {^config (.+)$} {
                set config [lindex $tokens 1]
                set configerror [load-config $config]
                log config $config
                if {$configerror eq ""} {
                    ffwrite ctrl "Config loaded"
                } else {
                    ffwrite ctrl $configerror
                }
                return
            }
            {^upgrade (.+)$} {
                log $line
                # $dir should contain fruhod.bin, fruho.bin and their signatures
                set dir [lindex $tokens 1]
                # if upgrade is successfull it never returns (execl replace program)
                #set err [upgrade $dir]
                
                # First try to upgrade the daemon
                set err [seamless-upgrade $dir/fruhod.bin [this-binary]]
                if {$err ne ""} {
                    ffwrite ctrl [log "Could not upgrade [this-binary] from $dir: $err"]
                    return
                }
                # Try to upgrade fruho client only if daemon succeeded
                # We need to do it here in fruhod because we need root
                set err [seamless-upgrade $dir/fruho.bin /usr/local/bin/fruho.bin]
                if {$err ne ""} {
                    ffwrite ctrl [log "Could not upgrade /usr/local/bin/fruho.bin from $dir: $err"]
                    #TODO shouldn't we revert daemon upgrade in this case?
                    return
                }

                # Restart the daemon only if both succeeded
                # Fruho client will restart itself after detecting version mismatch

                # execl replaces the calling process image with a new process image. 
                # This has the effect of running a new program with the process ID of the calling process. 
                # if this does not fail it never returns
                # Note: If you are using execl in a Tk application and it fails, you may not do anything that accesses the X server or you will receive a BadWindow error from the X server. This includes exe-cuting the Tk version of the exit command. We suggest using the following command to abort Tk applications after an execl fail-ure:
                # kill [id process]
                # On Windows, where the fork command is not available, execl starts a new process and returns the process id.
                execl [this-binary]
            }
            default {
                ffwrite ctrl "Unknown command"
            }
    
        }
    } on error {e1 e2} {
        log "$e1 $e2"
    } finally {
        daemon-model-report
    }
}

proc dns-replace {} {
    set dnsip $::model::ovpn_dnsip
    # Do nothing if DNS was not pushed by the server
    if {$dnsip eq ""} {
        return
    }
    # Do not backup resolv.conf if existing resolv.conf was fruhod generated
    # It prevents overwriting proper backup
    if {![dns-is-resolv-fruhod-generated]} {
        if {[catch {file rename -force /etc/resolv.conf /etc/resolv-fruhod.conf} out err]} {
            log $err
            return
        }
    }
    spit /etc/resolv.conf "$::model::Resolv_marker\nnameserver $dnsip"
}

proc dns-restore {} {
    if {[dns-is-resolv-fruhod-generated]} {
        if {[catch {file copy -force /etc/resolv-fruhod.conf /etc/resolv.conf} out err]} {
            # Not really an error, resolv-fruhod.conf may be non-existing for many reasons
            log "INFO: /etc/resolv-fruhod.conf does not exist"
        }
    }
}

proc dns-read-resolv {} {
    # Read existing resolv.conf
    if {[catch {set resolv [slurp /etc/resolv.conf]} out err]} {
        # log and ignore error
        log $err
        set resolv ""
    }
    return $resolv
}

proc dns-is-resolv-fruhod-generated {} {
    return [string match *$::model::Resolv_marker* [dns-read-resolv]]
}


proc OvpnRead {line} {
    try {
        set ignoreline 0
        switch -regexp -matchvar tokens $line {
            {MANAGEMENT: TCP Socket listening on \[AF_INET\]127\.0\.0\.1:(\d+)} {
                # update the mgmt port in case we had to choose another port than default from the model
                set ::model::mgmt_port [lindex $tokens 1]
                #we should call MgmtStart here, but it was moved after "TCP connection established" 
                #because connecting to mgmt interface too early caused OpenVPN to hang
            }
            {MANAGEMENT: Client connected from \[AF_INET\]127\.0\.0\.1:\d+} {
                #
            }
            {MANAGEMENT: Socket bind failed on local address \[AF_INET\]127\.0\.0\.1:(\d+) Address already in use} {
                # TODO what to do? 
                # busy mgmt port most likely means that openvpn is already running
                # on rare occasions it may be occupied by other application
                #retry/alter port
            }
            {Exiting due to fatal error} {
                OvpnExit 1
            }
            {MANAGEMENT: Client disconnected} {
                log Management client disconnected
            }
            {MANAGEMENT: CMD 'state'} {
                set ignoreline 1
            }
            {MANAGEMENT: CMD 'status'} {
                set ignoreline 1
            }
            {MANAGEMENT: CMD 'pid'} {
                set ignoreline 1
            }
            {TCP connection established with \[AF_INET\](\d+\.\d+\.\d+\.\d+):(\d+)} {
                # this only occurs for TCP tunnels = useless for general use
            }
            {TLS: Initial packet from \[AF_INET\](\d+\.\d+\.\d+\.\d+):(\d+)} {
                #after idle MgmtStarted $::model::mgmt_port
            }
            {TUN/TAP device (tun\d+) opened} {
            }
            {Initialization Sequence Completed} {
                MgmtStatus
                dns-replace
            }
            {Network is unreachable} {
            }
            {ERROR:.*Operation not permitted} {
                OvpnExit 1
            }
            {SIGTERM.*received, process exiting} {
                OvpnExit 0
            }
            {Inactivity timeout.*restarting} {
                kill-ovpn-by-saved-pid
                OvpnExit 0
            }
            {PUSH: Received control message} {
                # We need to handle PUSH commands from the openvpn server. Primarily DNS because we need to change resolv.conf
                #PUSH: Received control message: 'PUSH_REPLY,redirect-gateway def1 bypass-dhcp,dhcp-option DNS 10.10.0.1,route 10.10.0.1,topology net30,ping 5,ping-restart 28,ifconfig 10.10.0.66 10.10.0.65'
                if {[regexp {dhcp-option DNS (\d+\.\d+\.\d+\.\d+)} $line _ dnsip]} {
                    set ::model::ovpn_dnsip $dnsip
                }
            }
            default {
                #log OPENVPN default: $line
            }
        }
        if {!$ignoreline} {
            ffwrite ovpn $line
            log OPENVPN: $line
        }
    } on error {e1 e2} {
        log $e1 $e2
    }
}

#event_wait : Interrupted system call (code=4)
#/sbin/route del -net 10.10.0.1 netmask 255.255.255.255
#/sbin/route del -net 46.165.208.40 netmask 255.255.255.255
#/sbin/route del -net 0.0.0.0 netmask 128.0.0.0
#/sbin/route del -net 128.0.0.0 netmask 128.0.0.0
#Closing TUN/TAP interface
#/sbin/ifconfig tun0 0.0.0.0
#SIGTERM[hard,] received, process exiting
 

#MANAGEMENT: Socket bind failed on local address [AF_INET]127.0.0.1:8888: Address already in use


# this happens after starting openvpn after previous kill -9. It means that the:
# 46.165.208.40   192.168.1.1     255.255.255.255 UGH   0      0        0 wlan0
# route is not removed, others are removed by system because tun0 is destroyed
#ovpn: Mon Mar 30 15:15:52 2015 /sbin/route add -net 46.165.208.40 netmask 255.255.255.255 gw 192.168.1.1
#ovpn: Mon Mar 30 15:15:52 2015 ERROR: Linux route add command failed: external program exited with error status: 7


proc OvpnErrRead {line} {
    #TODO communicate error to user. gui and cli
    log openvpn stderr: $line
    ffwrite ovpn "stderr: $line"
}

# should be idempotent, as may be called many times on openvpn shutdown
proc OvpnExit {code} {
    if {[ovpn-pid] != 0} {
        ffwrite ctrl "OpenVPN with pid [ovpn-pid] stopped"
    }

    file delete -force /etc/fruhod/current

    dns-restore
    model reset-ovpn-state
}


proc build-version {} {
    memoize
    return [string trim [slurp [file join [file dir [info script]] buildver.txt]]]
}

proc build-date {} {
    memoize
    return [string trim [slurp [file join [file dir [info script]] builddate.txt]]]
}

proc ovpn-pid {} {
    # if Mgmt_pid up to date
    if {$::model::Mgmt_pid != 0 && [clock milliseconds] - $::model::Mgmt_pid_tstamp < 3000} {
        set ::model::ovpn_pid $::model::Mgmt_pid
    } elseif {$::model::Start_pid != 0 && [clock milliseconds] - $::model::Start_pid_tstamp < 5000} {
        set ::model::ovpn_pid $::model::Start_pid
    } else {
        set ::model::ovpn_pid 0
    }
    return $::model::ovpn_pid
}

proc ovpn-start {} {
    if {$::model::ovpn_installing} {
        # postpone openvpn start in hope that openvpn will get installed in the meantime
        after 5000 ovpn-start
    } else {
        model reset-ovpn-state
        set config [adjust-config $::model::ovpn_config]
        set ovpncmd "openvpn $config"
        try {
            set stdinout [cmd invoke $ovpncmd OvpnExit OvpnRead OvpnErrRead]
            set ::model::Start_pid [pid $stdinout]
            set ::model::Start_pid_tstamp [clock milliseconds]
            # this call is necessary to update ovpn_pid
            ovpn-pid
            ffwrite ctrl "OpenVPN with pid [ovpn-pid] started"
        } on error {e1 e2} {
            ffwrite ctrl "OpenVPN ERROR: $e1"
            log $e1 $e2
        }
    }
}


# TODO
proc ovpn-is-connected {} {
#    if {[dict get $stat ovpn_pid] == 0} 
#        set connstatus disconnected
#    elseif {[dict get $stat mgmt_connstatus] eq "CONNECTED"} 
}

# TODO
proc mgmt-is-connected {} {
}

# After tun/tap driver update to OpenVPN 2.3.6 the only things that have changed in driver data:
#Code(bytes):       19˙968,00
#Link Date:         2013-08-22 13:40:00
#Path:              C:\WINDOWS\system32\DRIVERS\tap0901.sys
#Init(bytes):       1˙664,00

# Consider including sysinternals sigcheck in deployment that will produce the following:
#        Verified:       Signed
#        Signing date:   13:40 2013-08-22
#        Publisher:      OpenVPN Technologies
#        Description:    TAP-Windows Virtual Network Driver
#        Product:        TAP-Windows Virtual Network Driver
#        Prod version:   9.9.2 9/9
#        File version:   9.9.2 9/9 built by: WinDDK
#        MachineType:    32-bit

main

vwait forever
