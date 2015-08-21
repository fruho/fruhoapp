# Global model of the application
# Part of it will be durable in ini config file(s)
#
# Using the convention: lowercase variables are saveable in inicfg !!! Capitalized or starting with other character are transient !!!
#

package require inicfg
package require skutil
package require csp

namespace eval ::model {
    
    namespace export *
    namespace ensemble create

    ######################################## 
    # Constants
    ########################################
    
    variable HOME [file normalize ~]
    variable CONFIGDIR [file join $HOME .fruho]
    variable INIFILE [file join $CONFIGDIR fruho.ini]
    variable LOGFILE [file join $CONFIGDIR fruho.log]
    variable PROFILEDIR [file join $CONFIGDIR profile]
    variable UPGRADEDIR [file join $CONFIGDIR upgrade]
    variable CADIR [file join $CONFIGDIR certs]


    ######################################## 
    # General globals
    ######################################## 

    # currently selected tab as a profileid (may need to be converted to full name of the tab frame)
    variable selected_profile fruho

    # fruhod --- fruho client connection socket 
    variable Ffconn_sock ""

    # last stat heartbeat from fruhod timestamp in millis
    variable Ffconn_beat 0

    # User Interface (gui or cli)
    variable Ui ""

    variable Running_binary_fingerprint ""

    # Time offset relative to the "now" received in welcome message
    variable now_offset 0

    # latest fruho version to upgrade from check-for-updates
    variable Latest_version 0


    # Last line of log received from fruhod/openvpn server with ovpn prefix
    variable OvpnServerLog ""

    # The built-in interim profile Fruho
    # while profile may contain multiple plans/slists, we need to store current slist as well since it depends on current time (through active plan selection)
if 0 {    variable Profiles [dict create fruho {
        profilename Fruho
        plans {id1 {name INTERIM timelimit {start 123456789 period month nop 3} trafficlimit {used 50000000 quota 400000000} slist {{id 1 ccode DE country Germany city Darmstadt ip 46.165.221.230 ovses {{proto udp port 123} {proto tcp port 443}}} {id 4 ccode FR country France city Paris ip 37.59.65.55 ovses {{proto udp port 56789}}}} selected_sitem_id ""}}
    }]
}
    

    # !!! Be careful in operating on model::Profiles (iterating, listing, etc). Prevent shimmering.
    # Internally it should be represented as a dictionary in order to properly save in inicfg::save
    # You can use defensive copy [dict replace $::model::Profiles]
    # Always use [dict for] instead of [foreach]
    variable Profiles [dict create fruho [dict create profilename Fruho]]

    # profile ids marked as removed
    variable removed_profiles {}

    # The OpenVPN connection protocol port preference order
    variable protoport_order {{udp 5353} {udp 53} {udp 443} {udp 5000} {tcp 443}}

    variable dns_cache [dict create www.securitykiss.com 91.227.221.115]

    # sample welcome message:
    # ip 127.0.0.1
    # now 1436792064
    # latestSkt 1.4.4
    # serverLists
    # {
    #     GREEN {{id 1 ccode DE country Germany city Darmstadt ip 46.165.221.230 ovses {{proto udp port 123} {proto tcp port 443}}}}
    #     JADEITE {{id 1 ccode DE country Germany city Darmstadt ip 46.165.221.230 ovses {{proto udp port 123} {proto tcp port 443}}} {id 2 ccode FR country France city Paris ip 176.31.32.106 ovses {{proto udp port 123} {proto tcp port 443}}} {id 3 ccode UK country {United Kingdom} city London ip 78.129.174.84 ovses {{proto udp port 5353} {proto tcp port 443}}}}
    # 
    # }
    # activePlans {{name JADEITE period month limit 50000000000 start 1431090862 used 12345678901 nop 3} {name GREEN period day limit 300000000 start 1431040000 used 15000000 nop 99999}}


    # sample slist
    # {{id 1 ccode DE country Germany city Darmstadt ip 46.165.221.230 ovses {{proto udp port 123} {proto tcp port 443}}} {id 2 ccode FR country France city Paris ip 176.31.32.106 ovses {{proto udp port 123} {proto tcp port 443}}} {id 3 ccode UK country {United Kingdom} city Newcastle ip 31.24.33.221 ovses {{proto udp port 5353} {proto tcp port 443}}}}
    # There is a single slist and selected_sitem_id (ssid) per profile
    # On Click Connect the current profile's selected_sitem is copied to Current_sitem which stores currently connecting/connected sitem
 
