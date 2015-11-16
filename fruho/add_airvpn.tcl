
namespace eval ::airvpn {
    namespace export *
    namespace ensemble create

    variable name airvpn
    variable dispname AirVPN
    variable host bootstrap
    variable port 10443
    variable path_config /vpapi/airvpn/config
    variable path_plans /vpapi/airvpn/plans


    # input entries - resettable/modifiable variables
    variable newprofilename ""
    variable username ""
    variable password ""

}



proc ::airvpn::create-import-frame {tab} {
    variable name
    variable dispname
    variable newprofilename

    set newprofilename [unique-profilename $dispname]

    set pconf $tab.$name
    ttk::frame $pconf
    ttk::label $pconf.profilelabel -text "Profile name" -anchor e
    ttk::entry $pconf.profileinput -textvariable ::${name}::newprofilename
    ttk::label $pconf.profileinfo -foreground grey
    ttk::label $pconf.usernamelabel -text "Email address" -anchor e
    ttk::entry $pconf.usernameinput -textvariable ::${name}::username
    ttk::label $pconf.usernameinfo -foreground grey
    ttk::label $pconf.passwordlabel -text "$dispname password" -anchor e
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
    hypertext $pconf.link "Buy account on <https://fruho.com/redirect?urlid=airvpn&cn=$::model::Cn><airvpn.org>"

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
    grid $pconf.link -sticky news -columnspan 3 -padx 10 -pady 10
    return $pconf
}
        
proc ::airvpn::add-to-treeview-plist {plist} {
    variable name
    variable dispname
    $plist insert {} end -id $name -image [img load 16/logo_$name] -values [list $dispname]
}

# this is csp coroutine
proc ::airvpn::ImportClicked {tab} {
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
        puts stderr "VPAPI-CONFIG-DIRECT completed"

        set result [vpapi-plans-direct $newprofilename $host $port $path_plans?[this-pcv] $username $password]
        if {$result != 200} {
            importline-update $pconf [http2importline $result] normal empty
            return
        }

        # save in the model to be able later refresh the plans via vpapi
        dict set ::model::Profiles $profileid vpapi_username $username
        dict set ::model::Profiles $profileid vpapi_password $password
        dict set ::model::Profiles $profileid vpapi_host $host
        dict set ::model::Profiles $profileid vpapi_port $port
        dict set ::model::Profiles $profileid vpapi_path_plans $path_plans

        puts stderr "VPAPI-PLANS-DIRECT completed"
    
        importline-update $pconf "" normal empty
        set ::${name}::username ""
        set ::${name}::password ""
    
        # when repainting tabset select the newly created tab
        set ::model::selected_profile $profileid
        tabset-profiles .c.tabsetenvelope
    } on error {e1 e2} {
        puts stderr [log $e1 $e2]
    }
}

lappend ::model::Supported_providers {150 airvpn}
if 0 {
dict set model::Supported_providers airvpn {
    order 150
    name $::airvpn::name
    dispname $::airvpn::dispname
}
}
