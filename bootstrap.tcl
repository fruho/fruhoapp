# This should be the preamble to every application
# It makes it possible to run as starpack or as a sourced script
if {![catch {package require starkit}]} {
  #this is to initialize starkit variables
  starkit::startup
}

set builddate [clock format [clock seconds] -gmt 1]

proc ex {args} {
    return [exec -- {*}$args >&@ stdout]
}

# only for text files, assumes utf-8 encoding
proc slurp {path} {
    set fd [open $path r]
    fconfigure $fd -encoding utf-8
    set data [read $fd]
    close $fd
    return $data
}

proc spit {path content} {
    set fd [open $path w]
    puts -nonewline $fd $content
    close $fd
}

proc generalize-arch {arch} {
    switch -glob $arch {
        i?86 {return ix86}
        x86_64 {return x86_64}
        default {error "Unrecognized CPU architecture"}
    }
}

proc this-arch {} {
    return [generalize-arch $::tcl_platform(machine)]
}

proc this-os {} {
    switch -glob $::tcl_platform(os) {
        Linux {return linux}
        Windows* {return win32}
        default {error "Unrecognized OS"}
    }
}

package require http
package require vfs::zip

proc platforminfo {} {
    puts "Script name: $::argv0"
    puts "Arguments:\n[join $::argv \n]"
    puts "Current directory: [pwd]"
    puts "This is Tcl version $::tcl_version , patchlevel $::tcl_patchLevel"
    puts "[info nameofexecutable] is [info tclversion] patch [info patchlevel]"
    puts "Directory(s) where package require will search:"
    puts "$::auto_path"
    puts "tcl_libPath = $::tcl_libPath"  ;# May want to skip this one
    puts "tcl_library = $::tcl_library"
    puts "info library = [info library]"
    puts "Shared libraries are expected to use the extension [info sharedlibextension]"
    puts "platform information:"
    parray ::tcl_platform
}

proc locate-fpm {} {
    if {[catch {exec fpm --version}] != 1} {
        return fpm
    } elseif {[catch {exec fpm.ruby2.1 --version}] != 1} {
        return fpm.ruby2.1
    } else {
        return ""
    }
}

proc find-pkg-mgr {} {
    # detect in the order: zypper, apt-get, yum (others: pacman, portage, urpmi, dnf, slapt-geti emerge)
    set candidates {zypper apt-get yum}
    foreach c $candidates {
        if {![catch {exec $c --version}]} {
            return $c
        }
    }
    return ""
}

proc install-fpm {} {
    if {[locate-fpm] eq ""} {
        puts "Installing fpm"

        set pkgmgr [find-pkg-mgr]
        if {$pkgmgr eq "apt-get"} {
            ex sudo apt-get update --fix-missing
            ex sudo apt-get -fy install git ruby-full ruby-dev gcc rpm make
            catch {ex sudo apt-get -fy install rubygems}
            ex sudo apt-get -fy install rubygems-integration
        } elseif {$pkgmgr eq "zypper"} {
            ex sudo zypper --non-interactive install ruby-devel gcc make rpm-build
        } elseif {$pkgmgr eq "yum"} {
            ex sudo yum -y install ruby-devel gcc make rpm-build
        }

        ex sudo gem install fpm

    } else {
        puts "fpm already present"
    }
}



#TODO test for rpms
proc fpm-arch {arch} {
    if {$arch eq "x86_64"} {
        return x86_64
    } elseif {$arch eq "ix86"} {
        return i386
    } else {
        error "fpm-arch unrecognized arch: $arch"
    }
}



# also in sklib
proc unzip {zipfile {destdir .}} {
  set mntfile [vfs::zip::Mount $zipfile $zipfile]
  foreach f [glob [file join $zipfile *]] {
    file copy -force $f $destdir
  }
  vfs::zip::Unmount $mntfile $zipfile
}

# convert pkg-name-1.2.3 into "pkg-name 1.2.3" or
# convert linux-ix86 into "linux ix86"
proc split-last-dash {s} {
  set dashpos [string last - $s]
  if {$dashpos > 0} {
    return [string replace $s $dashpos $dashpos " "]
  } else {
    error "Wrong name to split: $s. It should contain at least one dash"
  }
}


