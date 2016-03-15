
namespace eval ::securitykiss {
    namespace export *
    namespace ensemble create

    variable name securitykiss
    variable dispname SecurityKISS
    variable host www.securitykiss.com
    variable port 10443
    variable path_config /vpapi/securitykiss/config
    variable path_plans /vpapi/securitykiss/plans


    # input entries - resettable/modifiable variables
    variable newprofilename ""
    variable username ""
    variable password ""

}



proc ::securitykiss::create-import-frame {tab} {
    variable name
    variable dispname

    set ::${name}::newprofilename [unique-profilename $dispname]

    set pconf $tab.$name
    ttk::frame $pconf

    addprovider-gui-profilename $tab $name
    addprovider-gui-username $tab $name $dispname "e.g. client12345678"
    addprovider-gui-password $tab $name $dispname
    addprovider-gui-importline $tab $name
    hypertext $pconf.link "Create free or premium account on <https://fruho.com/redirect?urlid=securitykiss&cn=$::model::Cn><securitykiss.com>"
    grid $pconf.link -sticky news -columnspan 3 -padx 10 -pady 10
    return $pconf
}
        
proc ::securitykiss::add-to-treeview-plist {plist} {
    variable name
    variable dispname
    $plist insert {} end -id $name -image [img load 16/logo_$name] -values [list $dispname]
}

# this is csp coroutine
proc ::securitykiss::ImportClicked {tab args} {
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
        dict set ::model::Profiles $profileid provider $name

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

lappend ::model::Supported_providers {010 securitykiss}
