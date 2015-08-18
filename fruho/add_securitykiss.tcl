
namespace eval ::securitykiss {
    namespace export *
    namespace ensemble create

    variable name securitykiss
    variable dispname SecurityKISS
    variable host www.securitykiss.com
    variable port 10443
    variable path_config /vpapi/config
    variable path_plans /vpapi/plans


    # input entries - resettable/modifiable variables
    variable newprofilename ""
    variable username client04284903
    variable password 97d7a6cc3

}



proc ::securitykiss::create-import-frame {tab} {
    variable name
    variable dispname
    variable newprofilename

    set newprofilename [unique-profilename $dispname]

    set pconf $tab.$name
    ttk::frame $pconf
    ttk::label $pconf.profilelabel -text "Profile name" -anchor e
    ttk::entry $pconf.profileinput -textvariable ::${name}::newprofilename
    ttk::label $pconf.profileinfo -foreground grey
    ttk::label $pconf.usernamelabel -text "Username" -anchor e
    ttk::entry $pconf.usernameinput -textvariable ::securitykiss::username
    ttk::label $pconf.usernameinfo -foreground grey -text "e.g. client12345678"
    ttk::label $pconf.passwordlabel -text "Password" -anchor e
    ttk::entry $pconf.passwordinput -textvariable ::${name}::password
    ttk::label $pconf.passwordinfo -foreground grey
    ttk::frame $pconf.importline
    ttk::button $pconf.importline.button -text "Import configuration" -command [list go ::${name}::ImportClicked $tab]
    # must use non-ttk label for proper animated gif display
    label $pconf.importline.img
    img place 24/empty $pconf.importline.img
    ttk::label $pconf.importline.msg
    grid $pconf.importline.button -row 0 -column 0 -padx 10
    grid $pconf.importline.img -row 0 -column 1 -padx 10 -pady 10
    grid $pconf.importline.msg -row 0 -column 2 -padx 10 -pady 10
    grid columnconfigure $pconf 0 -weight 3 -uniform 1
    grid columnconfigure $pconf 1 -weight 5 -uniform 1
    grid columnconfigure $pconf 2 -weight 4 -uniform 1
    grid $pconf.profilelabel -row 1 -column 0 -sticky news -padx 5 -pady 5
    grid $pconf.profileinput -row 1 -column 1 -sticky news -padx 5 -pady 5
    grid $pconf.profileinfo -row 1 -column 2 -sticky news -pady 5
    grid $pconf.usernamelabel -row 5 -column 0 -sticky news -padx 5 -pady 5
    grid $pconf.usernameinput -row 5 -column 1 -sticky news -padx 5 -pady 5
    grid $pconf.usernameinfo -row 5 -column 2 -sticky news -pady 5
    grid $pconf.passwordlabel -row 7 -column 0 -sticky news -padx 5 -pady 5
    grid $pconf.passwordinput -row 7 -column 1 -sticky news -padx 5 -pady 5
    grid $pconf.passwordinfo -row 7 -column 2 -sticky news -pady 5
    grid $pconf.importline -sticky news -columnspan 3
    return $pconf
}
        
proc ::securitykiss::add-to-treeview-plist {plist} {
    variable name
    variable dispname
    $plist insert {} end -id $name -image [img load 16/logo_$name] -values [list $dispname]
}

# this is csp coroutine
proc ::securitykiss::ImportClicked {tab} {
    try {
        variable name
        variable dispname
        variable host
        variable port
        variable path_config
        variable path_plans
        variable username
        variable password
        variable newprofilename
        set pconf $tab.$name
        img place 24/connecting $pconf.importline.img
        $pconf.importline.msg configure -text "Importing configuration from $dispname"
        $pconf.importline.button configure -state disabled
    
        set result [vpapi-config-direct $newprofilename $host $port $path_config?[this-pcv] $username $password]
        if {$result != 200} {
            if {$result == 401} {
                set msg "Incorrect username or password"
            } else {
                set msg $result
            }
            img place 24/empty $pconf.importline.img
            $pconf.importline.button configure -state normal
            $pconf.importline.msg configure -text $msg
            return
        }
        puts stderr "VPAPI-CONFIG-DIRECT completed"
        set result [vpapi-plans-direct $newprofilename $host $port $path_plans?[this-pcv] $username $password]
        if {$result != 200} {
            if {$result == 401} {
                set msg "Incorrect username/password"
            } else {
                set msg $result
            }
            img place 24/empty $pconf.importline.img
            $pconf.importline.button configure -state normal
            $pconf.importline.msg configure -text $msg
            return
        }
        puts stderr "VPAPI-PLANS-DIRECT completed"
    
        img place 24/empty $pconf.importline.img
        $pconf.importline.msg configure -text ""
        $pconf.importline.button configure -state normal
        set ::securitykiss::username ""
        set ::${name}::password ""
    
        # when repainting tabset select the newly created tab
        tabset-profiles .c.tabsetenvelope [window-sibling $tab [name2id $newprofilename]]
    } on error {e1 e2} {
        puts stderr [log $e1 $e2]
    }
}


dict set model::Supported_providers securitykiss {
    name $::securitykiss::name
    dispname $::securitykiss::dispname
}