    variable Current_sitem {}
    variable Current_protoport {}

    variable layout_bg1 white
    variable layout_bg2 grey95
    variable layout_bg3 #eeeeee
    variable layout_fgused grey
    variable layout_fgelapsed grey
    variable layout_x 300
    variable layout_y 300
    variable layout_w 0
    variable layout_h 0
    variable layout_barw 350
    variable layout_barh 8

    variable Geo_loc ""


    # OpenVPN connection status as reported by fruhod/openvpn stat reports
    # Although the source of truth for connstatus is fruhod stat reports (but it is not always up-to-date)
    # we keep local copy to know when to update display
    variable Connstatus unknown
    variable Connstatus_change_tstamp 0


    # Last N measurements of traffic up, down and timestamps for currently connected profile
    variable Previous_trafficup {}
    variable Previous_trafficdown {}
    variable Previous_traffic_tstamp {}
    # number of traffic probes saved and used for moving average - this is to be saved in config
    variable previous_traffic_probes 5


    variable Gui_openvpn_connection_timeout 15
    variable openvpn_connection_timeout 15

    csp::channel ::model::Chan_button_connect
    csp::channel ::model::Chan_button_disconnect
    csp::channel ::model::Chan_stat_report
    csp::channel ::model::Chan_ffread




    # client id
    variable Cn ""
    
    # Embedded bootstrap hostport list
    variable Hostports {}

    variable hostport_lastok 0

    ######################################## 
    # Supported providers
    ######################################## 
    # e.g.: from_file {name from_file dispname "From File"}
    #
    variable Supported_providers {}
}


# Display all model variables to stderr
proc ::model::print {} {
    puts stderr "MODEL:"
    foreach v [info vars ::model::*] {
        puts stderr "$v=[set $v]"
    }
    puts stderr ""
}

# get the list of ::model namespace variables
proc ::model::vars {} {
    lmap v [info vars ::model::*] {
        string range $v [string length ::model::] end
    }
}


proc ::model::active-profiles {} {
    set keys [dict keys $::model::Profiles]
    return [ldiff $keys $::model::removed_profiles]
}


proc ::model::connstatus {args} {
    if {[llength $args] == 1} {
        # unknown status can be immediately overwritten so while setting unknown status reset last change tstamp to 0 so that stat report does not need to delay update
        set newstatus [lindex $args 0]
        set ::model::Connstatus $newstatus
        if {$newstatus ne "unknown"} {
            set ::model::Connstatus_change_tstamp [clock milliseconds]
        }
    } else {
        return $::model::Connstatus
    }
}



proc ::model::ini2model {inifile} {
    touch $inifile
    # smd - Saved Model Dictionary
    set smd [inicfg load $inifile]
    dict for {key value} $smd { 
        set ::model::$key $value
    }
}

proc ::model::model2ini {inifile} {
    # load entire model namespace to a dict
    set d [dict create]
    foreach key [::model::vars] {
        dict set d $key [set ::model::$key]
    }
    # save fields starting with lowercase
    set smd [dict filter $d key \[a-z\]*]
    inicfg save $inifile $smd
}

proc ::model::dict2ini {d inifile} {
    # save field if starts with lowercase
    set smd [dict filter $d key \[a-z\]*]
    #log "\nSMD: inicfg save \{$inifile\} \{$smd\}\n"
    inicfg save $inifile $smd
}

proc ::model::load-bootstrap {} {
    # embedded bootstrap hostport list
    set lst [slurp [file join [file dir [info script]] bootstrap.lst]]
    set ::model::Hostports {}
    foreach v $lst {
        set v [string trim $v]
        lassign [split $v :] ip port
        if {[is-valid-ip $ip] && ([is-valid-port $port] || $port eq "")} {
            lappend ::model::Hostports $v
        }
    }
    #TODO isn't certificate signing start date a problem in case of bootstrap hosts in different timezones? Consider signing with golang crypto libraries
}



