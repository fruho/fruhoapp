package provide img 0.0.0

package require anigif

namespace eval ::img {
    namespace export *
    namespace ensemble create
    # we keep a map lbl => img to prevent overwriting anigifs on unecessary img place
    variable anigif_lbl2img [dict create]
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


# Create image object in the context of the caller and return its name
# e.g. ::img::load flag/pl will look for images/flag/pl.png or images/flag/pl.gif 
# and will load image under the name flag_pl and return that name
proc ::img::load {imgptr} {
    memoize
    set imgobj [string map {/ _} $imgptr]
    #TODO check if replacing / with \ is necessary on windows
    uplevel [list image create photo $imgobj -file [::img::path $imgptr]]
    return $imgobj
}


# we keep a map lbl => img:
# - do nothing when trying to place already placed image on the same label
proc ::img::place {imgptr lbl {imgptr_default 16/missing}} {
    variable anigif_lbl2img
    if {![::img::exists $imgptr]} {
        set imgptr $imgptr_default
    }
    # sort of caching to prevent anigifs flickering when unnecessarily updated 
    if {[dict exists $anigif_lbl2img $lbl]} {
        if {[dict get $anigif_lbl2img $lbl] eq $imgptr} {
            # do nothing if that image is already on that lbl
            return
        } else {
            # must be a different image so clear cache
            dict unset anigif_lbl2img $lbl
        }
    }
    anigif::stop $lbl
    if {[::img::ext $imgptr] eq ".gif"} {
        # must use non-ttk label $lbl for proper animated gif display
        if {[winfo class $lbl] eq "Label"} {
            anigif::anigif [::img::path $imgptr] $lbl
            dict set anigif_lbl2img $lbl $imgptr
        } else {
            error "img::place: You should use plain label (not ttk::label) to display animated gif"
        }
    } else {
        $lbl configure -image [::img::load $imgptr]
    }
}
