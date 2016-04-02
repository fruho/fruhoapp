
namespace eval ::mullvad {
    namespace export *
    namespace ensemble create

    variable name mullvad
    variable dispname Mullvad
    variable host bootstrap
    # port is not relevant - it will be taken from bootstrap nodes list
    variable port 10443
    variable path_config /vpapi/mullvad/config
    variable path_plans /vpapi/mullvad/plans


    # input entries - resettable/modifiable variables
    variable newprofilename ""
    variable username ""
    variable password ""

}



proc ::mullvad::create-import-frame {tab} {
    variable name
    variable dispname

    set ::${name}::newprofilename [unique-profilename $dispname]

    set pconf $tab.$name
    ttk::frame $pconf

    ttk::label $pconf.notsupported -text "Mullvad VPN no longer supported" 
    grid $pconf.notsupported -row 1 -column 2 -sticky news -pady 5
if 0 {
    addprovider-gui-profilename $tab $name
    ttk::label $pconf.usernamelabel -text "Mullvad account number" -anchor e
    ttk::entry $pconf.usernameinput -textvariable ::${name}::username
    ttk::label $pconf.usernameinfo -foreground grey -text ""
    grid $pconf.usernamelabel -row 5 -column 0 -sticky news -padx 5 -pady 5
    grid $pconf.usernameinput -row 5 -column 1 -sticky news -padx 5 -pady 5
    grid $pconf.usernameinfo -row 5 -column 2 -sticky news -pady 5
    addprovider-gui-importline $tab $name
    hypertext $pconf.link "Create account on <https://fruho.com/redirect?urlid=mullvad&cn=$::model::Cn><mullvad.net>"
    grid $pconf.link -sticky news -columnspan 3 -padx 10 -pady 10
}

    return $pconf
}
        
proc ::mullvad::add-to-treeview-plist {plist} {
    variable name
    variable dispname
    $plist insert {} end -id $name -image [img load 16/logo_$name] -values [list $dispname]
}


# this is csp coroutine
proc ::mullvad::ImportClicked {tab args} {
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
        importline-update $pconf "Importing configuration from $dispname" disabled spin
    
        set result [vpapi-config-direct $newprofilename $host $port $path_config?[this-pcv] $username $password]
        if {$result != 200} {
            importline-update $pconf [http2importline $result] normal empty
            return
        }

        set result [vpapi-plans-direct $newprofilename $host $port $path_plans?[this-pcv] $username $password]
        if {$result != 200} {
            importline-update $pconf [http2importline $result] normal empty
            return
        }
        dict set ::model::Profiles $profileid vpapi_username $username
        dict set ::model::Profiles $profileid vpapi_host $host
        dict set ::model::Profiles $profileid vpapi_port $port
        dict set ::model::Profiles $profileid vpapi_path_plans $path_plans
        dict set ::model::Profiles $profileid provider $name

        importline-update $pconf "" normal empty
        set ::${name}::username ""
    
        # when repainting tabset select the newly created tab
        set ::model::selected_profile $profileid
        tabset-profiles .c.tabsetenvelope
    } on error {e1 e2} {
        puts stderr [log $e1 $e2]
    }
}


lappend ::model::Supported_providers {030 mullvad}
