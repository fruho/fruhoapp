#
# fruho/main.tcl
#
# This should be the preamble to every application
# It makes it possible to run as starpack or as a sourced script
if {![catch {package require starkit}]} {
  #this is to initialize starkit variables
  starkit::startup
}



package require ovconf
package require tls
#package require http
package require cmdline
package require unix
# unix requires Tclx which litters global namespace. Need to clean up to avoid conflict with csp
rename ::select ""
package require linuxdeps
#http::register https 443 [list tls::socket]
package require http
package require https
package require json
package require i18n
package require csp
namespace import csp::*
package require img
package require uri
# skutil must be last required package in order to overwrite the log proc from Tclx
package require skutil

source [file join [file dir [info script]] model.tcl]
foreach f [glob -nocomplain -directory [file dir [info script]] add_*.tcl] {
    source $f
}
set ::model::Supported_providers [lsort -decreasing -stride 2 $::model::Supported_providers]

# print to stderr
proc pq {id args} {
    puts stderr "[join [lrepeat 10 $id] ""]:    [join $args]"
}


proc fatal {msg {err ""}} {
    log $msg $err
    in-ui error $msg
    main-exit
}

proc exit-nosave {msg} {
    in-ui error [log $msg]
    main-exit nosave
}


proc background-error {msg err} {
    fatal $msg [dict get $err -errorinfo]
}

interp bgerror "" background-error
#after 4000 {error "This is my bg error"}

# We need to redirect to log file here and not in external shell script
# in case it is run with sudo. Then logging would go to /root/.fruho
# Redirect stdout to a file $::model::LOGFILE
namespace eval tolog {
    variable fh
    proc initialize {args} {
        variable fh
        # if for some reason cannot log to file, log to stderr
        if {[catch {mk-head-dir $::model::LOGFILE} out err] == 1 || [catch {set fh [open $::model::LOGFILE w]} out err] == 1} {
            set fh stderr
            puts stderr $err
        }
        info procs
    }
    proc finalize {args} {
        variable fh
        catch {close $fh}
    }
    proc clear {args} {}
    proc flush {handle} {
        variable fh
        if {[catch {::flush $fh} out err] == 1} {
            set fh stderr
            puts stderr $err
        }
    }
    proc write {handle data} {
        variable fh
        # again, downgrade to logging to stderr if problems with writing to file
        if {[catch {puts -nonewline $fh $data} out err] == 1} {
            set fh stderr
            puts stderr $err
        }
        flush $fh
    }
    namespace export *
    namespace ensemble create
}



proc redirect-stdout {} {
    chan push stdout tolog
}

# Parse command line options and launch proper task
# It may set global variables
proc main {} {
    try {
        unix relinquish-root
        # every created file by the app should be private
        umask 0077
        redirect-stdout
    
        # watch out - cmdline is buggy. For example you cannot define help option, it conflicts with the implicit one
        set options {
                {cli                "Run command line interface (CLI) instead of GUI"}
                {generate-keys      "Generate private key and certificate signing request"}
                {add-launcher       "Add desktop launcher for current user"}
                {remove-launcher    "Remove desktop launcher"}
                {id                 "Show client id from the certificate"}
                {version            "Print version"}
                {locale    en       "Run particular language version"}
            }
        set usage ": fruho \[options]\noptions:"
        if {[catch {array set params [::cmdline::getoptions ::argv $options $usage]}] == 1} {
            log [cmdline::usage $options $usage]
            exit 1
        }
    
    
        if {[catch {i18n load en [file join [file dir [info script]] messages.txt]} out err]} {
            log $out
            log $err
        }
    
        puts stderr [build-date]
        puts stderr [build-version]
        model load

        # Copy cadir because it  must be accessible from outside of the starkit
        # Overwrites certs on every run
        copy-merge [file join [file dir [info script]] certs] $::model::CADIR
    
        if {$params(cli) || ![unix is-x-running] || $params(version) || $params(id) || $params(generate-keys) || $params(add-launcher) || $params(remove-launcher)} {
            set ::model::Ui cli
        } else {
            set ::model::Ui gui
        }
    
        if {$params(version)} {
            exit-nosave [build-version]
        }
    
        if {$params(generate-keys)} {
            main-generate-keys
            main-exit nosave
        }
        if {$params(add-launcher)} {
            puts stderr [log Adding Desktop Launcher]
            unix add-launcher fruho
            main-exit nosave
        }
        if {$params(remove-launcher)} {
            puts stderr [log Removing Desktop Launcher]
            unix remove-launcher fruho
            main-exit nosave
        }
    

        try {
            set cn [extract-cn-from csr [ovpndir fruho client.csr]]
            set ::model::Cn $cn
            if {$params(id)} {
                exit-nosave $cn
            }
        } on error {e1 e2} {
            log "$e1 $e2"
            exit-nosave "Could not retrieve client id. Try to reinstall the program."
        }
    
        
        set piderr [create-pidfile ~/.fruho/fruho.pid]
        if {$piderr ne ""} {
            exit-nosave $piderr
        } 
    
        set ::model::Running_binary_fingerprint [sha1sum [this-binary]]
    
        in-ui main
        daemon-monitor
        plan-monitor
    } on error {e1 e2} {
        log $e1 $e2
    }
}

