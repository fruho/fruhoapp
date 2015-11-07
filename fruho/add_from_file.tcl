
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
    variable newprofilename

    set newprofilename [unique-profilename "My Profile"]

    set pconf $tab.$name
    ttk::frame $pconf
    ttk::label $pconf.profilelabel -text "Profile name" -anchor e
    ttk::entry $pconf.profileinput -textvariable ::${name}::newprofilename
    ttk::label $pconf.profileinfo -foreground grey
    ttk::frame $pconf.select
    ttk::label $pconf.select.msg -text "Select configuration files" -anchor e
    ttk::button $pconf.select.button -image [img load 16/logo_from_file] -command [list go ::from_file::SelectFileClicked $pconf]
    grid $pconf.select.msg -row 0 -column 0 -sticky news -padx 5 -pady 5
    grid $pconf.select.button -row 0 -column 1 -sticky e -padx 5 -pady 5
    grid columnconfigure $pconf.select 0 -weight 1
    ttk::label $pconf.selectinfo -foreground grey

    ttk::frame $pconf.importline
    ttk::button $pconf.importline.button -state disabled -text "Import configuration" -command [list go ::${name}::ImportClicked $tab $name]
    # must use non-ttk label for proper animated gif display
    label $pconf.importline.img
    img place 24/empty $pconf.importline.img
    ttk::label $pconf.importline.msg
    grid $pconf.importline.button -row 0 -column 0 -padx 10
    grid $pconf.importline.img -row 0 -column 1 -padx 10 -pady 10
    grid $pconf.importline.msg -row 0 -column 2 -padx 10 -pady 10

    hypertext $pconf.link "<https://fruho.com/howto/1><How to get config files?>"

    grid columnconfigure $pconf 0 -weight 4 -uniform 1
    grid columnconfigure $pconf 1 -weight 4 -uniform 1
    grid columnconfigure $pconf 2 -weight 4 -uniform 1
    grid $pconf.profilelabel -row 1 -column 0 -sticky news -padx 5 -pady 5
    grid $pconf.profileinput -row 1 -column 1 -sticky news -padx 5 -pady 5
    grid $pconf.profileinfo -row 1 -column 2 -sticky news -pady 5
    grid $pconf.select -row 4 -column 0 -sticky news -columnspan 2
    grid $pconf.selectinfo -row 4 -column 2 -sticky news
    grid $pconf.importline -sticky news -columnspan 3
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
    set files [tk_getOpenFile -multiple 1 -initialdir /home/sk/configbundles/sk1]
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
            puts stderr "tempdir: $tempdir"
    
            set ovpn [convert-config $tempdir]
            puts stderr "\n$ovpn\n"
            set ovpnfile [ovpndir $profileid config.ovpn]
            spit $ovpnfile $ovpn
            # parse config now in order to extract separate cert files
            ::ovconf::parse $ovpnfile
    
            set slist [extract-servers $tempdir]
            puts stderr "slist: $slist"
    
            set plan [dict create name $newprofilename timelimit [dict create start 0 period month nop 1000000] trafficlimit [dict create used 0 quota 1000000000] slist $slist]
            dict set ::model::Profiles $profileid plans [dict create plainid $plan]
            dict set ::model::Profiles $profileid profilename $newprofilename


            go update-bulk-sitem $profileid
        
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

proc are-selected-files-correct {files} {
    if {$files eq ""} {
        return 0
    }
    foreach f $files {
        set ext [file extension $f]
        if {$ext in {.doc .mp3 .png .gif .jpg}} {
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
    puts stderr "extract-servers files: $files"
    foreach f $files {
        set ovpn [slurp $f]
        puts stderr "slurp ovpn: $ovpn"
        set remotes [ovconf raw-get $ovpn remote]
        set remotes [concat $remotes [ovconf raw-get $ovpn #remote]]
        set remotes [concat $remotes [ovconf raw-get $ovpn "# remote"]]
        puts stderr "remotes: $remotes"
        set proto [ovconf raw-get $ovpn proto]
        foreach r $remotes {
            lassign $r host port
            if {[is-valid-host $host] && [is-valid-port $port] && [is-valid-proto $proto]} {
                set triple [list $host $proto $port]
                lappend endpoints $triple
            }
        }
    }
    set endpoints [lunique $endpoints]

    #TODO resolve hostsnames


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
if 0 {
dict set model::Supported_providers from_file {
    order 900
    name $::from_file::name
    dispname $::from_file::dispname
}
}

