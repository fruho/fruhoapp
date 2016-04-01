
package require skutil

namespace eval ::from_file {
    namespace export *
    namespace ensemble create

    variable name from_file
    variable dispname "From file"
    # input entries - resettable/modifiable variables
    variable newprofilename ""
}


proc ::from_file::create-import-frame {tab} {
    variable name
    variable dispname

    set ::${name}::newprofilename [unique-profilename "My Profile"]

    set pconf $tab.$name
    ttk::frame $pconf

    addprovider-gui-profilename $tab $name

    ttk::frame $pconf.select
    ttk::label $pconf.select.msg -text "Select configuration files" -anchor e
    ttk::button $pconf.select.button -image [img load 16/logo_from_file] -command [list go ::from_file::SelectFileClicked $pconf]
    grid $pconf.select.msg -row 0 -column 0 -sticky news -padx 5 -pady 5
    grid $pconf.select.button -row 0 -column 1 -sticky e -padx 5 -pady 5
    grid columnconfigure $pconf.select 0 -weight 1
    ttk::label $pconf.selectinfo -foreground grey

    hypertext $pconf.link "<https://fruho.com/howto/1><How to get config files?>"
    grid $pconf.select -row 4 -column 0 -sticky news -columnspan 2
    grid $pconf.selectinfo -row 4 -column 2 -sticky news

    addprovider-gui-importline $tab $name
    grid $pconf.link -sticky news -columnspan 3 -padx 10 -pady 10
    return $pconf
}
        
proc ::from_file::add-to-treeview-plist {plist} {
    variable name
    variable dispname
    $plist insert {} end -id $name -image [img load 16/logo_$name] -values [list $dispname]
}


proc ::from_file::SelectFileClicked {pconf} {
    # "Select configuration files"
    # "Press Control to select multiple files"
    set files [tk_getOpenFile -multiple 1]  ;# possible -initialdir option
    if {$files ne ""} {
        set ::model::Gui_selected_files $files
        $pconf.select.msg configure -text "[llength $::model::Gui_selected_files] file(s) selected"
        $pconf.importline.button configure -state normal
    }
}


# this is csp coroutine
proc ::from_file::ImportClicked {tab name} {
    try {
        set newprofilename [set ::${name}::newprofilename]
        set pconf $tab.$name
    
        importline-update $pconf "Importing configuration from file" disabled spin

        set profileid [name2id $newprofilename]
        if {[are-selected-files-correct $::model::Gui_selected_files]} {
            set tempdir [copy2temp $::model::Gui_selected_files]
            log "tempdir: $tempdir"
    
            # find ovpn file in the bundle, if many take first
            set ovpn [convert-config $tempdir]
            if {$ovpn eq ""} {
                importline-update $pconf "No openvpn config in selected files" normal empty
                return
            }
            set ovpnfile [ovpndir $profileid config.ovpn]
            spit $ovpnfile $ovpn
            # parse config now in order to extract separate cert files
            ::ovconf::parse $ovpnfile
    
            set slist [extract-servers $tempdir]
            log "slist: $slist"
            if {$slist eq ""} {
                importline-update $pconf "No server candidates in selected files" normal empty
                return
            }
    
            set plan [dict create name $newprofilename timelimit [dict create start 0 period month nop 1000000] trafficlimit [dict create used 0 quota 1000000000] slist $slist]
            dict set ::model::Profiles $profileid plans [dict create planid_1 $plan]
            dict set ::model::Profiles $profileid profilename $newprofilename
            dict set ::model::Profiles $profileid provider $name

            # expose as an option to the user to export server list in various formats
            # after 10000 [list temp-export-call $profileid planid_1]

            # Delay in resolving server list domains - allow for completing the slist by appenders like in add_cyberghost
            after 1000 go update-bulk-sitem $profileid
        
            # when repainting tabset select the newly created tab
            set ::model::selected_profile [name2id $newprofilename]
            tabset-profiles .c.tabsetenvelope
            importline-update $pconf "" normal empty
        } else {
            importline-update $pconf "Selected files are incorrect" normal empty
        }
    } on error {e1 e2} {
        puts stderr [log $e1 $e2]
    }
}


proc temp-export-call {profileid planid} {
    ::model::slist-export-golang [::model::slist $profileid $planid]
}



# to eliminate obvious wrong file candidates upfront
proc are-selected-files-correct {files} {
    if {$files eq ""} {
        return 0
    }
    foreach f $files {
        set ext [file extension $f]
        if {$ext in {.doc .xls .ppt .mp3 .m4a .wav .wma .mpg .mp4 .avi .png .gif .jpg}} {
            return 0
        }
    }
    return 1
}


# copy and unzip in temporary folder
proc ::from_file::copy2temp {files} {
    set tempdir /tmp/from_file_[rand-big]
    file mkdir $tempdir
    foreach f $files {
        if {[string match *.zip $f]} {
            unzip $f $tempdir
        } elseif {[string match *.gz $f]} {
            set outfile [gunzip $f $tempdir]
            if {[string match *.tar $outfile]} {
                untar $outfile $tempdir
            }
        } elseif {[string match *.tar $f]} {
            untar $f $tempdir
        } else {
            file copy $f $tempdir
        }
    }
    return $tempdir
}

proc ::from_file::find-ovpn-in {dir pattern {find_all 0}} {
    set files {}
    foreach f [glob -nocomplain -directory $dir -type f $pattern] {
        set looks [ovconf looks-like-ovpn $f] 
        if {[ovconf looks-like-ovpn $f] > 40} {
            lappend files $f
            if {!$find_all} {
                break
            }
        }
    }
    return $files
}


