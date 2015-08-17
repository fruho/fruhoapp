package provide inicfg 0.0.0

# *.ini config parser. Supports hierarchical sections
# inicfg load $path - return dict
# inicfg save $path $config - save $config dict

# Sample ini file
# first=1111111 aaaaaa
#
# second=22222222 bbbbbbb
#
# add1=dodane
#
# [HOST]
# #keyvalue
# third=33333 cccc ccc
#
# [PORT]
# forth=4444444 dddddd
#
# add2=ddddoodda
#
# [PORT.FIRST.SECOND]
# fifth=55555
#
# [PORT.FIRST]
# add3=duuuddd
#

namespace eval ::inicfg {
    namespace export load save dict-pretty
    namespace ensemble create
}

proc ::inicfg::slurp {path} {
    set fd [open $path r]
    set data [read $fd]
    close $fd
    return $data
}

proc ::inicfg::spit {path content} {
    set fd [open $path w]
    puts -nonewline $fd $content
    close $fd
}

# Load ini file and return as dictionary
# ini file may have bracketed sections
# section names may be multi-level with parts separated by dots
# what creates nested dictionary
proc ::inicfg::load {path} {
    set data [slurp $path]
    set lines [split $data \n]
    set lines [lmap line $lines {string trim $line}]
    set res [dict create]
    set sections {}
    # start with default section
    set section ""
    foreach line $lines {
        switch -regexp -matchvar v $line {
            {^$} {}
            {^[#;].*} {}
            {^\[(.*)\]$} {
                if {[lindex $v 1] in $sections} {
                    error "Error parsing $path. Multiple sections $line"
                }
                set section [lindex $v 1]
                lappend sections $section
            }
            {^([^=]*)=(.*)$} {
                set name [lindex $v 1]
                set value [lindex $v 2]
                dict set res {*}[split $section .] $name $value
            }
            default {
                error "Error parsing $path. Unexpected '$line'"
            }
        }
    }
    return $res
}


proc ::inicfg::save {path config} {
    set res {}
    ::inicfg::serialize res $config
    file mkdir [file dir $path]
    spit $path [join $res \n]
}

# args is the list of keys that address (as a path in nested dict) the subtree in the total config dict
proc ::inicfg::serialize {result config args} {
    upvar $result res
    if {[isdict [dict get $config {*}$args]]} {
        set leaves [dict-leaves $config {*}$args]
        if {$leaves ne ""} {
            if {[llength $args] != 0} {
                lappend res "\n\[[join $args .]\]"
            }
            foreach {k v} $leaves {
                lappend res "$k=$v"
            }
        }
        set nonleaves [dict-nonleaves $config {*}$args]
        foreach {k v} $nonleaves {
            ::inicfg::serialize res $config {*}$args $k
        }
    }
}


proc ::inicfg::orig_isdict {v} { 
   string match "value is a dict *" [::tcl::unsupported::representation $v] 
} 



# heuristic/duck typing way to determine if this is a dictionary
proc ::inicfg::isdict {v} { 
    set len [llength $v]
    # dict must be even length
    if {$len % 2 == 1} {
        return 0
    }
    # keys must be single word lowercase strings
    for {set i 0} {$i < $len} {incr i 2} {
        if {![regexp {^([a-z0-9_]+)$} [lindex $v $i]]} {
            return 0
        }
    }
    # also if all values are simple words treat it as a string
    set are_simple_words 1
    for {set i 1} {$i < $len} {incr i 2} {
        if {![regexp {^(\w+)$} [lindex $v $i]]} {
            set are_simple_words 0
        }
    }
    if {$are_simple_words} {
        return 0
    }
    return 1
}



######################### 
# convert dictionary value dict into string 
# hereby insert newlines and spaces to make 
# a nicely formatted ascii output 
# The output is a valid dict and can be read/used 
# just like the original dict 
############################# 
# copy of this proc is also in skutil.tcl
proc ::inicfg::dict-pretty {d {indent ""} {indentstring "    "}} {
   # unpack this dimension 
   dict for {key value} $d { 
      if {[isdict $value]} { 
         append result "$indent[list $key]\n$indent\{\n" 
         append result "[dict-pretty $value "$indentstring$indent" $indentstring]\n" 
         append result "$indent\}\n" 
      } else { 
         append result "$indent[list $key] [list $value]\n" 
      }
   }
   return $result 
}

# Get dict consisting of leaves only key-value pairs in the d's subtree specified by args (as path in nested dict)
proc ::inicfg::dict-leaves {d args} {
    set res [dict create]
    dict for {key value} [dict get $d {*}$args] {
        if {![isdict $value]} {
            dict set res $key $value
        }
    }
    return $res
}

proc ::inicfg::dict-nonleaves {d args} {
    set res [dict create]
    dict for {key value} [dict get $d {*}$args] {
        if {[isdict $value]} {
            dict set res $key $value
        }
    }
    return $res
}


