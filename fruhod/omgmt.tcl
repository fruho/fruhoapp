#
# fruhod/omgmt.tcl
#

proc MgmtConnect {} {
    catch {MgmtClose}
    catch {
        set ::model::Mgmt_sock [socket 127.0.0.1 $::model::mgmt_port]
        chan configure $::model::Mgmt_sock -blocking 0 -buffering line
        chan event $::model::Mgmt_sock readable [list MgmtRead $::model::Mgmt_sock]
    }
}

proc MgmtClose {} {
    if {$::model::Mgmt_sock ne ""} {
        catch {close $::model::Mgmt_sock}
        set ::model::Mgmt_sock ""
        set ::model::Mgmt_clientok 0
    }
}

proc MgmtRead {sock} {
    try {
        if {[gets $sock line] >= 0} {
            #log "MGMT: $line"
            switch -regexp -matchvar tokens $line {
                {^TUN/TAP read bytes,(\d+)$} {
                    # status command output
                    set ::model::mgmt_vread [lindex $tokens 1]
                }
                {^TUN/TAP write bytes,(\d+)$} {
                    # status command output
                    set ::model::mgmt_vwrite [lindex $tokens 1]
                }
                {^TCP/UDP read bytes,(\d+)$} {
                    # status command output
                    set ::model::mgmt_rread [lindex $tokens 1]
                }
                {^TCP/UDP write bytes,(\d+)$} {
                    # status command output
                    set ::model::mgmt_rwrite [lindex $tokens 1]
                }
    
                {^(\d+),(.+),(.*),(.*),(.*)$} {
                    # state command output
                    # For example:
                    # 1436527709,AUTH,,,
                    # 1436527711,GET_CONFIG,,,
                    # 1436527712,ASSIGN_IP,,10.13.0.6,
                    # 1436527715,CONNECTED,SUCCESS,10.13.0.6,78.129.174.84
                    set connstatus [lindex $tokens 2]
                    set ::model::mgmt_vip [lindex $tokens 4]
                    set ::model::mgmt_rip [lindex $tokens 5]
                    # immediately report the change to CONNECTED status to a client by calling daemon-model-report
                    if {$connstatus eq "CONNECTED" && $::model::mgmt_connstatus ne "CONNECTED"} {
                        # model::mgmt_connstatus may store stale value - it is valid only when ovpn_pid is not zero
                        set ::model::mgmt_connstatus $connstatus
                        daemon-model-report
                    } else {
                        set ::model::mgmt_connstatus $connstatus
                    }
                    set ::model::mgmt_state_tstamp [clock milliseconds]
                }
                {^SUCCESS: pid=(\d+)$} {
                    # pid command output
                    set ::model::Mgmt_pid [lindex $tokens 1]
                    set ::model::Mgmt_pid_tstamp [clock milliseconds]
                    # this call is necessary to update ovpn_pid in the model
                    ovpn-pid
                }
                {FATAL:ERROR:.*Operation not permitted} {
                    #when run without sudo, should be handled from direct ovpn logs
                }
                {OpenVPN Management Interface Version} {
                    # give more delay after MgmtConnect - workaround for the OpenVPN freeze bug
                    after 3000 set ::model::Mgmt_clientok 1
                    #puts "OpenVPN welcome: $line"
                }
                {SUCCESS: hold release succeeded} {
                    #puts "$line"
                }
                pre-compress -
                post-compress -
                pre-decompress -
                post-decompress -
                "OpenVPN STATISTICS" -
                Updated, -
                "Auth read bytes" -
                END {
                    #ignore
                    #puts "MGMT IGNORE: $line"
                }
                default {
                    #unrecognized openvpn mgmt interface output
                    puts "MGMT UNRECOGNIZED: $line"
                }
            }
        }
        if {[eof $sock]} {
            log "eof $sock"
            catch {close $sock}
            MgmtClose
        }
    } on error {e1 e2} {
        log $e1 $e2
        catch {close $sock}
        MgmtClose
    }
}

proc MgmtWrite {cmd} {
    if {$::model::Mgmt_sock ne ""} {
        if {[catch {puts -nonewline $::model::Mgmt_sock "$cmd\r\n"} out err]} {
            log $out $err
            MgmtClose
        }
    }
}

proc MgmtStatus {} {
    MgmtWrite status
    MgmtWrite state
    MgmtWrite pid
}

proc MgmtHoldRelease {} {
    MgmtWrite "hold release"
}

proc MgmtConnectionMonitor {} {
    if {$::model::Mgmt_sock eq ""} {
        MgmtConnect
    }
    after 500 MgmtConnectionMonitor
}

proc MgmtStatusMonitor {} {
    if {$::model::Mgmt_clientok} {
        MgmtStatus
    }
    after 400 MgmtStatusMonitor
}
