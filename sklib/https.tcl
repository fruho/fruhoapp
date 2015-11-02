package provide https 0.0.0

package require http
package require tls
# Collection of http/tls utilities like wget or curl
# They work also for plain http
# TODO support url redirect (Location header)
# TODO Currently the necessity of calling ::cleanup after ::geturl is the usage scheme taken from http package. If we assume only asynchronoous use we could do cleanup in this package after returning from user callback. It could release the user from responsibility of calling cleanup so prevent possible memory leaks.


# Believe or not but the original Tcl tls package does not validate certificate subject's Common Name CN against URL's domain name
# TLS is pointless without this validation because it enables trivial MITM attack


namespace eval ::https {
    variable default_timeout 15000
    variable sock2host
    variable sock2error
    variable host2expected
    namespace export curl curl-async wget wget-async socket init parseurl
    namespace ensemble create
}

# log with timestamp to stdout
proc ::https::log {args} {
    catch {puts [join [list [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"] {*}$args]]}
}

proc ::https::debug-http {tok} {
    upvar #0 $tok state
    log debug-http $tok
    parray state
}

# This may be called by clients in order to overwrite default TLS socket settings
# Provide args for tls::socket command. In particular you can:
# -cadir dir            # Provide the directory containing the CA certificates.
# -cafile filename      # Provide the CA file.
# -certfile filename    # Provide the certificate to use. 
proc ::https::init {args} {
    catch {http::unregister https}
    # We cannot use the original tls::socket because it does not validate Host against Common Name
    http::register https 443 [list https::socket -require 1 -command ::https::tls-callback -ssl2 0 -ssl3 0 -tls1 1 {*}$args]
}


# tls::socket ?options? host port
proc ::https::socket {args} {
    variable sock2host
    log https::socket args: $args
    #Note that http::register appends options, host and port. E.g.: <given https::socket options> -async tv.eurosport.com 443
    set chan [tls::socket {*}$args]
    log https::socket created chan: $chan
    # Save tls socket to host mapping which is further required for TLS validation
    dict set sock2host $chan [lindex $args end-1]
    log sock2host: $sock2host
    return $chan
}

proc ::https::tls-cleanup {chan} {
    variable sock2host
    variable host2expected
    dict unset sock2host $chan
    dict unset host2expected $chan
}


#
# this is a modified version of the default [info body tls::callback] with cert Common Name validation
proc ::https::tls-callback {option args} {
    variable sock2host
    variable sock2error
    variable host2expected
    log tls-callback: $option $args
    switch -- $option {
        "error" {
            lassign $args chan msg
            log "             " "TLS/$chan: error: $msg"
            set msg "TLSERROR: $msg"
            log $msg
            puts stderr $msg
        }
        "verify"  {
            lassign $args chan depth cert rc err
            array set c $cert
            # Parse X.509 subject to extract CN
            set subject $c(subject)
            set props [split $subject ","]
            set props [lmap p $props {string trim $p}]
            set prop [lsearch -inline $props CN=*]
            if {![regexp {^CN=(.+)$} $prop _ cn]} {
                set msg "TLSERROR: Wrong subject format in the certificate: $subject"
                log $msg
                dict set sock2error $chan $msg
                tls-cleanup $chan
                return 0
            }
            # Return error early on bad/missing certs detected by OpenSSL
            if {$rc != 1} {
                set msg "TLSERROR: TLS/$chan: verify/$depth: Bad Cert: $err (rc = $rc)"
                log $msg
                dict set sock2error $chan $msg
                tls-cleanup $chan
                return $rc
            }
            log "             " "TLS/$chan: verify/$depth: $c(subject)"
            # Don't verify Common Name against url domain for root and intermediate certificates
            if {$depth != 0} {
                return 1
            }
            # Return error if chan name not saved before
            if {![dict exists $sock2host $chan]} {
                log TLSERROR: Missing hostname for channel $chan. It may be caused by previous errors
                return 0
            }
            set host [dict get $sock2host $chan]
            #TODO expected-hostname - allow providing a list of expected hostnames
            if {$host ne "" && ($host eq $cn || ([info exists host2expected] && [dict exists $host2expected $host] && [dict get $host2expected $host] eq $cn))} {
                log Hostname matched the Common Name: $cn
                tls-cleanup $chan
                return 1
            } else {
                set msg "TLSERROR: Hostname: $host does not match the name in the certificate: $cn"
                puts stderr $msg
                log $msg
                dict set sock2error $chan $msg
                tls-cleanup $chan
                return 0
            }
        }
        "info"  {
            lassign $args chan major minor state msg
            if {$msg != ""} {
                append state ": $msg"
            }
            # For tracing
            upvar #0 tls::$chan cb
            set cb($major) $minor
            log "             " "TLS/$chan: $major/$minor: $state"
        }
        default {
            return -code error "bad option \"$option\": must be one of error, info, or verify"
        }
    }
}

# like http::geturl but args may contain addtional options:
# -expected-hostname <expected_hostname>
# -basicauth {$username $password}
# It also appends default -timeout if not given
proc ::https::geturl {url args} {
    if {[lsearch -exact $args -timeout] == -1} {
        lappend args -timeout $::https::default_timeout
    }
    set bai [lsearch -exact $args -basicauth]
    if {$bai != -1} {
        package require base64
        set basic "Basic "
        set userpass [join [lindex $args [expr {$bai+1}]] :]
        set args [lreplace $args $bai [expr {$bai+1}]]
        append basic [base64::encode $userpass]
        lappend args -headers [list Authorization $basic]
    }
    set ehi [lsearch -exact $args -expected-hostname]
    if {$ehi != -1} {
        set expected [lindex $args [expr {$ehi+1}]]
        if {$expected eq ""} {
            error "Missing -expected-hostname value in: $args"
        }
        set args [lreplace $args $ehi [expr {$ehi+1}]]
        #TODO ZONK - we don't have tls channel here - it's only in https::socket so we cannot overwrite sock2host :(
        # quick and dirty way to link expected-hostname with url host. It's not completely correct because it's a global mapping. Should be in the tls sock/chan context
        variable host2expected
        array set parsed [::https::parseurl $url]
        log host: $parsed(host)
        dict set host2expected $parsed(host) $expected
    }


    if {[catch {set tok [http::geturl $url {*}$args]} out err]} {
        variable sock2error
        log $out
        # This is to make error more informative because normally any TLS error is causing geturl to fail miserably at random socket operation with a misleading error message
        if {[regexp {error .*"(.+)": software caused connection abort} $out _ chan]} {
            if {[info exists sock2error] && [dict exists $sock2error $chan]} {
                set tlserror [dict get $sock2error $chan]
                dict unset $sock2error $chan
                error $tlserror
            }
        }
        error $err
    }
    return $tok
}


proc ::https::parseurl {url} {
    # This is copied from ::http::geturl
    set URLmatcher {(?x)        # this is _expanded_ syntax
    ^
    (?: (\w+) : ) ?         # <protocol scheme>
    (?: //
        (?:
        (
            [^@/\#?]+       # <userinfo part of authority>
        ) @
        )?
        (               # <host part of authority>
        [^/:\#?]+ |     # host name or IPv4 address
        \[ [^/\#?]+ \]      # IPv6 address in square brackets
        )
        (?: : (\d+) )?      # <port part of authority>
    )?
    ( [/\?] [^\#]*)?        # <path> (including query)
    (?: \# (.*) )?          # <fragment>
    $
    }
    if {[regexp -- $URLmatcher $url -> a(proto) a(user) a(host) a(port) a(srvurl)]} {
        return [array get a]
    } else {
        error "Wrong url format: $url"
    }

}




#http:: If the -command option is specified, then the HTTP operation is done in the background. ::http::geturl returns immediately after generating the HTTP request and the callback is invoked when the transaction completes. For this to work, the Tcl event loop must be active. In Tk applications this is always true. For pure-Tcl applications, the caller can use ::http::wait after calling ::http::geturl to start the event loop.

# If called as synchronous (without -command option) it returns url content or throws error on anything different than HTTP 200 OK
# See https::geturl for detailed options
# All errors propagated upstream
# Examples:
# puts [https curl https://example.com/index.html]
# set tok [https curl https://example.com/index.html -command ::https::curl-callback]
# puts [https curl https://91.227.221.115/geo-ip.php -expected-hostname example.com]
proc ::https::curl {url args} {
    set async [expr {[lsearch -exact $args -command] != -1}]
    if {[catch {set tok [https::geturl $url {*}$args]} out err]} {
        error $err
    }
    if {$async} {
        return $tok
    }
    set retcode [http::ncode $tok]
    set status [http::status $tok]
    set data [http::data $tok]
    if {$status eq "ok" && $retcode == 200} {
        http::cleanup $tok
        return $data
    } else {
        debug-http $tok
        http::cleanup $tok
        error "ERROR in curl $url $args (status $status, retcode $retcode)"
    }
}

# This is a template for curl callback if https::curl is called with async -command option
# Use tok as request ID to match request-response
proc ::https::curl-callback {tok} {
    puts "curl-callback called with tok: $tok"
    set retcode [http::ncode $tok]
    set status [http::status $tok]
    set data [http::data $tok]
    http::cleanup $tok
    puts "curl-callback status: $status"
    puts "curl-callback retcode: $retcode"
    puts "curl-callback data: $data"
}


proc ::https::wget {url filepath args} {
    set async [expr {[lsearch -exact $args -command] != -1}]
    set fd [open $filepath w]
    if {[catch {set tok [https::geturl $url -channel $fd {*}$args]} out err]} {
        close $fd
        error $err
    }
    upvar #0 $tok state
    set state(filepath) $filepath
    if {$async} {
        return $tok
    }
    close $fd
    set status [http::status $tok]
    set retcode [http::ncode $tok]
    if {$status ne "ok"} {
        file delete $filepath
        debug-http $tok
        http::cleanup $tok
        error "ERROR in wget $url $filepath"
    }
    if {$retcode != 200} {
        file delete $filepath
    }
    http::cleanup $tok
    return $retcode
}


# This is a template for wget callback if https::wget is called with async -command option
# Use tok as request ID to match request-response
proc ::https::wget-callback {tok} {
    puts "wget-callback called with tok: $tok"
    upvar #0 $tok state
    set fd $state(-channel)
    set filepath $state(filepath)
    set url $state(url)
    catch {close $fd}
    set retcode [http::ncode $tok]
    set status [http::status $tok]
    puts "status: $status, retcode: $retcode"
    if {$status eq "ok" && $retcode == 200} {
        log wget-callback token $tok success
    } else {
        file delete $filepath
        log "wget-callback error: $url $filepath"
        debug-http $tok
    }
    http::cleanup $tok
}


# Do default initialization with Linux cert store location
::https::init -cadir /etc/ssl/certs