# Read saved part of the model as a dict
# and populate to model ns
proc ::model::load {} {
    if {[catch {
        ini2model $::model::INIFILE
        ::model::load-bootstrap

        # load profiles from individual directories and update model
        set profiles [lmap d [glob -directory $::model::PROFILEDIR -nocomplain -type d *] {file tail $d}]
        # sanitize directory names
        foreach p $profiles {
            if {![regexp {^[\w\d_]+$} $p]} {
                fatal "Profile directory name should be alphanumeric string in $::model::PROFILEDIR"
            }
        }

        foreach p $profiles {
            set inifile [file join $::model::PROFILEDIR $p config.ini]
            if {[file exists $inifile]} {
                dict set ::model::Profiles $p [inicfg load $inifile]
            }
        }
        #puts stderr "MODEL PROFILES: \n[::inicfg::dict-pretty $::model::Profiles]"

    } out err]} {
        puts stderr $out
        log $out
        log $err
        main-exit nosave
    }
}

# may throw errors
proc ::model::save {} {
    # save main ini
    ::model::model2ini $::model::INIFILE
    # save profile inis
    dict for {p d} $::model::Profiles {
        set inifile [file join $::model::PROFILEDIR $p config.ini]
        ::model::dict2ini $d $inifile
    }
}


######################################## 
# Slist and Sitem logic
######################################## 

proc ::model::slist {profile planid} {
    return [dict-pop $::model::Profiles $profile plans $planid slist {}]
}

# Get or store selected sitem/site_id. Since slist is dynamic the selected sitem may get obsolete. 
# This function should prevent returning obsolete selected sitem by taking random in that case
# so there is no guarantee that what you put in is what you get out
#
# With additional arguments (profile nad planid identify an slist):
# selected-sitem $profile $planid - get selected sitem (dict) for profile and planid or draw random from slist, if slist is empty return empty
# selected-sitem $profile $planid ?sitem_id?
# selected-sitem $profile $planid ?sitem?
# - saves selected sitem id. Given sitem may be empty
proc ::model::selected-sitem {profile planid args} {
    if {[llength $args] == 0} {
        set slist [::model::slist $profile $planid]
        if {$slist eq ""} {
            return ""
        }
        set ssid [dict-pop $::model::Profiles $profile plans $planid selected_sitem_id {}]
        if {$ssid eq "" || [::model::sitem-by-id $profile $planid $ssid] eq ""} {
            # pick random sitem
            set rand [rand-int [llength $slist]]
            set sitem [lindex $slist $rand]
            #puts stderr "rand: $rand, sitem: $sitem"
            # save its id in model
            dict set ::model::Profiles $profile plans $planid selected_sitem_id [dict get $sitem id]
            return $sitem
        } else {
            return [::model::sitem-by-id $profile $planid $ssid]
        }
    } elseif {[llength $args] == 1} {
        set sitem [lindex $args 0]
        if {$sitem eq ""} {
            set sitem_id ""
        } elseif {[string is integer -strict $sitem]} {
            set sitem_id $sitem
        } else {
            set sitem_id [dict-pop $sitem id {}]
        }
        dict set ::model::Profiles $profile plans $planid selected_sitem_id $sitem_id
        return [::model::selected-sitem $profile $planid]
    } else {
        log ERROR: wrong number of arguments in selected-sitem $profile $args
    }
}

# return sitem dict by id or empty if no such sitem in the given profile
proc ::model::sitem-by-id {profile planid sitem_id} {
    foreach sitem [::model::slist $profile $planid] {
        set id [dict get $sitem id]
        if {$id eq $sitem_id} {
            return $sitem
        }
    }
    return ""
}

# [model now]
# return offset-ed current time, it may use previously saved time offset 
# it should be server-originated UTC in seconds, if no offset use local time
# TODO remember to update display and time related derivatives 
# (for example current plan) after welcome message received
# in order to get the time with updated time offset
# TODO what to do if we get "now" from many welcome messages?
# [model now $now]
# use $now to calculate time offset that will be saved in the model
proc ::model::now {args} {
    if {[llength $args] == 0} {
        return [expr {[clock seconds] + $::model::now_offset}]
    } elseif {[llength $args] == 1} {
        set now [lindex $args 0]
        if {[string is integer -strict $now]} {
            set ::model::now_offset [expr {$now - [clock seconds]}]
        }
    } else {
        log ERROR: wrong number of arguments in ::model::now $args
    }
}





