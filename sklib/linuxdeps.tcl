package provide linuxdeps 0.0.0

package require unix
package require skutil

namespace eval ::linuxdeps {
    variable pkgmgr2cmd 
    dict set pkgmgr2cmd apt-get "apt-get -fy install" 
    dict set pkgmgr2cmd zypper "zypper --non-interactive install" 
    dict set pkgmgr2cmd yum "yum -y install"
    variable pkgmgr2deps
    dict set pkgmgr2deps apt-get "libxft2 libx11-6 libfreetype6 libfontconfig1 libxrender1 libxss1 libxext6 zlib1g libxcb1 libexpat1 libxau6 libxdmcp6"
    dict set pkgmgr2deps zypper "libXft2 libX11-6 libfreetype6 fontconfig libXrender1 libXss1 libXext6 libz1 libxcb1 libexpat1 libXau6 libXdmcp6"	
    dict set pkgmgr2deps yum "libXft libX11 freetype fontconfig libXrender libXScrnSaver libXext zlib libxcb expat libXau libXdmcp"

    # finding package for library:
    # apt-file search libXss.so.1
    # zypper search --provides libXss.so.1
    # yum whatprovides libXss.so.1

    #In Debian: /etc/debian_version
    #In Ubuntu: lsb_release -a or /etc/debian_version
    #In Redhat: cat /etc/redhat-release
    #In Fedora: cat /etc/fedora-release
    #Read cat /proc/version
    # Prefer feature detection over distro detection

    namespace export is-openvpn-installed find-pkg-mgr find-pkg-mgr-cmd tkdeps-install openvpn-install ext2installer
    namespace ensemble create
}



proc ::linuxdeps::find-pkg-mgr {} {
    memoize
    # detect in the order: zypper, apt-get, yum (others: pacman, portage, urpmi, dnf, slapt-geti emerge)
    set candidates {zypper apt-get yum}
    foreach c $candidates {
        if {![catch {exec $c --version}]} {
            return $c
        }
    }
    return ""
}


proc ::linuxdeps::find-pkg-mgr-cmd {} {
    memoize
    variable pkgmgr2cmd
    set pkg_mgr [linuxdeps find-pkg-mgr]
    if {[llength $pkg_mgr] > 0} {
        return [dict get $pkgmgr2cmd $pkg_mgr]
    } else {
        puts "Could not find package manager"
    }
    return ""
}

proc ::linuxdeps::is-openvpn-installed {} {
    # Unfortunately openvpn always returns exit code 1
    catch {exec openvpn --version} out err
    # So check if openvpn output starts with "OpenVPN"
    return [expr {[string first OpenVPN $out] == 0}]
}
 

# Check if openvpn installed, install if needed
# No errors raised, best effort
proc ::linuxdeps::openvpn-install {} {
    variable pkgmgr2cmd
    if {![is-openvpn-installed]} {
        set pkgcmd [linuxdeps find-pkg-mgr-cmd]
        if {[llength $pkgcmd] > 0} {
            exec {*}$pkgcmd openvpn >&@ stdout
        }
    }
}


proc ::linuxdeps::tkdeps-install {} {
    variable pkgmgr2cmd
    variable pkgmgr2deps
    if {[unix is-x-running]} {
        if {[catch {package require Tk} out err]} {
            set pkg_mgr [linuxdeps find-pkg-mgr]
            if {[llength $pkg_mgr] > 0} {
                set pkgcmd [dict get $pkgmgr2cmd $pkg_mgr]
                set deps [dict get $pkgmgr2deps $pkg_mgr]
                exec {*}$pkgcmd {*}$deps >&@ stdout
            }
        } else {
            wm withdraw .
            destroy .
        }
    }
}

proc ::linuxdeps::ext2installer {ext} {
    if {$ext eq "deb"} {
        return dpkg
    } elseif {$ext eq "rpm"} {
        return rpm
    } else {
        error "Unrecognized extension in ext2installer: $ext"
    }
}

