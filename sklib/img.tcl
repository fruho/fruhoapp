package provide img 0.0.0

package require anigif

namespace eval ::img {
    namespace export *
    namespace ensemble create
}


proc ::img::memoize {} {
    set cmd [info level -1]
    if {[info level] > 2 && [lindex [info level -2] 0] eq "memoize"} return
    if {![info exists ::Memo($cmd)]} {set ::Memo($cmd) [eval $cmd]}
    return -code return $::Memo($cmd)
}


# Convert image pointer to image root name
# Example:   flag/pl  ->  <scriptroot>/images/flag/pl
proc ::img::root {imgptr} {
    memoize
    return [file join [file dir [info script]] images $imgptr]
}


# Return .png or .gif for given imgptr (image pointer)
# e.g. flag/pl is a pointer to images/flag/pl.png or images/flag/pl.gif 
# depending on which one is present
proc ::img::ext {imgptr} {
    memoize
    set imgpath [::img::root $imgptr]
    foreach ext {.png .gif} {
        if {[file exists ${imgpath}${ext}]} {
           return $ext
       }
    }
    puts stderr "WARNING: ::img::ext could not find image for $imgptr ($imgpath)"
    # if image not found return .png
    return .png
}

proc ::img::path {imgptr} {
    memoize
    return [::img::root $imgptr][::img::ext $imgptr]
}

proc ::img::exists {imgptr} {
    set imgpath [::img::root $imgptr]
    set ext [::img::ext $imgptr]
    return [file exists ${imgpath}${ext}]
}

proc ::img::name {imgptr} {
    #TODO check if replacing / with \ is necessary on windows
    return [string map {/ _} $imgptr]
}

# Create image object in the context of the caller and return its name
# e.g. ::img::load flag/pl will look for images/flag/pl.png or images/flag/pl.gif 
# and will load image under the name flag_pl and return that name
proc ::img::load {imgptr} {
    memoize
    set imgname [::img::name $imgptr]
    uplevel [list image create photo $imgname -file [::img::path $imgptr]]
    return $imgname
}


proc ::img::place {imgptr lbl {imgptr_default 16/missing}} {
    if { ![winfo exists $lbl] } {
        return
    }
    if {![::img::exists $imgptr]} {
        set imgptr $imgptr_default
    }
    # prevent anigifs flickering when unnecessarily updated 
    # do nothing when trying to place already placed image on the same label
    if {[$lbl cget -image] eq [::img::name $imgptr]} {
        return
    }
    anigif::stop $lbl
    if {[::img::ext $imgptr] eq ".gif"} {
        # can use both label and ttk::label now (after fixing anigif)
        anigif::anigif [::img::path $imgptr] $lbl 0 [::img::load $imgptr]
    } else {
        $lbl configure -image [::img::load $imgptr]
    }
}
