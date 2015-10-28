
# This version of hideipvpn config retrieval does not log in to hideipvpn website
# It only takes the static config via VPAPI which is the same for all users
# hideipvpn uses VPN username and password for authentication and shared certificate

namespace eval ::hideipvpn {
    namespace export *
    namespace ensemble create

    variable name hideipvpn
    variable dispname HideIpVPN
    variable host bootstrap
    # port is not relevant - it will be taken from bootstrap nodes list
    variable port 10443
    variable path_config /vpapi/hideipvpn/config
    variable path_plans /vpapi/hideipvpn/plans


    # input entries - resettable/modifiable variables
    variable newprofilename ""
    variable username tgqyqzai
    variable password behdfuuu

}



proc ::hideipvpn::create-import-frame {tab} {
    variable name
    variable dispname
    variable newprofilename

    set newprofilename [unique-profilename $dispname]

    set pconf $tab.$name
    ttk::frame $pconf
    ttk::label $pconf.profilelabel -text "Profile name" -anchor e
    ttk::entry $pconf.profileinput -textvariable ::${name}::newprofilename
    ttk::label $pconf.profileinfo -foreground grey
    ttk::label $pconf.usernamelabel -text "VPN username" -anchor e
    ttk::entry $pconf.usernameinput -textvariable ::${name}::username
    ttk::label $pconf.usernameinfo -foreground grey -text ""
    ttk::label $pconf.passwordlabel -text "VPN password" -anchor e
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
    grid columnconfigure $pconf 0 -weight 4 -uniform 1
    grid columnconfigure $pconf 1 -weight 4 -uniform 1
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
        
proc ::hideipvpn::add-to-treeview-plist {plist} {
    variable name
    variable dispname
    $plist insert {} end -id $name -image [img load 16/logo_$name] -values [list $dispname]
}

# this is csp coroutine
proc ::hideipvpn::ImportClicked {tab} {
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

        set profileid [name2id $newprofilename]

        set pconf $tab.$name
        img place 24/spin $pconf.importline.img
        $pconf.importline.msg configure -text "Importing configuration from $dispname"
        $pconf.importline.button configure -state disabled
    
        # in case of hideipvpn using username and password has a different purpose than authentication
        # instead of using for basic authentication (any strings will pass) the credentials are included in the returned config.ovpn
        set result [vpapi-config-direct $newprofilename $host $port $path_config?[this-pcv] $username $password]
        if {$result != 200} {
            set msg [http2importline $result]
            img place 24/empty $pconf.importline.img
            $pconf.importline.button configure -state normal
            $pconf.importline.msg configure -text $msg
            return
        }
        puts stderr "VPAPI-CONFIG-DIRECT completed"

        # in case of hideipvpn using username and password has a different purpose than authentication
        # instead of using for basic authentication (any strings will pass) the credentials are included in the returned config.ovpn
        set result [vpapi-plans-direct $newprofilename $host $port $path_plans?[this-pcv] $username $password]
        if {$result != 200} {
            set msg [http2importline $result]
            img place 24/empty $pconf.importline.img
            $pconf.importline.button configure -state normal
            $pconf.importline.msg configure -text $msg
            return
        }
        dict set ::model::Profiles $profileid vpapi_username $username
        dict set ::model::Profiles $profileid vpapi_password $password
        dict set ::model::Profiles $profileid vpapi_host $host
        dict set ::model::Profiles $profileid vpapi_port $port
        dict set ::model::Profiles $profileid vpapi_path_plans $path_plans

        puts stderr "VPAPI-PLANS-DIRECT completed"
    
        img place 24/empty $pconf.importline.img
        $pconf.importline.msg configure -text ""
        $pconf.importline.button configure -state normal
        set ::${name}::username ""
        set ::${name}::password ""
    
        # when repainting tabset select the newly created tab
        set ::model::selected_profile $profileid
        tabset-profiles .c.tabsetenvelope
    } on error {e1 e2} {
        puts stderr [log $e1 $e2]
    }
}


dict set model::Supported_providers hideipvpn {
    name $::hideipvpn::name
    dispname $::hideipvpn::dispname
}