proc main-exit {{arg ""}} {
    #TODO Disconnect and clean up
    if {$arg ne "nosave"} {
        model save
    }
    # ignore if problems occurred in deleting pidfile
    delete-pidfile ~/.fruho/fruho.pid
    set ::until_exit 1
    catch {close [$::model::Ffconn_sock}
    catch {destroy .}
    exit
}


# Combine $fun and $ui to run proper procedure in gui or cli
proc in-ui {fun args} {
    [join [list $fun $::model::Ui] -] {*}$args
}


proc error-gui {msg} {
    # if Tk not functional downgrade displaying errors to cli
    if {[is-tk-loaded]} {
        # hide toplevel window. Use wm deiconify to restore later
        catch {wm withdraw .}
        log $msg
        tk_messageBox -title "fruho error" -type ok -icon error -message ERROR -detail "$msg\n\nPlease check $::model::LOGFILE for details"
    } else {
        error-cli $msg
    }
}

proc error-cli {msg} {
    log $msg
    puts stderr $msg
}
# This is blocking procedure to be run from command line
# ruturn 1 on success, 0 otherwise
# Print to stderr for user-visible messages. Use log for detailed info written to log file
proc main-generate-keys {} {
    puts stderr [log Generating RSA keys]
    set privkey [ovpndir fruho client.key]
    if {[file exists $privkey]} {
        puts stderr [log RSA key $privkey already exists]
    } else {
        if {![generate-rsa $privkey]} {
            puts stderr [log Could not generate RSA keys]
            return
        }
    }
    set csr [ovpndir fruho client.csr]
    if {[file exists $csr]} {
        puts stderr [log CSR $csr already exists]
    } else {
        set cn [generate-cn]
        if {![generate-csr $privkey $csr $cn]} {
            puts stderr [log Could not generate Certificate Signing Request]
            return
        }
    }
    return
}


#TODO generate from HD UUID/dbus machine-id and add sha256 for checksum/proof of work
proc generate-cn {} {
    return [join [lmap i [seq 8] {rand-byte-hex}] ""]
}

proc main-cli {} {
    log Running CLI
    #TODO
}

# height should be odd value
proc hsep {parent height} {
    set height [expr {($height-1)/2}]
    static counter 0
    incr counter
    ttk::frame $parent.sep$counter
    grid $parent.sep$counter -padx 10 -pady $height -sticky news
}


proc main-gui {} {
    try {
        log Running GUI
        # TODO fruho client may be started before all Tk deps are installed, so run in CLI first and check for Tk a few times with delay
        package require Tk 
        wm title . "Fruho"
        wm iconphoto . -default [img load 16/logo] [img load 24/logo] [img load 32/logo] [img load 64/logo]
        wm deiconify .
        wm protocol . WM_DELETE_WINDOW {
            #TODO improve the message
            main-exit
            if {[tk_messageBox -message "Quit?" -type yesno] eq "yes"} {
                main-exit
            }
        }
    
        ttk::frame .c
        grid .c -sticky news
        grid columnconfigure . .c -weight 1
        grid rowconfigure . .c -weight 1
    
        frame-toolbar .c
    
        ttk::frame .c.tabsetenvelope
        grid columnconfigure .c.tabsetenvelope 0 -weight 1
        grid rowconfigure .c.tabsetenvelope 0 -weight 1
        grid .c.tabsetenvelope -sticky news

        tabset-profiles .c.tabsetenvelope
    
        frame-ipinfo .c
        frame-status .c
        hsep .c 15
        frame-buttons .c
        hsep .c 5
    
        # If the tag is the name of a class of widgets, such as Button, the binding applies to all widgets in that class;
        bind Button <Return> InvokeFocusedWithEnter
        bind TButton <Return> InvokeFocusedWithEnter
        #TODO coordinate with shutdown hook and provide warning/confirmation request
        bind . <Control-w> main-exit
        bind . <Control-q> main-exit
    
        grid [ttk::label .statusline -textvariable ::model::OvpnServerLog]
        # sizegrip - bottom-right corner for resize
        grid [ttk::sizegrip .grip] -sticky se
    
        setDialogSize .
        grid columnconfigure .c 0 -weight 1
        # this will allocate spare space to the first row in container .c
        grid rowconfigure .c .c.tabsetenvelope -weight 1
        bind . <Configure> [list MovedResized %W %x %y %w %h]
    
        go get-welcome
        go faas-config-monitor
        gui-update
    } on error {e1 e2} {
        puts stderr [log $e1 $e2]
    }
}


proc check-for-updates {uframe} {
    try {
        channel {chout cherr} 1
        curl-dispatch $chout $cherr bootstrap:10443 -urlpath /check-for-updates?[this-pcv]
        select {
            <- $chout {
                set data [<- $chout]
                if {[is-dot-ver $data]} { 
                    set ::model::Latest_version $data
                } else {
                    set ::model::Latest_version 0
                }
                puts stderr "Check for updates: $data"
            }
            <- $cherr {
                set ::model::Latest_version 0
                set err [<- $cherr]
                puts stderr "Check failed: $err"
            }
        }
        checkforupdates-refresh $uframe 0
        $chout close
        $cherr close
    } on error {e1 e2} {
        log "$e1 $e2"
    }
}

# calculate current slist for profile at timestamp
# tstamp - current time given as argument to get multiple values in specific moment
proc current-slist {tstamp profile} {
    #TODO temporary assertion
    if {[is-addprovider $profile]} {
        fatal "profile in current-planid should not be $profile" 
    }
    set planid [current-planid $tstamp $profile]
    return [dict-pop $::model::Profiles $profile plans $planid slist {}]
}


# calculate current pland id for profile at timestamp
# tstamp - current time given as argument to get multiple values in specific moment
proc current-planid {tstamp profile} {
    #TODO temporary assertion
    if {[is-addprovider $profile]} {
        fatal "profile in current-planid should not be $profile" 
    }
    # operate on copy of model::Profiles to prevent shimmering and saving problem in inicfg::save
    set profiles [dict replace $::model::Profiles]

    # get plans dictionary id=>plan
    set plans [dict-pop $profiles $profile plans {}]
    if {$plans eq {}} {
        return ""
    }

    #puts stderr [log "before lsort: plans: $plans"]

    # sort by the second element of 2-elem tuples which is the actual plan
    set sorted_plans [lsort -stride 2 -index 1 -command [list plan-comparator $tstamp] $plans]
    set planid [lindex $sorted_plans 0]
    return $planid
}


proc period-elapsed {plan tstamp} {
    return [expr {$tstamp - [period-start $plan $tstamp]}]
}

proc period-length {plan tstamp} {
    return [expr {[period-end $plan $tstamp] - [period-start $plan $tstamp]}]
}


proc period-end {plan tstamp} {
    set period [dict-pop $plan timelimit period day]
    set period_start [period-start $plan $tstamp]
    #TODO make sure that period is handled well when milliseconds/seconds
    return [clock add $period_start 1 $period]
}

proc period-start {plan tstamp} {
    set period [dict-pop $plan timelimit period day]
    if {$period eq "day"} {
        set periodsecs 86400
    } elseif {$period eq "month"} {
        # average number of seconds in a month
        set periodsecs 2629800
    #TODO one more else for handling period in seconds/milliseconds
    } else {
        # just in case set default to day
        set periodsecs 86400
    }
    set plan_start [plan-start $plan]
    set secs [expr {$tstamp - $plan_start}]
    # estimated number of periods
    set est [expr {$secs / $periodsecs - 2}]
    for {set i $est} {$i<$est+5} {incr i} {
        set start [clock add $plan_start $i $period]
        set end [clock add $plan_start [expr {$i+1}] $period]
        if {$start <= $tstamp && $tstamp < $end} {
            return $start
        }
    }
    error "Could not determine period-start for plan $plan and tstamp $tstamp"
}


proc plan-start {plan} {
    return [dict-pop $plan timelimit start [model now]]
}


proc plan-end {plan} {
    set period [dict-pop $plan timelimit period day]
    set plan_start [plan-start $plan]
    set nop [dict-pop $plan timelimit nop 0]
    #TODO make it work for period being in {day month <ms>}
    return [clock add $plan_start $nop $period]
}



# tstamp - current time given as argument to get multiple values in specific moment
proc plan-is-active {tstamp plan} {
    set start [plan-start $plan]
    return [expr {$start < $tstamp && $tstamp < [plan-end $plan]}]
}

# sort activePlans:
# - active first
# - month first over day period
# - traffic limit descending
# - empty last
# tstamp - current time given as argument to get multiple values in specific moment
proc plan-comparator {tstamp a b} {
    if {$a eq ""} { return -1 }
    if {$b eq ""} { return 1 }
    set active_diff [expr {[plan-is-active $tstamp $b] - [plan-is-active $tstamp $a]}]
    if {$active_diff != 0} {
        return $active_diff
    }
    # use direct string compare - lexicographically day sorts before month
    # TODO make it work for period being in {day month <ms>}
    set period_diff [string compare [dict-pop $b timelimit period day] [dict-pop $a timelimit period day]]
    if {$period_diff != 0} {
        return $period_diff
    }
    return [expr {[dict-pop $b trafficlimit quota 0] - [dict-pop $a trafficlimit quota 0]}] 
}
 

proc get-welcome {} {
    try {
        channel {chout cherr} 5
        set success 0
        for {set i 0} {$i < 3 && !$success} {incr i} {
            curl-dispatch $chout $cherr bootstrap:10443 -urlpath /welcome?[this-pcv]
            select {
                <- $chout {
                    set data [<- $chout]
                    puts stderr [log get-welcome received: $data]
                    set success 1
                    # Never call return from select condition
                }
                <- $cherr {
                    set err [<- $cherr]
                    puts stderr [log get-welcome failed with error: $err]
                    # Never call return from select condition
                }
            }
        }
        if {$success} {
            set welcome [json::json2dict $data]
            set now [dict-pop $welcome now ""]
            if {$now ne ""} {
                model now $now
            }
            set latest [dict-pop $welcome latest ""]
            if {[is-dot-ver $latest]} { 
                set ::model::Latest_version $latest
            } else {
                set ::model::Latest_version 0
            }
            set dnscache [dict-pop $welcome dnscache ""]
            if {$dnscache ne ""} {
                set ::model::dns_cache $dnscache
            }
            set loc [dict-pop $welcome loc ""]
            if {$loc ne ""} {
                set ::model::Geo_loc $loc 
            }
            gui-update
        } else {
            # set 'unknown' IP only if all failed and Geo_loc not set in another coroutine
            if {[dict-pop $::model::Geo_loc cc ""] eq ""} {
                set ::model::Geo_loc [dict create ip "    ?     " cc ""]
                gui-update
            }
        }
    } on error {e1 e2} {
        log "$e1 $e2"
    } finally {
        catch {$chout close}
        catch {$cherr close}
    }
}


proc get-external-loc {} {
    try {
        channel {chout cherr} 5
        set success 0
        for {set i 0} {$i < 3 && !$success} {incr i} {
            curl-dispatch $chout $cherr bootstrap:10443 -urlpath /loc?[this-pcv]&as=json
            select {
                <- $chout {
                    set data [<- $chout]
                    puts stderr [log get-external-loc received: $data]
                    set ::model::Geo_loc [json::json2dict $data]
                    gui-update
                    set success 1
                    # Never call return from select condition
                }
                <- $cherr {
                    set err [<- $cherr]
                    puts stderr [log get-external-loc failed with error: $err]
                    # Never call return from select condition
                }
            }
        }
        if {!$success} {
            # set 'unknown' IP only if all failed and Geo_loc not set in another coroutine
            if {[dict-pop $::model::Geo_loc cc ""] eq ""} {
                set ::model::Geo_loc [dict create ip "    ?     " cc ""]
                gui-update
            }
        }
    } on error {e1 e2} {
        log "$e1 $e2"
    } finally {
        catch {$chout close}
        catch {$cherr close}
    }
}

# take list of ip addresses
proc get-bulk-loc {ips} {
    try {
        channel {chout cherr} 5
        if {[llength $ips] == 0} {
            return {}
        }
        set ipfile /tmp/ipfile_[rand-big]
        spit $ipfile [join $ips \n]
        set loc {}
        set success 0
        for {set i 0} {$i < 3 && !$success} {incr i} {
            curl-dispatch $chout $cherr bootstrap:10443 -urlpath /loc?[this-pcv] -method POST -type text/plain -postfromfile $ipfile
            select {
                <- $chout {
                    set data [<- $chout]
                    puts stderr "BULK: $data"
                    set loc [json::json2dict $data]
                    set success 1
                    puts stderr "GEO: $loc"
                    # Never call return from select condition
                }
                <- $cherr {
                    set err [<- $cherr]
                    puts stderr [log get-bulk-loc failed with error: $err]
                    # Never call return from select condition
                }
            }
        }
        return $loc
    } on error {e1 e2} {
        log "$e1 $e2"
        return {}
    } finally {
        catch {$chout close}
        catch {$cherr close}
    }
}

proc update-bulk-loc {profileid} {
    try {
        set ips {}
        dict for {_ plan} [dict-pop $::model::Profiles $profileid plans {}] {
            foreach sitem [dict-pop $plan slist {}] {
                set ip [dict-pop $sitem ip {}]
                if {[is-valid-ip $ip]} {
                    lappend ips $ip
                }
            }
        }
        set loc [get-bulk-loc $ips]

        dict for {planid plan} [dict-pop $::model::Profiles $profileid plans {}] {
            set slist [dict-pop $plan slist {}]
            set slist [rebuild-slist-with-geoloc $slist $loc]
            dict set ::model::Profiles $profileid plans $planid slist $slist
        }
    } on error {e1 e2} {
        puts stderr [log $e1 $e2]
    }
}



proc rebuild-slist-with-geoloc {slist loc} {
    set newslist {}
    set geomap [dict create]
    foreach l $loc {
        dict set geomap [dict-pop $l ip {}] $l
    }
    foreach sitem $slist {
        set newsitem $sitem
        if {[dict-pop $sitem ccode {}] eq ""} {
            set ip [dict-pop $sitem ip {}]
            set geo [dict-pop $geomap $ip {}]
            if {$geo ne ""} {
                set newsitem [dict create]
                dict set newsitem id [dict-pop $sitem id {}]
                dict set newsitem ip [dict-pop $sitem ip {}]
                dict set newsitem ovses [dict-pop $sitem ovses {}]
                dict set newsitem ccode [dict-pop $geo cc {}]
                dict set newsitem country [dict-pop $geo country {}]
                dict set newsitem city [dict-pop $geo city {}]
            }
        }
        lappend newslist $newsitem
    }
    return $newslist
}



proc ovpndir {profileid args} {
    return [file join $::model::PROFILEDIR [name2id $profileid] ovpnconf default {*}$args]
}


# while we can use default welcome message and ovpn config
# the cert must be signed online in order to move forward
proc is-cert-received {profileid} {
    set f [ovpndir $profileid client.crt]
    if {[file exists $f]} {
        return 1
    }
    # handle the case when cert is inlined in the config file - hardcoded paths!
    set f [ovpndir $profileid config_keys cert]
    if {[file exists $f]} {
        return 1
    }
    return 0
}

proc is-config-received {profileid} {
    set f [ovpndir $profileid config.ovpn]
    return [file exists $f]
}




proc curl-dispatch {chout cherr hostport args} {
    if {[string match bootstrap:* $hostport]} {
        curl-retry $chout $cherr -hostports $::model::Hostports -hindex ::model::hostport_lastok -expected_hostname vbox.fruho.com -cadir $::model::CADIR {*}$args
    } else {
        curl-retry $chout $cherr -hostports [lrepeat 3 $hostport] {*}$args
    }
}


proc vpapi-config-direct {profilename host port urlpath username password} {
    try {
        set profileid [name2id $profilename]
        channel {chout cherr} 1
        set f [ovpndir $profileid config.ovpn]
        curl-dispatch $chout $cherr $host:$port -urlpath $urlpath -gettofile $f -basicauth [list $username $password]
        set httpcode ""
        select {
            <- $chout {
                set data [<- $chout]
                puts stderr [log Saved $f]
                # parse config now in order to extract separate cert files
                ::ovconf::parse $f
                # http request succeded so return http OK response code
                set httpcode 200
                # Never call return from select condition
            }
            <- $cherr {
                set err [<- $cherr]
                puts stderr [log vpapi-config-direct failed with error: $err]
                # will return http response code
                set httpcode $err
                # Never call return from select condition
            }
        }
        return $httpcode
    } on error {e1 e2} {
        log "$e1 $e2"
        return 500
    } finally {
        catch {$chout close}
        catch {$cherr close}
    }
}


# this is replacement for the old sign-cert call
proc vpapi-cert-direct {profilename host port urlpath username password} {
    try {
        set profileid [name2id $profilename]
        set csr [ovpndir $profileid client.csr]
        if {![file exists $csr]} {
            log vpapi-cert-direct abandoned because $csr does not exist
            return 0
        }

        channel {chout cherr} 1
        set crt [ovpndir $profileid client.crt]
        curl-dispatch $chout $cherr $host:$port -urlpath $urlpath -method POST -type text/plain -postfromfile $csr -gettofile $crt -basicauth [list $username $password]
        set httpcode ""
        select {
            <- $chout {
                set data [<- $chout]
                puts stderr [log Saved $crt]
                # http request succeded so return http OK response code
                set httpcode 200
                # Never call return from select condition
            }
            <- $cherr {
                set err [<- $cherr]
                puts stderr [log vpapi-cert-direct failed with error: $err]
                # will return http response code
                set httpcode $err
                # Never call return from select condition
            }
        }
        return $httpcode
    } on error {e1 e2} {
        log "$e1 $e2"
        return 500
    } finally {
        catch {$chout close}
        catch {$cherr close}
    }
}

proc vpapi-plans-direct {profilename host port urlpath username password} {
    try {
        channel {chout cherr} 1
        curl-dispatch $chout $cherr $host:$port -urlpath $urlpath -basicauth [list $username $password]
        set httpcode ""
        select {
            <- $chout {
                set data [<- $chout]
                puts stderr [log Received plans JSON: $data]
                set plans [json::json2dict $data]
                set profileid [name2id $profilename]
                dict set ::model::Profiles $profileid plans $plans
                dict set ::model::Profiles $profileid profilename $profilename
                #puts stderr "Profiles: $::model::Profiles"
                set httpcode 200
                # Never call return from select condition
            }
            <- $cherr {
                set err [<- $cherr]
                puts stderr [log vpapi-plans-direct failed with error: $err]
                set httpcode $err
                # Never call return from select condition
            }
        }
        return $httpcode
    } on error {e1 e2} {
        log "$e1 $e2"
        return 500
    } finally {
        catch {$chout close}
        catch {$cherr close}
    }
}



# save main window position and size changes in Config
proc MovedResized {window x y w h} {
    if {$window eq "."} {
        set ::model::layout_x $x
        set ::model::layout_y $y
        set ::model::layout_w $w
        set ::model::layout_h $h
        #puts stderr "$window\tx=$x\ty=$y\tw=$w\th=$h"
    }
}



# Extract new OpenVPN connstatus from fruhod stat report
# update the model and refresh display if status changed
proc conn-status-update {stat} {
    set newstatus [conn-status-reported $stat]
    if {$newstatus ne $::model::Connstatus} {
        set ::model::Connstatus $newstatus
        if {$newstatus eq "connected"} {
            trigger-geo-loc 1000
        }
        gui-update
    }
}

proc faas-config-monitor {} {
    try {
        puts stderr [log faas-config-monitor running]
        tickernow t1 10000 #3
        range t $t1 {
            if {[get-faas-config] == 200} {
                gui-update
                return
            }
        }
        puts stderr [log All faas-config-monitor attempts failed]
    } on error {e1 e2} {
        log "$e1 $e2"
    } finally {
        catch {$t1 close}
    }
}

# get 'fruho as a service' config/plans
proc get-faas-config {} {
    try {
        set username $::model::Cn
        #TODO let the password verify Cn integrity
        set password ""
        # we will call bootstrap servers from hostport list so port is not relevant
        set port 10443

        if {![is-cert-received fruho]} {
            set result [vpapi-cert-direct Fruho bootstrap $port /vpapi/cert?[this-pcv] $username $password]
            if {$result != 200} {
                puts stderr [log "ERROR: vpapi-cert-direct Fruho failed with status $result"]
                return $result
            }
            puts stderr [log vpapi-cert-direct Fruho SUCCESS]
        }
        if {![is-config-received fruho]} {
            set result [vpapi-config-direct Fruho bootstrap $port /vpapi/config?[this-pcv] $username $password]
            if {$result != 200} {
                puts stderr [log "ERROR: vpapi-config-direct Fruho failed with status $result"]
                return $result
            }
            puts stderr [log vpapi-config-direct Fruho SUCCESS]
        }
        if {![dict exists $::model::Profiles fruho plans]} {
            set result [vpapi-plans-direct Fruho bootstrap $port /vpapi/plans?[this-pcv] $username $password]
            if {$result != 200} {
                puts stderr [log "ERROR: vpapi-plans-direct Fruho failed with status $result"]
                return $result
            }
            puts stderr [log vpapi-plans-direct Fruho SUCCESS]
        }
        return 200
    } on error {e1 e2} {
        log "$e1 $e2"
    } finally {
    }
}


# Extract new OpenVPN connstatus from fruhod stat report
proc conn-status-reported {stat} {
    if {$stat eq ""} {
        set connstatus unknown
    } elseif {[dict get $stat ovpn_pid] == 0} {
        set connstatus disconnected
    # model::mgmt_connstatus may store stale value - it is valid only when ovpn_pid is not zero
    } elseif {[dict get $stat mgmt_connstatus] eq "CONNECTED"} {
        set connstatus connected
    } else {
        set connstatus connecting
    }
    return $connstatus
}

proc effective-connstatus {} {
    # this represents fruhod/openvpn connection status
    set status $::model::Connstatus
    # Connstatus_enforced represents status set by GUI controls and may overwrite the connection status
    if {$::model::Connstatus_enforced ne ""} {
        set status $::model::Connstatus_enforced
    }
    return $status
}

# Actually this is a profile tab but let's call it "addprovider" tab
proc is-addprovider-tab-selected {} {
    return [is-addprovider [current-profile]]
}

proc is-addprovider {profile} {
    return [string equal $profile "addvpnprovider"]
}


# state should be normal or disabled
proc profile-tabset-update {} {
    set all_tabs [.c.tabsetenvelope.nb tabs]
    foreach tab $all_tabs {
        set profile [lindex [split $tab .] end]
        .c.tabsetenvelope.nb tab $tab -state [profile-tab-stand $profile]
    }
}

proc profile-tab-stand {profileid} {
    if {$profileid eq "addvpnprovider"} {
        return normal
    }
    if {[is-connecting-status]} {
        if {$profileid ne [connecting-profile]} {
            return disabled
        }
    }
    return normal
}

# return profileid of currently connecting or connected profile or empty string otherwise
proc connecting-profile {} {
    if {[is-connecting-status]} {
        return [dict-pop $::model::Current_sitem profile ""]
    } else {
        return ""
    }
}

# actually "connecting" or "connected"
proc is-connecting-status {} {
    set status [effective-connstatus]
    return [expr {$status eq "connected" || $status eq "connecting"}]
}

# stand is widget status calculated from the model
proc connect-button-stand {} {
    if {[is-addprovider-tab-selected]} {
        return disabled
    }
    # CSR not completed yet - disable buttons
    if {![is-cert-received [current-profile]] || ![is-config-received [current-profile]]} {
        return disabled
    }
    set status [effective-connstatus]
    switch $status {
        unknown {set state disabled}
        disconnected {set state normal}
        connecting {set state disabled}
        connected {set state disabled}
        default {set state disabled}
    }
    return $state
}


# stand is widget status calculated from the model
proc disconnect-button-stand {} {
    # In case of Disconnect button on addprovider tab apply the full connstatus logic
    if {![is-addprovider-tab-selected]} {
        # These checks make sense only when real profile selected
        # CSR not completed yet - disable buttons
        if {![is-cert-received [current-profile]] || ![is-config-received [current-profile]]} {
            return disabled
        }
    }
    set status [effective-connstatus]
    switch $status {
        unknown {set state disabled}
        disconnected {set state disabled}
        connecting {set state normal}
        connected {set state normal}
        default {set state disabled}
    }
    return $state
}




# stand is widget status calculated from the model
proc slist-button-stand {} {
    if {[is-addprovider-tab-selected]} {
        return disabled
    }
    return normal
}

proc connect-flag-stand {} {
    set cc [dict-pop $::model::Geo_loc cc EMPTY]
    if {$cc eq ""} {
        set cc EMPTY
    }
    return $cc
}

proc connect-image-stand {} {
    set status [effective-connstatus]
    return $status
}

proc connect-msg-stand {} {
    set status [effective-connstatus]
    set city [dict-pop $::model::Current_sitem city ?]
    set ccode [dict-pop $::model::Current_sitem ccode ?]
    switch $status {
        unknown         {set msg [_ "Unknown"]}
        disconnected    {set msg [_ "Disconnected"]}
        connecting      {
            if {$city ne "" && $ccode ne ""} {
                set msg [_ "Connecting to {0}, {1}, port {2}" $city $ccode $::model::Current_protoport]
            } else {
                set msg [_ "Connecting"]
            }
        }
        connected       {
            if {$city ne "" && $ccode ne ""} {
                set msg [_ "Connected to {0}, {1}, port {2}" $city $ccode $::model::Current_protoport]
            } else {
                set msg [_ "Connected"]
            }
        }
        default         {set msg [_ "Unknown"]}
    }
    return $msg
}

proc externalip-stand {} {
    return [dict-pop $::model::Geo_loc ip ""]
}


proc gui-update {} {
    try {
        img place 32/status/[connect-image-stand] .c.stat.imagestatus
        img place 64/flag/[connect-flag-stand] .c.stat.flag 64/flag/EMPTY
        set externalip [externalip-stand]
        if {$externalip eq ""} {
            img place 16/connecting .c.inf.externalip
            .c.inf.externalip configure -text "                  "
        } else {
            img place 16/empty .c.inf.externalip
            .c.inf.externalip configure -text $externalip
        }
        .c.bs.connect configure -state [connect-button-stand]
        .c.bs.disconnect configure -state [disconnect-button-stand]
        .c.bs.slist configure -state [slist-button-stand]
        .c.stat.status configure -text [connect-msg-stand]
        profile-tabset-update
        set now [model now]
        dash-plan-update $now
        dash-time-update $now
        dash-gauge-update
    } on error {e1 e2} {
        puts stderr [log "$e1 $e2"]
    }
}

proc usage-meter-update-blank {} {
    set um .c.tabsetenvelope.nb.[current-profile].um
    set ::model::Gui_planline [_ "Plan ?"]
    set ::model::Gui_usedlabel [_ "Used"]
    set ::model::Gui_elapsedlabel [_ "Elapsed"]
    set ::model::Gui_usedsummary ""
    set ::model::Gui_elapsedsummary ""
    $um.usedbar.fill configure -width 0
    $um.elapsedbar.fill configure -width 0
}


# TODO add different types of usage meter
proc usage-meter-update {tstamp} {
    try {
        set profile [current-profile]
        set um .c.tabsetenvelope.nb.$profile.um
        set planid [current-planid $tstamp $profile]
        if {$planid eq ""} {
            usage-meter-update-blank
            return
        }
        set plan [dict get $::model::Profiles $profile plans $planid]
        set planname [dict-pop $plan name ?]
        set plan_start [plan-start $plan]
        set plan_end [plan-end $plan]
        set until [format-date $plan_end]
        set period [dict-pop $plan timelimit period day]
        if {$period eq "month"} {
            set ::model::Gui_usedlabel [_ "This month used"]
            set ::model::Gui_elapsedlabel [_ "This month elapsed"]
            set ::model::Gui_planline [_ "Plan {0} valid until {1}" $planname $until]
        } elseif {$period eq "day"} {
            set ::model::Gui_usedlabel [_ "This day used"]
            set ::model::Gui_elapsedlabel [_ "This day elapsed"]
            set ::model::Gui_planline [_ "Plan {0}" $planname]
        #TODO need one more else for period in milliseconds
        } else {
            usage-meter-update-blank
            return
        }
        
        set used [dict-pop $plan trafficlimit used 0]
        set quota [dict-pop $plan trafficlimit quota 0]
        if {$quota <= 0} {
            usage-meter-update-blank
            return
        }
        if {$used > $quota} {
            set used $quota
        }
        if {$used < 0} {
            usage-meter-update-blank
            return
        }
        set ::model::Gui_usedsummary "[format-mega $used] / [format-mega $quota 1]"
        set period_start [period-start $plan $tstamp]
        set period_end [period-end $plan $tstamp]
        #puts stderr "plan_start: [clock format $plan_start]"
        #puts stderr "period_start: [clock format $period_start]"
        #puts stderr "period_end: [clock format $period_end]"
        set period_elapsed [period-elapsed $plan $tstamp]
        set period_length [period-length $plan $tstamp]
        if {$period_elapsed <= 0} {
            usage-meter-update-blank
            return
        }
        if {$period_length <= 0} {
            usage-meter-update-blank
            return
        }
        if {$period_elapsed > $period_length} {
            set period_elapsed $period_length
        }
        set ::model::Gui_elapsedsummary "[format-interval $period_elapsed] / [format-interval $period_length 1]"
    
        ##################################
        # update bars
    
        set barw $::model::layout_barw
        set wu [expr {$barw * $used / $quota}]
        if {$wu < 0} {
        }
        $um.usedbar.fill configure -width $wu
        set we [expr {$barw * $period_elapsed / $period_length}]
        $um.elapsedbar.fill configure -width $we
    } on error {e1 e2} {
        log "$e1 $e2"
    }
}



# convert big number to the suffixed (K/M/G/T) representation 
# with max 3 significant digits plus optional dot
# trim - trim the decimal part if zero
# return pair {value unit}
proc format-mega {n {trim 0}} {
    # number length
    set l [string length $n]
    # 3 digits to display
    set d [string range $n 0 2]
    if {$l > 12} {
        set suffix T
    } elseif {$l > 9} {
        set suffix G
    } elseif {$l > 6} {
        set suffix M
    } elseif {$l > 3} {
        set suffix k
    } else {
        set suffix ""
    }
    # position of the dot
    set p [expr {$l % 3}]
    if {$suffix ne "" && $p > 0} {
        set d [string-insert $d $p .]
        if {$trim} {
            while {[string index $d end] eq "0"} {
                set d [string range $d 0 end-1]
            }
            if {[string index $d end] eq "."} {
                set d [string range $d 0 end-1]
            }
        }
    }
    return [list $d $suffix]
}


# trim - trim the minor unit
proc format-interval {sec {trim 0}} {
    set min [expr {$sec/60}]
    # if more than 24 hour
    if {$min > 1440} {
        set days [expr {$min/1440}]
        set hours [expr {($min-$days*1440)/60}]
        if {$trim} {
            return "${days}d"
        } else {
            return "${days}d ${hours}h"
        }
    } else {
        set hours [expr {$min/60}]
        set minutes [expr {$min-($hours*60)}]
        if {$trim} {
            return "${hours}h"
        } else {
            return "${hours}h ${minutes}m"
        }
    }
}

proc format-date {sec} {
    return [clock format $sec -format "%Y-%m-%d"]
}



proc frame-dashboard {p} {
    dash-plan $p
    dash-time $p
    dash-gauge $p
}

proc dash-plan {p} {
    set dbplan [frame $p.dbplan]
    frame $dbplan.planname
    label $dbplan.planname.lbl -text "Plan:"
    label $dbplan.planname.val -font [dynafont -weight bold]
    grid $dbplan.planname.lbl -row 0 -column 0 -sticky w
    grid $dbplan.planname.val -row 0 -column 1 -sticky w

    frame $dbplan.planexpiry
    label $dbplan.planexpiry.lbl
    label $dbplan.planexpiry.val -font [dynafont -weight bold]
    grid $dbplan.planexpiry.lbl -row 0 -column 0 -sticky e
    grid $dbplan.planexpiry.val -row 0 -column 1 -sticky e
 
    grid columnconfigure $dbplan 0 -weight 1
    grid columnconfigure $dbplan 1 -weight 1
    grid $dbplan.planname -row 1 -column 0 -sticky w
    grid $dbplan.planexpiry -row 1 -column 1 -sticky e
    grid $dbplan -padx 10 -pady 10 -sticky news
}

proc dash-time {p} {
    set bg3 $::model::layout_bg3
    set fgelapsed $::model::layout_fgelapsed
    set barw $::model::layout_barw
    set barh $::model::layout_barh

    set dbtime [frame $p.dbtime]

    label $dbtime.elapsedlabel -text "Timeline:" ;#-background #bbbbbb 
    frame $dbtime.elapsedbar -background $bg3 -width $barw -height $barh
    frame $dbtime.elapsedbar.fill -background $fgelapsed -width 0 -height $barh
    place $dbtime.elapsedbar.fill -x 0 -y 0
    label $dbtime.elapsedsummary ;#-background #bbbbbb
    grid $dbtime.elapsedlabel $dbtime.elapsedbar $dbtime.elapsedsummary -row 2 -padx 5 -pady 5 -sticky w
    grid $dbtime

}


proc dash-gauge {p} {
    set db [frame $p.db]

    set font1 [dynafont -size 14]
    set font2 [dynafont -size 20]

    set gaugebg #eeeeee
    set gaugew 100
    set gaugeh 10

    # header
    label $db.linkdir
    label $db.speedgaugelabel
    label $db.speedlabel -text "Speed" -anchor e -font $font1
    label $db.speedlabelunit
    label $db.trafficlabel -text "Traffic" -anchor e -font $font1
    label $db.trafficlabelunit
   
    # up row
    label $db.linkup -image [img load 32/uplink] -anchor e
    frame $db.speedupgauge -background $gaugebg -width $gaugew -height $gaugeh
    frame $db.speedupgauge.fill -height $gaugeh
    place $db.speedupgauge.fill -x 0 -y 0
    label $db.speedup -text "0" -anchor e -font $font2 
    label $db.speedupunit -text "kbps" -anchor w -font $font1
    label $db.trafficup -text "0" -anchor e -font $font2
    label $db.trafficupunit -text "MB" -anchor w -font $font1

    # down row
    label $db.linkdown -image [img load 32/downlink] -anchor e
    frame $db.speeddowngauge -background $gaugebg -width $gaugew -height $gaugeh
    frame $db.speeddowngauge.fill -height $gaugeh
    place $db.speeddowngauge.fill -x 0 -y 0
    label $db.speeddown -text "0" -anchor e -font $font2
    label $db.speeddownunit -text "kbps" -anchor w -font $font1
    label $db.trafficdown -text "0" -anchor e -font $font2
    label $db.trafficdownunit -text "MB" -anchor w -font $font1

    set col -1
    grid $db.linkdir -row 1 -column [incr col] -sticky news -padx 10 -pady 5
    grid $db.speedgaugelabel -row 1 -column [incr col] -sticky news -padx 10 -pady 5
    grid $db.speedlabel -row 1 -column [incr col] -sticky news -padx 10 -pady 5
    grid $db.speedlabelunit -row 1 -column [incr col] -sticky news -pady 5
    grid $db.trafficlabel -row 1 -column [incr col] -sticky news -padx 10 -pady 5
    grid $db.trafficlabelunit -row 1 -column [incr col] -sticky news -pady 5

    set col -1
    grid $db.linkup -row 3 -column [incr col] -sticky news -padx 10 -pady 5
    grid $db.speedupgauge -row 3 -column [incr col] -sticky w -padx 10 -pady 5
    grid $db.speedup -row 3 -column [incr col] -sticky news -padx 10 -pady 5
    grid $db.speedupunit -row 3 -column [incr col] -sticky news -pady 5
    grid $db.trafficup -row 3 -column [incr col] -sticky news -padx 10 -pady 5
    grid $db.trafficupunit -row 3 -column [incr col] -sticky news -pady 5

    set col -1
    grid $db.linkdown -row 5 -column [incr col] -sticky news -padx 10 -pady 5
    grid $db.speeddowngauge -row 5 -column [incr col] -sticky w -padx 10 -pady 5
    grid $db.speeddown -row 5 -column [incr col] -sticky news -padx 10 -pady 5
    grid $db.speeddownunit -row 5 -column [incr col] -sticky news -pady 5
    grid $db.trafficdown -row 5 -column [incr col] -sticky news -padx 10 -pady 5
    grid $db.trafficdownunit -row 5 -column [incr col] -sticky news -pady 5

    set col -1
    grid columnconfigure $db [incr col] -minsize 40
    grid columnconfigure $db [incr col] -minsize 100
    grid columnconfigure $db [incr col] -minsize 100
    grid columnconfigure $db [incr col] -minsize 70
    grid columnconfigure $db [incr col] -minsize 100
    grid columnconfigure $db [incr col] -minsize 70

    grid $db -padx 10 -sticky n
}



proc dash-plan-update {tstamp} {
    set profileid [current-profile]
    if {[is-addprovider-tab-selected]} {
        return
    }
    set dbplan .c.tabsetenvelope.nb.$profileid.dbplan

    if {[winfo exists $dbplan]} {
        set planid [current-planid $tstamp $profileid]
        set plan [dict-pop $::model::Profiles $profileid plans $planid {}]
        set planname [dict-pop $plan name UNKNOWN]
        set plan_start [plan-start $plan]
        set plan_end [plan-end $plan]
        set until [format-date $plan_end]
        set expires "Expires:"
        set period [dict-pop $plan timelimit period day]
        $dbplan.planname.val configure -text $planname
        # if longer than 10 years
        if {$plan_end - $plan_start > 315000000} {
            set until ""
            set expires ""
        }
        $dbplan.planexpiry.lbl configure -text $expires
        $dbplan.planexpiry.val configure -text $until
    }
}

proc dash-time-update {tstamp} {
    set profileid [current-profile]
    if {[is-addprovider-tab-selected]} {
        return
    }
    set dbtime .c.tabsetenvelope.nb.$profileid.dbtime

    if {[winfo exists $dbtime]} {
        set planid [current-planid $tstamp $profileid]
        set plan [dict-pop $::model::Profiles $profileid plans $planid {}]
        set period_start [period-start $plan $tstamp]
        set period_end [period-end $plan $tstamp]
        set period_elapsed [period-elapsed $plan $tstamp]
        set period_length [period-length $plan $tstamp]
        if {$period_elapsed > 0 && $period_length > 0 && $period_elapsed > $period_length} {
            set period_elapsed $period_length
        }
        set barw $::model::layout_barw
        set summary ""
        set we 0
        if {$period_elapsed > 0 && $period_length > 0} {
            set summary "[format-interval $period_elapsed] / [format-interval $period_length 1]"
            set we [expr {$barw * $period_elapsed / $period_length}]
        }
        $dbtime.elapsedbar.fill configure -width $we
        $dbtime.elapsedsummary configure -text $summary
    }
}


proc dash-gauge-update {} {
    if {[is-addprovider-tab-selected]} {
        return 
    }
    set profileid [current-profile]
    set db .c.tabsetenvelope.nb.$profileid.db

    if {[winfo exists $db]} {
        lassign [traffic-speed-calc] trafficup trafficdown speedup speeddown
        set speedup_f [format-mega $speedup]
        $db.speedup configure -text [lindex $speedup_f 0]
        $db.speedupunit configure -text [lindex $speedup_f 1]B/s
        set speeddown_f [format-mega $speeddown]
        $db.speeddown configure -text [lindex $speeddown_f 0]
        $db.speeddownunit configure -text [lindex $speeddown_f 1]B/s
    
        lassign [speed-gauge-calc $speedup 2000000 100] width rgb
        #puts stderr "speedup $speedup   width $width    rgb: $rgb"
        $db.speedupgauge.fill configure -background $rgb -width $width
    
        set trafficup_f [format-mega $trafficup]
        $db.trafficup configure -text [lindex $trafficup_f 0]
        $db.trafficupunit configure -text [lindex $trafficup_f 1]B
        set trafficdown_f [format-mega $trafficdown]
        $db.trafficdown configure -text [lindex $trafficdown_f 0]
        $db.trafficdownunit configure -text [lindex $trafficdown_f 1]B
    
        lassign [speed-gauge-calc $speeddown 2000000 100] width rgb
        #puts stderr "speeddown $speeddown   width $width    rgb: $rgb"
        $db.speeddowngauge.fill configure -background $rgb -width $width
    }
}


# return tuple of width and RGB color value
proc speed-gauge-calc {current_value max_value max_width} {
    # transformation function - linear here, may be logarithmic
    # Ignore small values, start from value 100
    set y [expr {round(1000 * (log10($current_value + 100) - 2))}]
    set maxy [expr {round(1000 * (log10($max_value + 100) - 2))}]

    set width [expr {$max_width * $y / $maxy}]
    if {$width < 0} {
        set width 0
    }
    if {$width > $max_width} {
        set width $max_width
    }
    set r [expr {min(255, 512 * $width / $max_width)}]
    set g [expr {min(255, 512 - 512 * $width / $max_width)}]
    return [list $width [format "#%02x%02x00" $r $g]]
}




# create usage meter in parent p
proc frame-usage-meter {p} {
    set bg1 $::model::layout_bg1
    set bg3 $::model::layout_bg3
    set fgused $::model::layout_fgused
    set fgelapsed $::model::layout_fgelapsed
    set um [frame $p.um -background $bg1]
    ttk::label $um.plan -textvariable ::model::Gui_planline -background $bg1
    ttk::label $um.usedlabel -textvariable ::model::Gui_usedlabel -background $bg1 -width 15
    set barw $::model::layout_barw
    set barh $::model::layout_barh
    frame $um.usedbar -background $bg3 -width $barw -height $barh
    frame $um.usedbar.fill -background $fgused -width 0 -height $barh
    place $um.usedbar.fill -x 0 -y 0
    grid columnconfigure $um.usedbar 0 -weight 1
    #ttk::label $um.usedsummary -text "12.4 GB / 50 GB" -background $bg1
    ttk::label $um.usedsummary -textvariable ::model::Gui_usedsummary -background $bg1 -width 15
    ttk::label $um.elapsedlabel -textvariable ::model::Gui_elapsedlabel -background $bg1 -width 15
    frame $um.elapsedbar -background $bg3 -width $barw -height $barh
    frame $um.elapsedbar.fill -background $fgelapsed -width 0 -height $barh
    place $um.elapsedbar.fill -x 0 -y 0
    #ttk::label $um.elapsedsummary -text "3 days 14 hours / 31 days" -background $bg1
    ttk::label $um.elapsedsummary -textvariable ::model::Gui_elapsedsummary -background $bg1 -width 15
    grid $um.plan -column 0 -row 0 -columnspan 3 -padx 5 -pady 5 -sticky w
    grid $um.usedlabel $p.um.usedbar $p.um.usedsummary -row 1 -padx 5 -pady 5 -sticky w
    grid $um.elapsedlabel $p.um.elapsedbar $p.um.elapsedsummary -row 2 -padx 5 -pady 5 -sticky w
    grid $um -padx 10 -sticky news
    return $um
}


proc frame-toolbar {p} {
    set tb [ttk::frame $p.tb -borderwidth 0 -relief raised]
    #ttk::button $tb.feedback
    #img place 16/feedback  $tb.feedback 
    #grid $tb.feedback -column 0 -row 0 -sticky w
    label $tb.appealimg
    img place 16/bang $tb.appealimg
    label $tb.appeal1 -text "Help improve this program. Provide your"
    hyperlink $tb.appeal2 -command [list launchBrowser "https://fruho.com/geo"] -text "feedback."
    label $tb.appeal3 -text "We listen."

    button $tb.options -relief flat -command OptionsClicked
    img place 24/options  $tb.options
    grid $tb.appealimg -column 0 -row 0 -sticky w
    grid $tb.appeal1 -column 1 -row 0 -sticky w
    grid $tb.appeal2 -column 2 -row 0 -sticky w
    grid $tb.appeal3 -column 3 -row 0 -sticky w
    grid $tb.options -column 4 -row 0 -sticky e
    grid $tb -padx 5 -sticky news
    grid columnconfigure $tb $tb.options -weight 1
    return $tb
}



# create ip info panel in parent p
proc frame-ipinfo {p} {
    set bg2 $::model::layout_bg2
    set inf [frame $p.inf -background $bg2]
    ttk::label $inf.externaliplabel -text [_ "Your IP:"] -background $bg2
    label $inf.externalip -background $bg2 -compound center
    hyperlink $inf.geocheck -image [img load 16/external] -background $bg2 -command [list launchBrowser "https://fruho.com/geo"]
    grid $inf.externaliplabel -column 0 -row 2 -padx 10 -pady 5 -sticky e
    grid $inf.externalip -column 1 -row 2 -padx 0 -pady 5 -sticky e
    grid $inf.geocheck -column 2 -row 2 -padx 5 -pady 5 -sticky e
    grid columnconfigure $inf $inf.externaliplabel -weight 1
    grid columnconfigure $inf $inf.externalip -minsize 120
    grid $inf -padx 10 -sticky news
    return $inf
}

proc frame-status {p} {
    set bg2 $::model::layout_bg2
    set stat [frame $p.stat -background $bg2]
    # must use non-ttk label for proper animated gif display
    label $stat.imagestatus -background $bg2
    ttk::label $stat.status -text "" -background $bg2
    ttk::label $stat.flag -background $bg2
    img place 64/flag/EMPTY $stat.flag
    grid $stat.imagestatus -row 5 -column 0 -padx 10 -pady 5
    grid $stat.status -row 5 -column 1 -padx 10 -pady 5 -sticky w
    grid $stat.flag -row 5 -column 2 -padx 40 -pady 5 -sticky e
    grid columnconfigure $stat $stat.status -weight 1
    grid $stat -padx 10 -sticky news
    return $stat
}

proc frame-buttons {p} {
    set bs [ttk::frame $p.bs]
    button $bs.connect -font [dynafont -size 12] -compound left -image [img load 24/connect] -text [_ "Connect"] -command ClickConnect ;# _2eaf8d491417924c
    button $bs.disconnect -font [dynafont -size 12] -compound left -image [img load 24/disconnect] -text [_ "Disconnect"] -command ClickDisconnect ;# _87fff3af45753920
    button $bs.slist -font [dynafont -size 12] -compound left -image [img load 24/servers] -text [_ "Servers"] -command ServerListClicked ;# _bf9c42ec59d68714
    grid $bs.connect -row 0 -column 0 -padx 10 -sticky w
    grid $bs.disconnect -row 0 -column 1 -padx 10 -sticky w
    grid $bs.slist -row 0 -column 2 -padx 10 -sticky e
    grid columnconfigure $bs $bs.slist -weight 1
    grid $bs -sticky news
    focus $bs.slist
    return $bs
}

proc dynafont {args} {
    memoize
    set name font[join $args]
    if {$name ni [font names]} {
        font create $name {*}[font actual TkDefaultFont]
        font configure $name {*}$args
    }
    return $name
}


proc tabset-profiles {p} {
    set nb $p.nb
    catch {destroy $nb}
    ttk::notebook $nb
    ttk::notebook::enableTraversal $nb
    bind $nb <<NotebookTabChanged>> [list ProfileTabChanged $nb]
    foreach profileid [model active-profiles] {
        set tab [frame-profile $nb $profileid]
        set pdict [dict get $::model::Profiles $profileid]
        set tabname [dict-pop $pdict profilename $profileid]
        $nb add $tab -text $tabname -sticky news
    }
    $nb add [frame-addvpnprovider $nb] -text "Add VPN Provider..."
    grid $nb -sticky news -padx 10 -pady 10 
    select-profile $nb
    set now [model now]
    dash-plan-update $now
    dash-time-update $now
    return $nb
}

proc select-profile {nb} {
    set candidate $nb.$::model::selected_profile
    foreach tab [$nb tabs] {
        if {$tab eq $candidate} {
            $nb select $candidate
            return
        }
    }
    # otherwise select first tab and save in the model
    set first [lindex [$nb tabs] 0]
    set ::model::selected_profile [lindex [split $first .] end]
    $nb select $first
}

proc ProfileTabChanged {nb} {
    set profileid [lindex [split [$nb select] .] end]
    set ::model::selected_profile $profileid
    if {![is-addprovider-tab-selected]} {
        #usage-meter-update [model now]
    }
    gui-update
}




proc frame-addvpnprovider {p} {
    set tab [ttk::frame $p.addvpnprovider]
    ttk::label $tab.addheader -text "Import configuration from the existing account with your VPN provider"
    grid $tab.addheader -row 0 -column 0 -columnspan 2 -sticky news -padx 10 -pady {10 0}


    set plist $tab.treeview
    ttk::treeview $plist -columns ### -selectmode browse -show tree -height 4
    bind $plist <<TreeviewSelect>> [list ProviderListSelected $tab]
    $plist column #0 -width 50 -anchor nw -stretch 0
    $plist column 0 -width 140 -anchor w

    foreach provider [dict keys $::model::Supported_providers] {
        $provider add-to-treeview-plist $plist
        $provider create-import-frame $tab
    }
    grid $plist -row 3 -column 0 -sticky news -padx 10 -pady 10
    grid rowconfigure $tab $plist -weight 1
    grid columnconfigure $tab $plist -weight 0
    grid columnconfigure $tab 1 -weight 1
#    grid columnconfigure $tab 1 -weight 5

    # select first item in the treeview
    $plist selection set [lindex [$plist children {}] 0]

    return $tab
}

proc ProviderListSelected {tab} {
    set provider [$tab.treeview selection]
    set slaves [grid slaves $tab -row 3 -column 1]
    foreach slave $slaves {
        grid remove $slave
    }
    grid $tab.$provider -row 3 -column 1 -sticky news -padx 10 -pady 10
}


proc window-sibling {w name} {
    set parent [join [lrange [split $w .] 0 end-1] .]
    return $parent.$name
}


# For example: .c.tabsetenvelope.nb.<profilename>
proc current-tab-frame {} {
    return [.c.tabsetenvelope.nb select]
}


# returns plain lowercase profile id
proc current-profile {} {
    set current [lindex [split [current-tab-frame] .] end]
    return $current
}

# return profile frame window
proc frame-profile {p pname} {
    set f [frame $p.$pname]
    grid columnconfigure $f 0 -weight 1
    # TODO here dispatch to different dashboard views
    #frame-usage-meter $f
    frame-dashboard $f
    return $f
}

proc unique-profilename {basename} {
    set i 0
    set profilename $basename
    while 1 {
        set profileid [name2id $profilename]
        if {[is-profileid-available $profileid]} {
            return $profilename
        }
        incr i 
        set profilename "$basename $i"
    }
}

proc is-profileid-available {profileid} {
    return [expr {$profileid ni [dict keys $::model::Profiles] && $profileid ni $::model::removed_profiles}]
}


# convert human friendly name into unique, no-whitespace, lowercase id
# applicable to profile names and supported provider names
proc name2id {profilename} {
    set profileid [join [split $profilename] _]
    set profileid [string tolower $profileid]
    return $profileid
}


proc InvokeFocusedWithEnter {} {
    set focused [focus]
    if {$focused eq ""} {
        return
    }
    set type [winfo class $focused]
    switch -glob $type {
        *Button {
            # this matches both Button and TButton
            $focused invoke
        }
        Treeview {
            puts stderr "selected: [$focused selection]"
        }
    }
}


proc setDialogSize {window} {
    #TODO check if layout in Config and if values make sense
    #TODO when layout in Config don't do updates from package manager
    # if layout not in Config we must determine size from package manager
    # this update will ensure that winfo will return the correct sizes
    update
    # get the current width and height as set by grid package manager
    set w [winfo width $window]
    set h [expr {[winfo height $window] + 10}]
    # set it as the minimum size
    wm minsize $window $w $h
    if {$::model::layout_w == 0} {
        set ::model::layout_w $w
    }
    if {$::model::layout_h == 0} {
        set ::model::layout_h $h
    }
    set cw $::model::layout_w
    set ch $::model::layout_h
    set cx $::model::layout_x
    set cy $::model::layout_y

    wm geometry $window ${cw}x${ch}+${cx}+${cy}
}

proc CheckForUpdatesClicked {uframe} {
    try {
        set about .options_dialog.nb.about
        $about.checkforupdates configure -state disabled
        checkforupdates-status $uframe 16/connecting "Checking for updates"
        go check-for-updates $uframe
    } on error {e1 e2} {
        log "$e1 $e2"
    }
}

proc checkforupdates-status {uframe img msg} {
    try {
        $uframe.status configure -text "  $msg"
        img place $img $uframe.status
    } on error {e1 e2} {
        log "$e1 $e2"
    }
} 


# Three possible outcomes: 
# -The program is up to date
# -New version XXX available
# -No updates found (connection problem) 
# uframe - it is passed to update the correct widget
# quiet - display message only if we already know that the program out of date
proc checkforupdates-refresh {uframe quiet} {
    try {
        if {![winfo exists $uframe]} {
            return
        }
        set latest $::model::Latest_version
        if {$quiet} {
            if {$latest ne "0" && [is-dot-ver $latest]} {
                if {[int-ver $latest] > [int-ver [build-version]]} {
                    checkforupdates-status $uframe 16/attention "New version $latest is available"
                    grid $uframe.button
                    return
                }
            }
            checkforupdates-status $uframe 16/empty ""
            return
        } else {
            if {$latest ne "0" && [is-dot-ver $latest]} {
                if {[int-ver $latest] > [int-ver [build-version]]} {
                    checkforupdates-status $uframe 16/attention "New version $latest is available"
                    grid $uframe.button
                } else {
                    checkforupdates-status $uframe 16/tick "The program is up to date"
                }
            } else {
                checkforupdates-status $uframe 16/question "No updates found"
            }
        }
    } on error {e1 e2} {
        log "$e1 $e2"
    }
}


proc UpdateNowClicked {uframe} {
    try {
        set about .options_dialog.nb.about
        $uframe.button configure -state disabled

        set version $::model::Latest_version
        if {[int-ver $version] <= [int-ver [build-version]]} {
            return
        }

        set dir [file join $::model::UPGRADEDIR $version]
        file mkdir $dir
        set platform [this-os]-[this-arch]
        set files {fruho.bin.sig fruhod.bin.sig fruho.bin fruhod.bin}
        # csp channel for collecting info about downloaded files
        channel collector
        if {![files-exist $files]} {
            checkforupdates-status $uframe 16/downloading "Downloading..."
            foreach f $files {
                set filepath [file join $dir $f]
                go download-latest-skt $collector /latest-skt/$version/$platform/$f $filepath
            }
            # given timeout is per item
            go wait-for-items $collector [llength $files] 60000 [list upgrade-downloaded $dir $uframe]
        } else {
            upgrade-downloaded $dir $uframe ok
        }
    } on error {e1 e2} {
        log "$e1 $e2"
    }
}

# fruhod only to verify signature and replace binaries and restart itself
# fruho client prepares upgrade dir, initializes upgrade and restarts itself
proc upgrade-downloaded {dir uframe status} {
    log upgrade-downloaded $status
    if {$status eq "ok"} { 
        checkforupdates-status $uframe 16/updating "Updating..."
        # give 5 seconds to restart itself, otherwise report update failed
        after 5000 [list checkforupdates-status $uframe 16/warning "Update failed"]
        puts stderr "PREPARE UPGRADE from $dir"
        ffwrite "upgrade $dir"
        puts stderr "UPGRADING from $dir"
    } else {
        checkforupdates-status $uframe 16/error "Problem with the download"
    }
           
}

# csp coroutine to collect messages from collector channel
# if $n items received within individual $timeouts
# then call "$command ok". Otherwise "$command timeout"
proc wait-for-items {collector n timeout command} {
    try {
        for {set i 0} {$i < $n} {incr i} {
            timer t $timeout
            select {
                <- $collector {
                    set item [<- $collector]
                    log "wait-for-items collected item=$item for n=$n timeout=$timeout command=$command"
                }
                <- $t {
                    log "wait-for-items timed out for n=$n timeout=$timeout command=$command"
                    <- $t
                    {*}$command timeout
                    return
                }
            }
        }
        log "wait-for-items completed successfully for n=$n timeout=$timeout command=$command"
        {*}$command ok
        return
    } on error {e1 e2} {
        log "$e1 $e2"
    } finally {
        catch {
            $collector close
        }
    }
}



proc download-latest-skt {collector url filepath} {
    try {
        channel {chout cherr} 1
        # wget the binary
        curl-dispatch $chout $cherr bootstrap:10443 -urlpath $url -gettofile $filepath
        log "download-latest-skt started $url $filepath"
        select {
            <- $chout {
                <- $chout
                $collector <- $filepath
                puts stderr [log "download-latest-skt $url $filepath OK"]
            }
            <- $cherr {
                set err [<- $cherr]
                puts stderr [log "download-latest-skt $url $filepath ERROR: $err"]
            }
        }
    } on error {e1 e2} {
        log "$e1 $e2"
    } finally {
        catch {
            $chout close
            $cherr close
        }
    }
}


proc OptionsClicked {} {
    try {
        set w .options_dialog
        catch { destroy $w }
        toplevel $w ;#-width 400 -height 400
    
    
        set nb [ttk::notebook $w.nb]
    
        #####################################################
        # About tab
        #
        ttk::frame $nb.about
        label $nb.about.desc -text "Fruho - Universal VPN client" -font [dynafont -weight bold]
        label $nb.about.userid1 -text "User ID:"
        label $nb.about.userid2 -text $::model::Cn
        label $nb.about.buildver1 -text "Program version:"
        label $nb.about.buildver2 -text [build-version]
        label $nb.about.builddate1 -text "Build date:"
        label $nb.about.builddate2 -text [build-date]
    
        # this widget needs to have unique id which is passed through button events to status update label
        set update_id [rand-big]
        set uframe $nb.about.updateframe$update_id
    
        button $nb.about.checkforupdates -text "Check for updates" -command [list CheckForUpdatesClicked $uframe]
    
        ttk::frame $uframe
        label $uframe.status -compound left
        button $uframe.button -text "Update now" -command [list UpdateNowClicked $uframe]
        #hyperlink $nb.about.website -command [list launchBrowser "https://fruho.com"] -text "Copyright \u00A9 fruho.com"
        grid $nb.about.desc -row 0 -padx 10 -pady 5 -columnspan 2
        grid $nb.about.userid1 -row 1 -column 0 -sticky w -padx 10 -pady 5
        grid $nb.about.userid2 -row 1 -column 1 -sticky w -padx 10 -pady 5
        grid $nb.about.buildver1 -row 2 -column 0 -sticky w -padx 10 -pady 5
        grid $nb.about.buildver2 -row 2 -column 1 -sticky w -padx 10 -pady 5
        grid $nb.about.builddate1 -row 4 -column 0 -sticky w -padx 10 -pady 5
        grid $nb.about.builddate2 -row 4 -column 1 -sticky w -padx 10 -pady 5
        grid $nb.about.checkforupdates -column 1 -sticky e -padx 10 -pady 5
        grid $uframe -row 7 -sticky news -padx 10 -pady 5 -columnspan 2 
        grid $uframe.status -row 0 -column 0 -sticky w
        grid $uframe.button -row 0 -column 1 -sticky e -padx {40 0}
        #grid $nb.about.website -row 9 -padx 10 -pady 5 -columnspan 2
        grid columnconfigure $nb.about 0 -weight 1 -minsize 200
        grid columnconfigure $uframe 0 -weight 1
        grid rowconfigure $uframe 0 -weight 1 -minsize 40
        grid remove $uframe.button
    
    
        #####################################################
        # Connection tab
        #
        frame $nb.connection
        label $nb.connection.info -text "OpenVPN connection protocol and port preference" -anchor w
        set ppl $nb.connection.ppl
        ttk::treeview $ppl -columns protoport -selectmode browse -show tree
        bind $ppl <<TreeviewSelect>> [list options-connection-tab-update $ppl]
        frame $nb.connection.buttons
    
        button $nb.connection.buttons.up -text "Move Up" -anchor w -command [list TreeItemMove up $ppl]
        button $nb.connection.buttons.down -text "Move Down" -anchor w -command [list TreeItemMove down $ppl]
    
        grid $nb.connection.buttons.up -row 0 -sticky nwe -pady {0 10}
        grid $nb.connection.buttons.down -row 1 -sticky nwe -pady {0 10}
    
        $ppl column #0 -width 30 -anchor w -stretch 0
        $ppl column 0 -width 100 -anchor w
    
        foreach protoport [protoport-list] {
            $ppl insert {} end -id [join $protoport ""] -values [list $protoport]
        }

        $ppl selection set [lindex [$ppl children {}] 0]
        $ppl focus [lindex [$ppl children {}] 0]

        frame $nb.connection.panel
    
        grid $nb.connection.info -columnspan 3 -padx 10 -pady {10 0} -sticky news
        grid $ppl -row 3 -column 0 -sticky news -padx 10 -pady 10
        grid $nb.connection.buttons -row 3 -column 1 -sticky nw -padx 10 -pady 10
        grid $nb.connection.panel -row 3 -column 2 -sticky news -padx 10 -pady 10
    
        grid columnconfigure $nb.connection 2 -weight 1
    
        options-connection-tab-update $ppl
    
        #####################################################
        # Profiles tab
        #
        frame $nb.profs
        label $nb.profs.info -text "Active profiles" -anchor w
        set profl $nb.profs.profl
        ttk::treeview $profl -columns profilename -selectmode browse -show tree
        bind $profl <<TreeviewSelect>> [list options-profile-tab-update $profl]
        frame $nb.profs.buttons
    
        button $nb.profs.buttons.up -text "Move Up" -anchor w -command [list TreeItemMove up $profl]
        button $nb.profs.buttons.down -text "Move Down" -anchor w -command [list TreeItemMove down $profl]
        button $nb.profs.buttons.delete -text "Delete" -anchor w -command [list ProfileDelete $profl]
        button $nb.profs.buttons.updateplan -text "Update Plan" -anchor w -command [list go ProfileUpdatePlan $profl $nb.profs]
        label $nb.profs.statusline -compound left -text " "
        img place 24/empty $nb.profs.statusline
    
        grid $nb.profs.buttons.up -row 0 -sticky nwe -pady {0 10}
        grid $nb.profs.buttons.down -row 1 -sticky nwe -pady {0 10}
        grid $nb.profs.buttons.delete -row 2 -sticky nwe -pady {0 10}
        grid $nb.profs.buttons.updateplan -row 3 -sticky nwe -pady {0 10}
    
        $profl column #0 -width 30 -anchor w -stretch 0
        $profl column 0 -width 160 -anchor w
    
        foreach profileid [model active-profiles] {
            set profilename [dict-pop $::model::Profiles $profileid profilename $profileid]
            $profl insert {} end -id $profileid -values [list $profilename]
        }

        $profl selection set [lindex [$profl children {}] 0]
        $profl focus [lindex [$profl children {}] 0]

        frame $nb.profs.panel
    
        grid $nb.profs.info -columnspan 3 -padx 10 -pady {10 0} -sticky news
        grid $profl -row 3 -column 0 -sticky news -padx 10 -pady 10
        grid $nb.profs.buttons -row 3 -column 1 -sticky nw -padx 10 -pady 10
        grid $nb.profs.panel -row 3 -column 2 -sticky news -padx 10 -pady 10
        grid $nb.profs.statusline -row 4 -columnspan 3 -sticky w -padx 10 -pady {0 10}

        grid columnconfigure $nb.profs 2 -weight 1
    
    
        options-profile-tab-update $profl
    
        #####################################################
        #
        ttk::notebook::enableTraversal $nb
        bind $nb <<NotebookTabChanged>> [list OptionsTabChanged $nb]
        $nb add $nb.about -text About -padding 20
        $nb add $nb.connection -text Connection
        $nb add $nb.profs -text Profile
        grid $nb -sticky news -padx 10 -pady 10 
    
        set wb $w.buttons
        frame $wb
        button $wb.cancel -text Cancel -width 10 -command [list set ::Modal.Result cancel]
        button $wb.ok -text OK -width 10 -command [list set ::Modal.Result ok]
        grid $wb -sticky news
        grid $wb.cancel -row 5 -column 0 -padx {30 0} -pady 5 -sticky w
        grid $wb.ok -row 5 -column 1 -padx {0 30} -pady 5 -sticky e
        grid columnconfigure $wb 0 -weight 1
        grid rowconfigure $wb 0 -weight 1
        grid columnconfigure $w 0 -weight 1
        grid rowconfigure $w 0 -weight 1
    
        bind $w <Escape> [list set ::Modal.Result cancel]
        bind $w <Control-w> [list set ::Modal.Result cancel]
        bind $w <Control-q> [list set ::Modal.Result cancel]
        wm title $w "Options"
        
        # update status based on previous values of Latest_version - in quiet mode - display only if program out of date
        checkforupdates-refresh $uframe 1
    
        set modal [ShowModal $w]
        if {$modal eq "ok"} {
            puts stderr "Options ok"
            set ::model::protoport_order {}
            foreach ppitem [$ppl children {}] {
                lappend ::model::protoport_order [lindex [$ppl item $ppitem -values] 0]
            }

            set original_profs [model active-profiles]
            set remaining_profs [$profl children {}]
            if {[llength $original_profs] != [llength $remaining_profs]} {
                foreach profileid [ldiff $original_profs $remaining_profs] {
                    lappend ::model::removed_profiles $profileid
                }
                set ::model::removed_profiles [lunique $::model::removed_profiles]
                # repaint profile tabset
                tabset-profiles .c.tabsetenvelope
            }
        }
        destroy $w
    } on error {e1 e2} {
        puts stderr [log $e1 $e2]
    }
}

proc OptionsTabChanged {nb} {
    options-connection-tab-update $nb.connection.ppl
    options-profile-tab-update $nb.profs.profl

}


proc options-connection-tab-update {tree} {
    set tabframe .options_dialog.nb.connection
    set stateup disabled
    set statedown disabled
    set sel [$tree selection]
    if {$sel ne ""} {
        set index [$tree index $sel]
        if {$index > 0} {
            set stateup normal
        }
        if {$index < [llength [$tree children {}]] - 1} {
            set statedown normal
        }
    }
    $tabframe.buttons.up configure -state $stateup
    $tabframe.buttons.down configure -state $statedown
}

proc options-profile-tab-update {tree} {
    set tabframe .options_dialog.nb.profs
    set stateup disabled
    set statedown disabled
    set statedelete disabled
    set stateupdateplan disabled
    set sel [$tree selection]
    if {$sel ne ""} {
        set index [$tree index $sel]
        if {$index > 0} {
            set stateup normal
        }
        if {$index < [llength [$tree children {}]] - 1} {
            set statedown normal
        }
        set statedelete normal
        set profileid $sel
        if {$profileid eq "fruho" || [dict-pop $::model::Profiles $profileid vpapi_username {}] ne ""} {
            set stateupdateplan normal
        }
    }
    $tabframe.buttons.up configure -state $stateup
    $tabframe.buttons.down configure -state $statedown
    $tabframe.buttons.delete configure -state $statedelete
    $tabframe.buttons.updateplan configure -state $stateupdateplan
}


proc ProfileDelete {tree} {
    set profileid [$tree selection]
    if {$profileid ne ""} {
        set newsel [$tree next $profileid]
        if {$newsel eq ""} {
            set newsel [$tree prev $profileid]
        }
        $tree delete [list $profileid]
        if {$newsel ne ""} {
            $tree selection set $newsel
        }
    }
    options-profile-tab-update $tree
}

proc ProfileUpdatePlan {tree tabframe} {
    try {
        set profileid [$tree selection]
        if {$profileid eq ""} {
            return
        }
        set profilename [dict-pop $::model::Profiles $profileid profilename {}]
        img place 24/connecting $tabframe.statusline
        $tabframe.statusline configure -text "Updating $profilename"
        $tabframe.buttons.updateplan configure -state disabled

        set result [vpapi-plans-direct $profilename [vpapi-host $profileid] [vpapi-port $profileid] [vpapi-path-plans $profileid]?[this-pcv] [vpapi-username $profileid] [vpapi-password $profileid]]
        set msg "Updated profile $profilename"
        if {$result != 200} {
            if {$result == 401} {
                set msg "Incorrect username/password"
            } else {
                set msg $result
            }
            puts stderr "updateplan msg: $msg"
        }
        img place 24/empty $tabframe.statusline
        $tabframe.statusline configure -text $msg
        after 3000 [list $tabframe.statusline configure -text " "]
        $tabframe.buttons.updateplan configure -state normal
    } on error {e1 e2} {
        puts stderr [log $e1 $e2]
    }
}


proc vpapi-username {profileid} {
    return [dict-pop $::model::Profiles $profileid vpapi_username $::model::Cn]
}
proc vpapi-password {profileid} {
    return [dict-pop $::model::Profiles $profileid vpapi_password {}]
}
proc vpapi-host {profileid} {
    return [dict-pop $::model::Profiles $profileid vpapi_host bootstrap]
}
proc vpapi-port {profileid} {
    return [dict-pop $::model::Profiles $profileid vpapi_port 10443]
}
proc vpapi-path-plans {profileid} {
    return [dict-pop $::model::Profiles $profileid vpapi_path_plans /vpapi/plans]
}

proc TreeItemMove {direction tree} {
    set sel [$tree selection]
    if {$sel eq ""} {
        return
    }
    set index [$tree index $sel]
    if {$direction eq "up"} {
        $tree move $sel {} [incr index -1]
    } elseif {$direction eq "down"} {
        $tree move $sel {} [incr index 1]
    } else {
        error "Wrong direction in TreeItemMove"
    }
    options-connection-tab-update $tree
    options-profile-tab-update $tree
}

proc protoport-list {} {
    dict for {_ profile} $::model::Profiles {
        dict for {_ plan} [dict-pop $profile plans {}] {
            foreach sitem [dict-pop $plan slist {}] {
                foreach ovs [dict-pop $sitem ovses {}] {
                    set ovsproto [dict-pop $ovs proto {}]
                    set ovsport [dict-pop $ovs port {}]
                    if {$ovsproto ne "" && $ovsport ne ""} {
                       lappend ::model::protoport_order [list $ovsproto $ovsport]
                    }
                }
            }
        }
    }
    set ::model::protoport_order [lunique $::model::protoport_order]
    return $::model::protoport_order
}



#TODO sorting by country and favorites
proc ServerListClicked {} {
    try {
        set profileid [current-profile]
        set planid [current-planid [model now] $profileid]
        set slist [model slist $profileid $planid]
        # we don't take selected_sitem_id directly from the model plan - give a chance to calculate/get random
        set ssitem [model selected-sitem $profileid $planid]
        set ssid [dict-pop $ssitem id {}]
    
    
        set w .slist_dialog
        catch { destroy $w }
        toplevel $w
        set wt $w.tree
    
        ttk::treeview $wt -columns "country city ip" -selectmode browse -yscrollcommand [list $w.scrollbar set]
        scrollbar $w.scrollbar -command [list $wt yview]
        
        $wt heading #0 -text F
        $wt heading 0 -text Country
        $wt heading 1 -text City
        $wt heading 2 -text IP
        $wt column #0 -width 50 -anchor nw -stretch 0
        $wt column 0 -width 140 -anchor w
        $wt column 1 -width 140 -anchor w
        $wt column 2 -width 140 -anchor w
        
        foreach sitem $slist {
            set id [dict get $sitem id]
            set ccode [dict get $sitem ccode]
            if {$ccode eq ""} {
                set ccode EMPTY
            }
            set country [dict get $sitem country]
            if {$country eq ""} {
                set country "Unknown"
            }
            set city [dict get $sitem city]
            if {$city eq ""} {
                set city "Unknown"
            }
            set ip [dict get $sitem ip]
            set flag 24/flag/$ccode
            if {![img exists $flag]} {
                set flag 24/flag/EMPTY
            }
            $wt insert {} end -id $id -image [img load $flag] -values [list $country $city $ip]
        }
        $wt selection set $ssid
        grid columnconfigure $w 0 -weight 1
        grid rowconfigure $w 0 -weight 1
        grid $wt $w.scrollbar -sticky news
    
        set wb $w.buttons
        ttk::frame $wb
        # width may be in pixels or in chars depending on presence of the image
        button $wb.cancel -text Cancel -width 10 -command [list set ::Modal.Result cancel]
        button $wb.ok -text OK -width 10 -command [list set ::Modal.Result ok]
        grid $wb -sticky news
        grid $wb.cancel -row 5 -column 0 -padx {30 0} -pady 5 -sticky w
        grid $wb.ok -row 5 -column 1 -padx {0 30} -pady 5 -sticky e
        grid columnconfigure $wb 0 -weight 1
    
        bind Treeview <Return> [list set ::Modal.Result ok]
        bind Treeview <Double-Button-1> [list set ::Modal.Result ok]
        bind $w <Escape> [list set ::Modal.Result cancel]
        bind $w <Control-w> [list set ::Modal.Result cancel]
        bind $w <Control-q> [list set ::Modal.Result cancel]
        wm title $w "Select server"
    
    
        focus $wt
        $wt focus $ssid
        set modal [ShowModal $w]
        if {$modal eq "ok"} {
            model selected-sitem $profileid $planid [$wt selection]
        }
        #model print
        destroy $w

    } on error {e1 e2} {
        log "$e1 $e2"
    }
}



#-----------------------------------------------------------------------------
# ShowModal win ?-onclose script? ?-destroy bool?
#
# Displays $win as a modal dialog. 
#
# If -destroy is true then $win is destroyed when the dialog is closed. 
# Otherwise the caller must do it. 
#
# If an -onclose script is provided, it is executed if the user terminates the 
# dialog through the window manager (such as clicking on the [X] button on the 
# window decoration), and the result of that script is returned. The default 
# script does nothing and returns an empty string. 
#
# Otherwise, the dialog terminates when the global ::Modal.Result is set to a 
# value. 
#
# This proc doesn't play nice if you try to have more than one modal dialog 
# active at a time. (Don't do that anyway!)
#
# Examples:
#   -onclose {return cancel}    -->    ShowModal returns the word 'cancel'
#   -onclose {list 1 2 3}       -->    ShowModal returns the list {1 2 3}
#   -onclose {set ::x zap!}     -->    (variations on a theme)
#
proc ShowModal {win args} {
    try {
        set ::Modal.Result {}
        array set options [list -onclose {} -destroy 0 {*}$args]
        wm transient $win .
        wm protocol $win WM_DELETE_WINDOW [list catch $options(-onclose) ::Modal.Result]
        set x [expr {([winfo width  .] - [winfo reqwidth  $win]) / 2 + [winfo rootx .]}]
        set y [expr {([winfo height .] - [winfo reqheight $win]) / 2 + [winfo rooty .]}]
        wm geometry $win +$x+$y
        #wm attributes $win -topmost 1
        #wm attributes $win -type dialog
        raise $win
        focus $win
        grab $win
        tkwait variable ::Modal.Result
        grab release $win
        if {$options(-destroy)} {destroy $win}
        return ${::Modal.Result}
    } on error {e1 e2} {
        puts stderr $e1 $e2
    }
}



proc resolve-host {host} {
    if {[is-valid-ip $host]} {
        return $host
    }
    if {[dict exists $::model::dns_cache $host]} {
        return [dict get $::model::dns_cache $host]
    } else {
        log "WARNING: resolve-host could not resolve $host. Using domain name instead of IP"
        return $host
    }
}


proc this-pcv {} {
    set platform [this-os]-[this-arch]
    set version [build-version]
    set cn $::model::Cn
    return [http::formatQuery p $platform v $version c $cn]
}


# tablelist vs TkTable vs treectrl vs treeview vs BWidget::Tree


# Defaults to https, "/" path, 5000 ms timeout
# In order to retry n times use:
# go curl-retry $chout $cherr -hostports [lrepeat $n $host:$port] -urlpath $urlpath {*}$args
# tryout - if success, http content response will be sent to this channel or empty string if -gettofile
# tryerr - if all attempts failed, last error (http response code) will be sent to this channel
proc curl-retry {tryout tryerr args} {
    try {
        fromargs {-urlpath -indiv_timeout -hostports -hindex -proto -expected_hostname -method -gettofile -postfromfile -basicauth -cadir} \
                 {/ 5000 {} _ https}
        upvar $hindex host_index
        if {![info exists host_index]} {
            set host_index 0
        }
        if {$proto ne "http" && $proto ne "https"} {
            error "Wrong proto: $proto"
        }

        set opts [dict create]
        # dict set ignore empty value
        dict-set-iev opts -timeout $indiv_timeout
        dict-set-iev opts -expected-hostname $expected_hostname
        dict-set-iev opts -method $method
        dict-set-iev opts -basicauth $basicauth

        set hlen [llength $hostports]
        set ncode 0
        # host_index is the index to start from when iterating hostports
        for {set i $host_index} {$i<$host_index+$hlen} {incr i} {
            set hostport [lindex $hostports [expr {$i % $hlen}]]
            lassign [split $hostport :] host port
            if {$port eq ""} {
                if {$proto eq "http"} {
                    set port 80
                } elseif {$proto eq "https"} {
                    set port 443
                } else {
                    error "No port given for $proto://$host$urlpath curl-retry call"
                }
            }
            set hostip [resolve-host $host]
            set url $proto://$hostip:${port}${urlpath}
            # Need to catch error in case the handler triggers after the channel was closed (if using select with timer channel for timeouts)
            # or https curl throws error immediately
            try {
                if {$gettofile ne ""} {
                    # in order to prevent opening the file in case when download fails 
                    # (it's not clear then whether file exists or not - file command gets confused)
                    # open temporary file and atomically move on success
                    set tmpgettofile /tmp/gettofile_[rand-big]
                    dict set opts -channel [open $tmpgettofile w]
                }
                if {$postfromfile ne ""} {
                    dict set opts -querychannel [open $postfromfile r] 
                    dict set opts -type text/plain
                }
                # reregister tls handling with proper CAdir store
                if {$cadir eq ""} {
                    #TODO make it cross-platform
                    https init -cadir /etc/ssl/certs
                } else {
                    https init -cadir $cadir
                }
                # use hostip for url but expect host for TLS domain verification if not overwritten by expected_hostname option
                # -expected-hostname given in options takes precedence over individual resolved host names
                # so overwrite here only if the option was not provided
                if {$expected_hostname eq ""} {
                    dict set opts -expected-hostname $host
                }
                https curl $url {*}[dict get $opts] -command [-> chhttp]
                set tok [<- $chhttp]
                upvar #0 $tok state
                set ncode [http::ncode $tok]
                set status [http::status $tok]
                if {$status eq "ok" && $ncode == 200} {
                    set host_index [expr {$i % $hlen}]
                    set data [http::data $tok]
                    puts stderr [log "curl-retry $url success. data: $data"]
                    if {$gettofile ne ""} {
                        catch {set fd $state(-channel); close $fd;}
                        # make appearing the file atomic
                        puts stderr "moving $tmpgettofile to $gettofile"
                        file mkdir [file dir $gettofile]
                        file rename -force $tmpgettofile $gettofile
                    }
                    $tryout <- $data
                    return
                } else {
                    puts stderr [log "curl-retry $url failed with status: $status, http code: $ncode, error: [http::error $tok]"]
                    if {$gettofile ne ""} {
                        file delete $gettofile
                    }
                }
            } on error {e1 e2} { 
                log "$e1 $e2"
            } finally {
                catch {$chhttp close}
                catch {set fd $state(-channel); close $fd;}
                catch {set fd $state(-querychannel); close $fd;}
                catch {http::cleanup $tok}
            }
        }
        $tryerr <- $ncode
    } on error {e1 e2} {
        log "$e1 $e2"
    } finally {
    }
}


# periodically trigger updating usage meter
proc plan-monitor {} {
    if {![is-addprovider-tab-selected]} {
        set now [model now]
        dash-plan-update $now
        dash-time-update $now
    }
    after 5000 plan-monitor
}

proc daemon-monitor {} {
    set ms [clock milliseconds]
    if {$ms - $::model::Ffconn_beat > 3000} {
        log "Heartbeat not received within last 3 seconds. Restarting connection."
        set ::model::Connstatus unknown
        gui-update
        ffconn-close
        daemon-connect 7777
    }
    after 1000 daemon-monitor
}


proc daemon-connect {port} {
    #TODO handle error
    if {[catch {set sock [socket 127.0.0.1 $port]} out err] == 1} {
        ffconn-close
        return
    }
    set ::model::Ffconn_sock $sock
    chan configure $sock -blocking 0 -buffering line
    chan event $sock readable ffread
}


proc ffwrite {msg} {
    if {[catch {puts $::model::Ffconn_sock $msg} out err] == 1} {
        log "ffwrite problem writing $msg to $::model::Ffconn_sock"
        ffconn-close
    }
}

proc ffconn-close {} {
    catch {close $::model::Ffconn_sock}
}


proc ffread {} {
    set sock $::model::Ffconn_sock
    if {[gets $sock line] < 0} {
        if {[eof $sock]} {
            log "ffread_sock EOF. Connection terminated"
            ffconn-close
        }
        return
    }
    switch -regexp -matchvar tokens $line {
        {^ctrl: (.*)$} {
            puts stderr [log OPENVPN CTRL: [lindex $tokens 1]]
            switch -regexp -matchvar details [lindex $tokens 1] {
                {^Config loaded} {
                    ffwrite start
                }
                {^version (\S+) (.*)$} {
                    set daemon_version [lindex $details 1]
                    puts stderr "DAEMON VERSION: $daemon_version"
                    puts stderr "FRUHO CLIENT VERSION: [build-version]"
                    # fruho client to restart itself if daemon already upgraded and not too often
                    if {[int-ver $daemon_version] > [int-ver [build-version]]} {
                        set sha [sha1sum [this-binary]]
                        # just restart itself from the new binary - daemon should have replaced it
                        # restart only if different binaries
                        if {$sha ne $::model::Running_binary_fingerprint} {
                            model save
                            execl [this-binary]
                        }
                    }
                }
            }
        }
        {^ovpn: (.*)$} {
            set ::model::OvpnServerLog [lindex $tokens 1]
            puts stderr [log OPENVPN LOG: $::model::OvpnServerLog]
            switch -regexp -matchvar details [lindex $tokens 1] {
                {^Initialization Sequence Completed} {
                }
            }
        }
        {^stat: (.*)$} {
            set stat [dict create {*}[lindex $tokens 1]]
            set ::model::Ffconn_beat [clock milliseconds]
            set ovpn_config [dict-pop $stat ovpn_config {}]
            set proto [lindex [ovconf get $ovpn_config --proto] 0]
            set port [lindex [lindex [ovconf get $ovpn_config --remote] 0] 1]
            set ::model::Current_protoport [list $proto $port]
            set meta [lindex [ovconf get $ovpn_config --meta] 0]
            if {$meta ne ""} {
                set ::model::Current_sitem $meta
                set profileid [dict-pop $meta profile {}]
                set trafficup [dict-pop $stat mgmt_rwrite 0]
                set trafficdown [dict-pop $stat mgmt_rread 0]
                traffic-speed-store $trafficup $trafficdown

                if {[is-connecting-status] && [current-profile] eq $profileid} {
                    dash-gauge-update
                }
            }
            #puts stderr "stat: $stat"
            #puts stderr "ovpn_config: $ovpn_config"
            #puts stderr "meta: $meta"

            conn-status-update $stat
            #TODO heartbeat timeout
            #connstatus update trigger

        }
    }
    log fruhod>> $line
}


# takes latest traffic measurements from stat and saves in the model
proc traffic-speed-store {trafficup trafficdown} {
    set ms [clock milliseconds]
    set n $::model::previous_traffic_probes

    # prevent adding duplicate measurements what might result in time difference = 0 and division by zero later
    if {[lindex $::model::Previous_traffic_tstamp end] != $ms} {
        lappend ::model::Previous_traffic_tstamp $ms
        lappend ::model::Previous_trafficup $trafficup
        lappend ::model::Previous_trafficdown $trafficdown
        # this will keep max n+1 items
        set ::model::Previous_traffic_tstamp [lrange $::model::Previous_traffic_tstamp end-$n end]
        set ::model::Previous_trafficup [lrange $::model::Previous_trafficup end-$n end]
        set ::model::Previous_trafficdown [lrange $::model::Previous_trafficdown end-$n end]
    }
}

# returns trafficup, trafficdown and moving averages of speedup and speeddown
proc traffic-speed-calc {} {
    set trafficup 0
    set trafficdown 0
    set speedupavg 0
    set speeddownavg 0
    if {$::model::Previous_traffic_tstamp ne ""} {
        set difft [lbetween {a b} $::model::Previous_traffic_tstamp {expr {$b-$a}}]
        set diffup [lbetween {a b} $::model::Previous_trafficup {expr {$b-$a}}]
        set diffdown [lbetween {a b} $::model::Previous_trafficdown {expr {$b-$a}}]

        if {[llength $difft] == [llength $diffup]} {
            # list of speeds
            set speedup [lmap tx $difft x $diffup {expr {1000*double($x)/double($tx)}}]
            set speeddown [lmap tx $difft x $diffdown {expr {1000*double($x)/double($tx)}}]
            set speedupavg [expr max(0, round([average-simple $speedup]))]
            set speeddownavg [expr max(0, round([average-simple $speeddown]))]
            set trafficup [lindex $::model::Previous_trafficup end]
            set trafficdown [lindex $::model::Previous_trafficdown end]
        }
    }
    return [list $trafficup $trafficdown $speedupavg $speeddownavg]
}



proc select-protoport-ovs {sitem} {
    set ovses [dict-pop $sitem ovses {}]
    foreach pp $::model::protoport_order {
        foreach ovs $ovses {
            set ovsproto [dict-pop $ovs proto {}]
            set ovsport [dict-pop $ovs port {}]
            if {$ovsproto ne "" && $ovsport ne ""} {
                if {$ovsproto eq [lindex $pp 0] && $ovsport eq [lindex $pp 1]} {
                    return $pp
                }
            }
        }
    }
    if {[llength $ovses] == 0} {
        log "ERROR: No ovses. Wrong sitem: $sitem"
        return ""
    }
    set ovs [lindex $ovses 0]
    set ovsproto [dict-pop $ovs proto {}]
    set ovsport [dict-pop $ovs port {}]
    if {$ovsproto ne "" && $ovsport ne ""} {
        return [list $ovsproto $ovsport]
    } else {
        log "ERROR: No ovsproto or ovsport. Wrong sitem: $sitem"
        return ""
    }
}


proc ClickConnect {} {
    try {
        set profile [current-profile]
        # immediately disable button to prevent double-click
        set ::model::Connstatus_enforced connecting
        after 1500 [list set ::model::Connstatus_enforced ""]


        # temporary set Current_sitem - it will be overwritten by meta info received back from daemon
        set planid [current-planid [model now] $profile]
        set ::model::Current_sitem [model selected-sitem $profile $planid]

        # additional profile name info in sitem that will be passed as metadata to openvpn config / fruhod
        dict set ::model::Current_sitem profile $profile
        set localconf [::ovconf::parse [ovpndir $profile config.ovpn]]

        set ip [dict get $::model::Current_sitem ip]

        set ::model::Current_protoport [select-protoport-ovs $::model::Current_sitem]
        lassign $::model::Current_protoport proto port

        #TODO not really append, it's rather replace
        #TODO handle inline certs and keys
        set cert [ovconf get $localconf --cert]
        if {$cert eq ""} {
            set localconf [ovconf cset $localconf --cert [ovpndir $profile client.crt]]
        }
        set key [ovconf get $localconf --key]
        if {$key eq ""} {
            set localconf [ovconf cset $localconf --key [ovpndir $profile client.key]]
        }
        set ca [ovconf get $localconf --ca]
        if {$ca eq ""} {
            set localconf [ovconf cset $localconf --ca [ovpndir $profile ca.crt]]
        }

        append localconf " --proto $proto --remote $ip $port --meta $::model::Current_sitem "
        puts stderr [log localconf: $localconf]
        ffwrite "config $localconf"
        gui-update
    } on error {e1 e2} {
        log "$e1 $e2"
    }
}

proc ClickDisconnect {} {
    try {
        # immediately disable button to prevent double-click
        set ::model::Connstatus_enforced disconnected
        after 1500 [list set ::model::Connstatus_enforced ""]
        trigger-geo-loc 1000
        set Previous_trafficup {}
        set Previous_trafficdown {}
        set Previous_traffic_tstamp {}
        gui-update
        ffwrite stop
    } on error {e1 e2} {
        log "$e1 $e2"
    }
}


proc trigger-geo-loc {{delay 0}} {
    set ::model::Geo_loc [dict create ip "" cc ""]
    after $delay [list go get-external-loc]
}


proc build-version {} {
    memoize
    return [string trim [slurp [file join [file dir [info script]] buildver.txt]]]
}

proc build-date {} {
    memoize
    return [string trim [slurp [file join [file dir [info script]] builddate.txt]]]
}





main

vwait ::until_exit