# Package presence is checked in the following order:
# 1. is pkg-ver in lib?             => copy to build dir
# 2. is pkg-ver in teapot-cache?    => prepare, unpack to lib dir, delete other versions in lib dir
# 3. is pkg-ver in tepot repo?      => fetch to teapot-cache dir


# first prepare-pkg and copy from lib to build
proc copy-pkg {os arch pkgname ver proj} {
  prepare-pkg $os $arch $pkgname $ver
  set libdir [file join build $proj $os-$arch $proj.vfs lib]
  #puts "Copying package $pkgname-$ver to $libdir"
  if {\
    [catch {file copy -force [file join lib $os-$arch $pkgname-$ver] $libdir}] &&\
    [catch {file copy -force [file join lib generic $pkgname-$ver]   $libdir}]} {
      #if both copy attempts failed raise error
      error "Could not find $pkgname-$ver neither in lib/$os-$arch nor lib/generic"
  }
}


proc suffix_exec {os} {
  array set os_suffix {
    linux .bin
    win32 .exe
  }
  return $os_suffix($os)
}

# recursively copy contents of the $from dir to the $to dir 
# while overwriting items in $to if necessary
# ignore files matching glob pattern $ignore
proc copy-merge {from to {ignore ""}} {
    file mkdir $to
    foreach f [glob [file join $from *]] {
        set tail [file tail $f]
        if {![string match $ignore $tail]} {
            if {[file isdirectory $f]} {
                set new_to [file join $to $tail]
                file mkdir $new_to
                copy-merge $f $new_to
            } else {
                file copy -force $f $to
            }
        }
    }
}


proc build {os arch_exact proj base {packages {}}} {
    set arch [generalize-arch $arch_exact]
    puts "\nStarting build ($os $arch $proj $base $packages)"
    if {![file isdirectory $proj]} {
      puts "Could not find project dir $proj"
      return
    }
    set bld [file join build $proj $os-$arch]
    puts "Cleaning build dir $bld"
    file delete -force $bld
    file mkdir [file join $bld $proj.vfs lib]
    # we don't copy base-tcl/tk to build folder. Having it in lib is enough - hence prepare-pkg
    prepare-pkg $os $arch {*}[split-last-dash $base]
    foreach pkgver $packages {
        copy-pkg $os $arch {*}[split-last-dash $pkgver] $proj
    }
    set vfs [file join $bld $proj.vfs]
    puts "Copying project source files to VFS dir: $vfs"
  
    copy-merge $proj $vfs exclude
    set cmd [list [info nameofexecutable] sdx.kit wrap [file join $bld $proj[suffix_exec $os]] -vfs [file join $bld $proj.vfs] -runtime [file join lib $os-$arch $base]]
    puts "Building starpack $proj"
    puts $cmd
    ex {*}$cmd
}

proc run {proj} {
    ex [info nameofexecutable] [file join build $proj [this-os]-[this-arch] $proj.vfs main.tcl]
}


proc prepare-lib {pkgname ver} {
    set dest [file join lib generic $pkgname-$ver]
    file delete -force $dest
    file mkdir $dest
    copy-merge $pkgname $dest
    pkg_mkIndex $dest
}

proc doc {path} {
    package require doctools
    ::doctools::new mydtp -format html
    set path [file normalize $path]
    set dest [file join [file dir $path] [file root [file tail $path]].html]
    spit $dest [mydtp format [slurp $path]]
}


# tarch - teapot specific architecture like linux-glibc2.3-x86_64
proc tarch {os arch} {
    #TODO macosx
    switch -exact $os {
        linux {return $os-glibc2.3-$arch}
        win32 {return $os-$arch}
        default {error "Unrecognized os: $os"}
    }
}

proc ctype2ext {ctype} {
    switch -glob $ctype {
        *application/x-zip* {return .zip}
        *application/octet-stream* {return ""}
        *text/plain* {return .tcl}
        default {error "Unrecognized Content-Type: $ctype"}
    }
}