# Convert 3rd party config into Fruho config
# take directory with the unzipped config files
# return ovpn config with inline certs
# If many ovpn configs found take the first one
proc ::from_file::convert-config {tempdir} {
    set ovpnfile [find-ovpn-in $tempdir *]
    if {$ovpnfile eq ""} {
        set ovpnfile [find-ovpn-in $tempdir */*]
    }
    if {$ovpnfile eq ""} {
        set ovpnfile [find-ovpn-in $tempdir */*/*]
    }
    if {$ovpnfile eq ""} {
        return ""
    }
    # take the first found ovpn file
    set ovpnfile [lindex $ovpnfile 0]
    set ovpn [slurp $ovpnfile]
    append ovpn \n
    if {[ovconf inline-section-coords $ovpn ca] eq ""} {
        set cafile [ovconf raw-get $ovpn ca]
        
        set cafile [file normalize [file join [file dir $ovpnfile] $cafile]]
        
        if {[file isfile $cafile]} {
            set ovpn [ovconf raw-del $ovpn ca]
            set ca [slurp $cafile]
            append ovpn "\n<ca>\n"
            append ovpn $ca
            append ovpn "\n</ca>\n"
        }

        set certfile [ovconf raw-get $ovpn cert]
        set certfile [file normalize [file join [file dir $ovpnfile] $certfile]]
        if {[file isfile $certfile]} {
            set ovpn [ovconf raw-del $ovpn cert]
            set cert [slurp $certfile]
            append ovpn "\n<cert>\n"
            append ovpn $cert
            append ovpn "\n</cert>\n"
        }
        set keyfile [ovconf raw-get $ovpn key]
        set keyfile [file normalize [file join [file dir $ovpnfile] $keyfile]]
        if {[file isfile $keyfile]} {
            set ovpn [ovconf raw-del $ovpn key]
            set key [slurp $keyfile]
            append ovpn "\n<key>\n"
            append ovpn $key
            append ovpn "\n</key>\n"
        }
    }

    set ovpn [ovconf raw-del $ovpn remote]
    set ovpn [ovconf raw-del $ovpn proto]
    return $ovpn
}

# return slist - a list of sitem dicts
proc ::from_file::extract-servers {tempdir} {
    # this time find all ovpn config files
    set files [find-ovpn-in $tempdir * 1]
    set files [concat $files [find-ovpn-in $tempdir */* 1]]
    set files [concat $files [find-ovpn-in $tempdir */*/* 1]]
    # list of triples {host proto port}
    set endpoints {}
    log "extract-servers files: $files"
    foreach f $files {
        log "Processing $f"
        set ovpn [slurp $f]
        log "slurp ovpn: $ovpn"
        set remotes [ovconf raw-get $ovpn remote]
        set remotes [concat $remotes [ovconf raw-get $ovpn #remote]]
        set remotes [concat $remotes [ovconf raw-get $ovpn "# remote"]]
        log "remotes: $remotes"
        set proto [ovconf raw-get $ovpn proto]
        foreach r $remotes {
            # if proto not given in a separate line in config try to get proto from the remote line (ibVPN provides such config)
            if {$proto eq ""} {
                lassign $r host port proto
            } else {
                lassign $r host port
            }
            if {[is-valid-host $host] && [is-valid-port $port] && [is-valid-proto $proto]} {
                set triple [list $host $proto $port]
                lappend endpoints $triple
            }
        }
    }
    set endpoints [lunique $endpoints]

    #TODO resolve hostnames


    set slist {}
    if {[llength $endpoints] > 0} {
        set slist [create-slist $endpoints]
    } else {
        # try to find a single file with IP addresses as VPN endpoints
        set files [glob -nocomplain -directory $tempdir -type f *]
        set files [concat $files [glob -nocomplain -directory $tempdir -type f */*]]
        set files [concat $files [glob -nocomplain -directory $tempdir -type f */*/*]]

        # Find file with biggest number of IP addresses
        # tuple2 of file and # of ips in file - to save the file with max ips
        set max_file_ip {"" 0}
        foreach f $files {
            set s [slurp $f]
            set count [llength [find-ips $s]]
            if {$count > [lindex $max_file_ip 1]} {
                set max_file_ip [list $f $count]
            }
        }

        if {[lindex $max_file_ip 0] ne "" && [lindex $max_file_ip 1] != 0} {
            set ips [find-ips [slurp [lindex $max_file_ip 0]]]
            set endpoints {}
            foreach ip $ips {
                # assume common proto port combinations
                foreach {proto port} {tcp 443 tcp 993 udp 443 udp 53 udp 5000 udp 5353} {
                    set triple [list $ip $proto $port]
                    lappend endpoints $triple
                }
            }
            set slist [create-slist $endpoints]
        }

    }
    return $slist
}

proc ::from_file::find-ips {s} {
    set ips {}
    foreach ip [regexp -all -inline -- {\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}} $s] {
        if {[is-valid-ip $ip]} {
            lappend ips $ip
        }
    }
    return [lunique $ips]
}



# take list of triples {ip proto port} and return slist as per model
proc ::from_file::create-slist {endpoints} {
    set slist {}
    set endpoints [lunique $endpoints]
    # mapping ip => endpoint
    set ipdict [dict create]
    foreach triple $endpoints {
        lassign $triple ip proto port
        dict lappend ipdict $ip $triple
    }
    set id 1
    dict for {ip triplelist} $ipdict {
        set ovses {}
        foreach triple [lunique $triplelist] {
            lassign $triple _ proto port
            set ovs [dict create proto $proto port $port]
            lappend ovses $ovs
        }
        set sitem [dict create id $id ccode "" country "" city "" ip $ip ovses $ovses]
        lappend slist $sitem
        incr id
    }
    return $slist
}


lappend ::model::Supported_providers {900 from_file}
