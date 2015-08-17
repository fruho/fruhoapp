package provide i18n 0.0.0

# Terminology:
# tm - translatable message
# uid - randomly generated identifier in format _1234567890abcdef, uniquely identifies tm


proc _ {msg args} {
    if {[dict exists $::i18n::LC $msg]} {
        set other [dict get $::i18n::LC $msg]
        if {$other ne ""} {
            set msg $other
        }
    }
    #TODO Verify number of params against placeholders in t
    set params [i18n params-list2dict $args]
    # replace tokens in msg
    return [string map [dict get $params] $msg]
}




namespace eval i18n {
    variable LC [dict create]
    namespace export load code2msg msg2code cleanup orphans params-list2dict
    namespace ensemble create
}

# Load messages file and store as dict mapping from en messages to selected locale messages
proc ::i18n::load {locale {msgfile messages.txt}} {
    variable LC
    set LC [dict create]
    set en ""
    set other ""
    set msgs [slurp $msgfile]
    set lines [split $msgs \n]
    foreach line $lines {
        switch -regexp -matchvar token $line \
        {^\s*en=(.*)$} {
            set en [lindex $token 1]
        } \
        "^\\s*$locale=(.*)\$" {
            set other [lindex $token 1]
            dict set LC $en $other
        }
    }
}


# Parse source code files, mark translatable lines with uid, create/update messages file.
# This assumes that developer added or updated translatable lines in source code and messages need to be updated.
proc ::i18n::code2msg {filespec {locales {fr es de pl}} {msgfile messages.txt}} {
    # to be passed to code-uid-update in order to solve ambiguities where possible
    set uid2tm_msg [msg-prescan $msgfile]
    #TODO for now filespec is assumed to be a single file - should be file/dir specification/filter
    set uid2tml_code [code-uid-update $filespec $uid2tm_msg]
    #puts "uid2tml_code: $uid2tml_code"

    # now process messages.txt line by line and update tm based on matching uid
    # then append tms for uids that were not matched
    set out {}
    touch $msgfile
    set msgs [slurp $msgfile]
    set lines [split $msgs \n]
    set uids {}
    set prevSaved 0
    # original line numbers
    set lno 0
    foreach line $lines {
        incr lno
        switch -regexp -matchvar token $line {
            {^\s*#\|\s*en=} {
                # automatic comment - saved previous tm
                set prevSaved 1
                lappend out $line
            }
            {^\s*#\s*(_[\da-f]{16})} {
                # automatic comment - uids which means new section
                set index 0
                set uids {}
                set prevSaved 0
                #TODO handle multiple uids in the future - this is preparation
                while {[regexp -start $index {.*?(_[\da-f]{16})} $line match sub]} {
                    lappend uids $sub
                    incr index [string length $match]
                }
                lappend out $line
            }
            {^\s*en=(.*)$} {
                # tm
                set msg [lindex $token 1]
                #TODO handle multiple uids in the future - it may be tricky to handle changes. For now take the first uid
                set uid [lindex $uids 0]
                if {[dict exists $uid2tml_code $uid]} {
                    set msg_code [lindex [dict get $uid2tml_code $uid] 0]
                    dict unset uid2tml_code $uid
                    if {$msg eq $msg_code} {
                        # tm has not changed
                        lappend out $line
                    } else {
                        #TODO update args description line above
                        if {!$prevSaved} {
                            lappend out "#| en=$msg"
                        }
                        lappend out "en=$msg_code"
                    }
                } else {
                    # uid not found in source code
                    lappend out $line
                }
            }
            default {
                lappend out $line
            }
        }
    }
    
    # now append new sections (uid present in source code but missing in messages)
    dict for {uid tml} $uid2tml_code {
        lappend out ""
        lappend out "# $uid"
        set msg_code [lindex $tml 0]
        set params [params-list2dict [lrange $tml 1 end]]
        if {$params ne ""} {
            lappend out "#, [join $params " "]"
        }
        lappend out "en=$msg_code"
        foreach l $locales {
            lappend out "$l="
        }
    }
    
    spit $msgfile [join $out \n]
}