# return random 0 <= x < $n
proc rand-int {n} {
    return [expr {round(floor(rand()*$n))}]
}

# return 9-digit random integer
proc rand-big {} {
    return [expr {100000000 + [rand-int 900000000]}]
}


# return the path to the cached package
proc teacup-fetch {os arch pkgname ver} {
    set nv $pkgname-$ver
    if {[string match base-* $pkgname]} {
        set type application
        set tarch_list [list [tarch $os $arch]]
    } else {
        set type package
        set tarch_list [list tcl [tarch $os $arch]]
    }
    set tcdir [teapot-cache]
    foreach tarch $tarch_list {
        set tcpath /$type/name/$pkgname/ver/$ver/arch/$tarch
        set tcpath_local [file normalize ../teapot-cache$tcpath]
        foreach ext {.tcl .zip ""} {
            set f $tcpath_local/$nv$ext
            if {[file isfile $f]} {
                puts stderr "Found cached $f"
                return $f
            }
        }
    }
    foreach tarch $tarch_list {
        set tcpath /$type/name/$pkgname/ver/$ver/arch/$tarch
        set tcpath_local [file normalize ../teapot-cache$tcpath]
        puts stderr "Fetching $nv-$tarch"
        try {
            set tmpfile /tmp/teacup_fetch_[rand-big]
            set url http://teapot.activestate.com$tcpath/file
            puts stderr "Fetching url: $url"
            set tok [http::geturl $url -channel [open $tmpfile w] -timeout 200000]
            upvar #0 $tok state
            if {[http::ncode $tok] == 200} {
                array set meta [http::meta $tok]
                puts stderr "Content-Type: $meta(Content-Type)"
                set ext [ctype2ext $meta(Content-Type)]
                puts stderr "ext=$ext"
                file mkdir $tcpath_local
                file rename -force $tmpfile $tcpath_local/$nv$ext
                return $tcpath_local/$nv$ext
            } else {
                puts stderr "Fetching ERROR: Received http response: [http::code $tok]"
            }
        } on error {e1 e2} {
            puts stderr "Could not fetch $nv ERROR: $e1 $e2"
        } finally {
            catch {set fd $state(-channel); close $fd;}
            catch {file delete $tmpfile}
            http::cleanup $tok
        }
    }
    error "Could not fetch $nv"
}

proc teapot-cache {} {
    set tcdir [file normalize ../teapot-cache]
    if {![file isdir $tcdir]} {
        ex git clone https://github.com/fruho/teapot-cache $tcdir
    }
    return $tcdir
}


proc prepare-pkg {os arch pkgname ver} {
    file mkdir [file join lib $os-$arch]
    set target_path_depend [file join lib $os-$arch $pkgname-$ver]
    set target_path_indep [file join lib generic $pkgname-$ver]
    # nothing to do if pkg exists in lib dir, it may be file or dir
    if {[file exists $target_path_depend]} {
      #puts "Already prepared: $target_path_depend"
      return
    }
    if {[file exists $target_path_indep]} {
      #puts "Already prepared: $target_path_indep"
      return
    }
    set localpkg [teacup-fetch $os $arch $pkgname $ver]
    puts "Preparing package $pkgname-$ver to place in lib folder"
    switch -glob $localpkg {
        */application/*/arch/* {
            file copy -force $localpkg $target_path_depend
            return 
        }
        */package/*/arch/tcl/*.tcl {
            file mkdir $target_path_indep
            file copy $localpkg $target_path_indep
            pkg_mkIndex $target_path_indep
            return
        }
        */package/*/arch/tcl/*.zip {
            file mkdir $target_path_indep
            #puts stderr "Unzipping to $target_path_indep"
            unzip $localpkg $target_path_indep
            return
        }
        */package/*.zip {
            file mkdir $target_path_depend
            #puts stderr "Unzipping to $target_path_depend"
            unzip $localpkg $target_path_depend
            return
        }
        default {error "Could not determine what to do with $localpkg"}
    }
}
 


#platforminfo

source build.tcl


