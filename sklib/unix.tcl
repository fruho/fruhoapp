package provide unix 0.0.0
package require Tclx

namespace eval ::unix {
    namespace export *
    namespace ensemble create
}


# Note: 
# Does the superuser account always have uid/gid 0/0 on Linux?
# Yes. There's code in the kernel which explicitly checks for uid 0 when needing to check for the root user, which means that root always has at least uid 0.

# Is the name of the user account with uid 0 always root?
# No. root is just a name, listed in /etc/passwd or some other authentication store. You could just as well call the account admin, and the OS itself won't care, but some applications might not quite like it because they expect there to exist a privileged account named root. Calling the uid 0 account on a *nix root is a very strongly held convention, but it isn't required by the system.



# Best effort drop superuser rights
# If Unix user originally was logged as non-root (from logname)
# drop root privileges by changing uid and gid and return that user name
# Do nothing if root from the ground up, return "root" then
# Also do nothing if currently non-root
proc ::unix::relinquish-root {} {
    # First check the current privileges (has-root as opposed to is-root)
    # id command from Tclx package
    if {![::unix::has-root]} {
        return [id user]
    }
    # Next, if currently root, check how the user logged in (from logname or sudo variables)
    # When running starpack in background (with &) logname may error with "logname: no login name"
    if {[catch {exec logname} user]} {
        # Fall back to checking SUDO_USER
        set user $::env(SUDO_USER)
        # If empty then I don't know, assume root
        if {[llength $user] == 0} {
            set user root
        }
    }
    # user not only has root now but also logged as a root (is-root as opposed to has-root) so we can't relinquish root
    if {$user eq "root"} {
        return root
    }
    set primary_group [exec id -g -n $user]
    # the order is relevant - first change gid then uid
    id group $primary_group
    id user $user
    return $user
}


# Check if current user has root privileges
proc ::unix::has-root {} {
    # check uid instead of [id user] ne "root" 
    return [expr {[id userid] == 0}]
}



# Check if X11 server is running
# by probing existence of $DISPLAY env variable
proc ::unix::is-x-running {} {
    return [expr {[array get ::env DISPLAY] ne ""}]
}

# locate desktop dir for current user
proc ::unix::get-desktop-dir {} {
    set userdirs [file normalize ~/.config/user-dirs.dirs]
    set desktop Desktop
    if {[file exists $userdirs]} {
        set content [slurp $userdirs]
        # the match will update desktop var
        regexp {XDG_DESKTOP_DIR="\$HOME/([^"]+)"} $content --> desktop
    }
    if {[llength $desktop] > 3 || [string length $desktop] > 20} {
        set desktop Desktop
    }
    set desktopdir [file normalize "~/$desktop"]
    return $desktopdir
}

# Create pulpit shortcut
# Place .desktop launcher in Desktop directory
proc ::unix::add-launcher {appname} {
    set desktopdir [::unix::get-desktop-dir]
    if {[file exists $desktopdir]} {
        file copy -force /usr/share/applications/$appname.desktop $desktopdir
        file attributes [file join $desktopdir $appname.desktop] -permissions ugo+rx
    }
}

# Remove pulpit shortcut
# Delete .desktop launcher from Desktop directory
proc ::unix::remove-launcher {appname} {
    set desktopdir [::unix::get-desktop-dir]
    set launcher [file join $desktopdir $appname.desktop]
    if {[file exists $launcher]} {
        file delete $launcher
    }
}