# Extract translatable messages with parameters from the line of source code
proc ::i18n::line-extract-tms {line} {
    set index 0
    set tms {}
    while {[regexp -start $index {.*?\[_\s+([^\]]+)\]} $line match sub]} {
        if {[string first {"} $sub] != 0} {
            error "Developer error. The first argument to the \[_ proc must be a properly quoted string"
        }
        lappend tms $sub
        incr index [string length $match]
    }
    return $tms
}

proc ::i18n::line-extract-uids {line} {
    set index 0
    set uids {}
    while {[regexp -start $index {.*?(_[\da-f]{16})} $line match sub]} {
        lappend uids $sub
        incr index [string length $match]
    }
    return $uids
}

# Parse source code file and create missing uid tokens in source file i.e. it may modify the source file
# Return dict mapping uid => (list of tm and its arguments)
proc ::i18n::code-uid-update {filename uid2tm_msg} {
    set uid2tml [dict create]
    set touched 0
    set out {}
    set code [slurp $filename]
    set lines [split $code \n]
    set lno 0
    foreach line $lines {
        incr lno
        # translatable messages with parameters
        set tms [line-extract-tms $line]
        # uid tokens
        set uids [line-extract-uids $line]

        # updated/enhanced uid list
        set uids_new [resolve-ambiguity $tms $uids $uid2tm_msg]
        
        if {[llength $tms] > 0} {
            puts "line: $line"
            puts "uids: $uids"
            puts "uids_new: $uids_new"
        }
        if {$uids ne $uids_new} {
            if {[regsub ";#\s*_" $line ";# $uids_new" newline]} {
                set line $newline
            } else {
                append line " ;# $uids_new"
            }
            set touched 1
        }

        foreach i [seq [llength $tms]] {
            dict set uid2tml [lindex $uids_new $i] [lindex $tms $i]
        }

        lappend out $line
    }

    # don't touch the source file if there were no changes
    if {$touched} {
        spit $filename [join $out \n]
    }
    return $uid2tml
}


# Parse messages file and build the dict mapping uid => enmsg
proc ::i18n::msg-prescan {msgfile} {
    set uid2tm [dict create]
    if {![file exists $msgfile] || ![file isfile $msgfile]} {
        return $uid2tm
    }
    set msgs [slurp $msgfile]
    set lines [split $msgs \n]
    set index 0
    set uids {}
    foreach line $lines {
        switch -regexp -matchvar token $line {
            {^\s*#\s*(_[\da-f]{16})} {
                # automatic comment - uids which means new section
                set index 0
                set uids {}
                while {[regexp -start $index {.*?(_[\da-f]{16})} $line match sub]} {
                    lappend uids $sub
                    incr index [string length $match]
                }
            }
            {^\s*en=(.*)$} {
                # tm
                set msg [lindex $token 1]
                #TODO handle multiple uids in the future - it may be tricky to handle changes. For now take the first uid
                foreach uid $uids {
                    dict set uid2tm $uid $msg
                }
            }
        }
    }
    return $uid2tm
}




# is-ambiguous is true also in simple case of tm without uid
proc ::i18n::is-ambiguous {tms uids} {
    return [expr {[llength $tms] != [llength $uids]}]
}


# Take as input the list of tms (translatable messages) and uids coming from the single line of source code
# and try to match them while handling non-trivial cases with missing uids
# uid2tms is the existing mapping from messages file
# tms is really the list of tms along with their parameters
# Return the updated list of uids. The result list may be enhanced or reduced comparing to the input uids
# Throw error if cannot resolve ambiguity
proc ::i18n::resolve-ambiguity {tms uids uid2tms} {
    set tlen [llength $tms]
    set ulen [llength $uids]
    if {$ulen == $tlen} {
        # nothing to do, all clear
        return $uids
    }
    if {$ulen > $tlen} {
        # Don't try to automatically handle redundant uids
        # This means that developer removed or moved the tm to a different line without deleting uid
        error "Developer error. Redundant uid in $uids."
    }
    if {$ulen < $tlen} {
        # now the fun begins

        # try to match the existing uids to tms
        set uids_res {}
        # build the list of empty boxes and fill them where matching
        foreach i [seq $tlen] {
            lappend uids_res {}
        }
        foreach uid $uids {
            # get existing tm from messages
            if {[dict exists $uid2tms $uid]} {
                set msgtm [dict get $uid2tms $uid]
            } else {
                error "Severe error. $uid - no such uid in messages file"
            }
            set found 0
            foreach i [seq $tlen] {
                set t [lindex $tms $i]
                # take tm without parameters
                set tm [lindex $t 0]
                if {$tm eq $msgtm} {
                    if {[lindex $uids_res $i] ne ""} {
                        error "Unresolvable ambiguity. '$tm' matching to more than one uid like $uid"
                    }
                    set uids_res [lreplace $uids_res $i $i $uid]
                    set found 1
                    break
                }
            }
            if {!$found} {
                error "Unresolvable ambiguity. Could not match translatable message or uid $uid currently mapping to '$msgtm'"
            }
        }

        # sanity check - we shouldn't be here if we did not match $ulen number of uids
        if {[lcount $uids_res] != $ulen} {
            error "sanity check failed - we shouldn't be here if we did not match $ulen number of uids"
        }

        # generate uids for remaining empty boxes
        foreach i [seq $tlen] {
            if {[lindex $uids_res $i] eq ""} {
                set uids_res [lreplace $uids_res $i $i [generate-uid]]
            }
        }
        return $uids_res
    }
}




# Parse messages file, compare its 'en' entries with translatable lines in source code. Update source code.
# This assumes that translator changed the original 'en' messages and source code needs to be updated.
# Throws error on any ambiguity (when not certain of uid => tm mapping in single line) in the source code
proc ::i18n::msg2code {filename {msgfile messages.txt}} {
    set uid2tm_msg [msg-prescan $msgfile]
    puts "u2m: $uid2tm_msg"


    set touched 0
    set out {}
    set code [slurp $filename]
    set lines [split $code \n]
    set lno 0
    foreach line $lines {
        incr lno
        # translatable messages with parameters
        set tms [line-extract-tms $line]
        # uid tokens
        set uids [line-extract-uids $line]
        set ulen [llength $uids]

        if {$ulen > 0 && [is-ambiguous $tms $uids]} {
            error "Could not update source code because of uid ambiguity in $filename:$lno: '$line'"
        }
        foreach i [seq $ulen] {
            set uid [lindex $uids $i]
            # take tm without parameters
            set tm [lindex [lindex $tms $i] 0]
            if {[dict exists $uid2tm_msg $uid]} {
                set msgtm [dict get $uid2tm_msg $uid]
            } else {
                error "Severe error. $uid - no such uid in messages file"
            }
            if {$msgtm ne $tm} {
                #TODO this replacement may be improved to prevent rare errors of wrong replacements
                #set line [string map [list $tm $msgtm] $line]
                set line [replace-nth-tm $line $i $tm $msgtm]
                set touched 1
            }
        }

        lappend out $line
    }

    # don't touch the source file if there were no changes
    if {$touched} {
        spit $filename [join $out \n]
    }
}

proc ::i18n::replace-nth-tm {line n tm newtm} {
    set index 0
    #puts "replace nth called with n=$n"
    foreach i [seq [expr {$n+1}]] {
        if {![regexp -indices -start $index {.*?\[_\s+([^\]]+)\]} $line match sub]} {
            error "Developer error. Could not find tm number $i in line: '$line'"
        }
        #puts "Processing tm $i: sub: $sub"
        set index [lindex $match 1]
    }
    # now we have indices of n-th tm in sub
    lassign $sub s etemp
    if {[string index $line $s] ne {"}} {
        error "Developer error. The first argument to the \[_ \] proc must be a properly quoted string"
    }
    set tm_with_params [string range $line $s $etemp]
    set tm_solo [lindex $tm_with_params 0]
    incr s
    set e [expr {$s + [string length $tm_solo] - 1}]

    set tm_retrieved [string range $line $s $e]
    #puts "replace-nth-tm: $line"
    #puts "tm:**$tm**"
    #puts "tm_with_params:**$tm_with_params**"
    #puts "tm_solo:**$tm_solo**"
    #puts "tm_retrieved:**$tm_retrieved**"

    # sanity check
    if {$tm ne $tm_retrieved} {
        error "Developer error. tm='$tm', tm_solo='$tm_solo', tm_retrieved='$tm_retrieved', newtm='$newtm'"
    }
    #TODO add newtm validation - it comes from messages file / translator,  so make sure that special characters are properly quoted
    #OR: quote using {} - but this would be Tcl specific
    set line [string replace $line $s $e $newtm]
    puts "newline: $line"

    return $line
}



# Delete previous '#|' messages from messages file
# Delete messages marked to remove from messages file
proc ::i18n::cleanup {} {
    #TODO
}

# Find messages from messages file that have no corresponding translatable line (by uid) in source code.
# Mark them to remove
proc ::i18n::orphans {} {
    #TODO
}

proc ::i18n::slurp {path} {
    set fd [open $path r]
    fconfigure $fd -encoding utf-8
    set data [read $fd]
    close $fd
    return $data
}

proc ::i18n::spit {path content} {
    set fd [open $path w]
    puts -nonewline $fd $content
    close $fd
}


proc ::i18n::rand-byte {} {
    return [expr {round(rand()*256)}]
}

proc ::i18n::rand-byte-hex {} {
    return [format %02x [rand-byte]]
}

proc ::i18n::seq {n} {
    set res {}
    for {set i 0} {$i < $n} {incr i} {
        lappend res $i
    }
    return $res
}

proc ::i18n::generate-uid {} {
    return _[join [lmap i [seq 8] {rand-byte-hex}] ""]
}


proc ::i18n::touch {file} {
    if {[file exists $file]} {
        file mtime $file [clock seconds]
    } else {
        set fh [open $file w]
        catch {close $fh}
    }
}

proc ::i18n::params-list2dict {params} {
    set d [dict create]
    set i 0
    foreach p $params {
        dict set d "{$i}" $p
        incr i
    }
    return $d
}

# Count non-empty elements of the list
proc ::i18n::lcount {a} {
    set c 0
    foreach e $a {
        if {$e ne ""} {
            incr c
        }
    }
    return $c
}

proc ::i18n::islist {a} {
    return [expr {[llength $a] > 1}]
}

