package provide cmd 0.0.0

namespace eval ::cmd {
    namespace export invoke
    namespace ensemble create
}

proc ::cmd::invoke {command {onexit {}} {onstdout puts} {onstderr {puts stderr}} {read gets}} {

    lassign [chan pipe] stderr stderrin
    lappend command 2>@$stderrin
    set stdout [open |$command]

    #chan pipe creates a standalone pipe whose read- and write-side channels are returned as a 2-element list, the first element being the read side and the second the write side. Can be useful e.g. to redirect separately stderr and stdout from a subprocess. To do this, spawn with "2>@" or ">@" redirection operators onto the write side of a pipe, and then immediately close it in the parent. This is necessary to get an EOF on the read side once the child has exited or otherwise closed its output.
    chan close $stderrin

    set handler1 [namespace current]::[info cmdcount]
    coroutine $handler1 ::cmd::handler $onstdout $onstderr $onexit $read
# this was putting tclsh into a busy loop and consumed CPU. It turns out that stderrin can be closed immediately as above
#    fileevent $stderrin writable [list apply {{stdout stderrin} {
#        if {[chan names $stdout] eq {} || [eof $stdout]} {
#            close $stderrin
#        }
#    }} $stdout $stderrin]
    #warning:  under the most recent Tcl release (8.6.1), any errors in handler
    #1 will not be reported via bgerror, but will silently disrupt the program.
    #For the status of this bug, see
    #http://core.tcl.tk/tcl/tktview/ef34dd2457472b08cf6a42a7c8c26329e2cae715
    fileevent $stdout readable [list $handler1 [list stdout $stdout]]
    fileevent $stderr readable [list $handler1 [list stderr $stderr]]
    return $stdout
}


proc ::cmd::handler {onstdout onstderr onexit read} {
    set done {}
    lassign [yield [info level 0]] mode chan
    while 1 {
        if {[set data [{*}$read $chan]] eq {}} {
            if {[eof $chan]} {
                lappend done $mode
                if {[catch {close $chan} cres e]} {
                    dict with e {}
                    lassign [set -errorcode] sysmsg pid exit
                    if {$sysmsg ne "CHILDSTATUS"} {
                        return -options $e $stderr 
                    }
                } else {
                    if {![info exists exit]} {
                        set exit 0
                    }
                }
                if {[llength $done] == 2} {
                    if {$onexit ne {}} {
                        after 0 [list {*}$onexit $exit]
                    }
                    return
                } else {
                    lassign [yield] mode chan
                }
            } else {
                lassign [yield] mode chan
            }
        } else {
            {*}[set on$mode] $data
            lassign [yield] mode chan
        }
    }
}

