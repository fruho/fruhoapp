
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

}


proc ::airvpn::create-import-frame {tab} {
    variable name
    variable dispname

    set ::${name}::newprofilename [unique-profilename $dispname]

    set pconf $tab.$name
    ttk::frame $pconf

    # must be in that order
    addprovider-gui-profilename $tab $name
    addprovider-gui-importline $tab $name
    addprovider-gui-selectfiles $tab $name
    hypertext $pconf.link "No support for auto import. See <https://fruho.com/howto/3><howto.>"
    grid $pconf.link -sticky news -columnspan 3 -padx 10 -pady 10
    return $pconf
}

        
proc ::airvpn::add-to-treeview-plist {plist} {
    variable name
    variable dispname
    $plist insert {} end -id $name -image [img load 16/logo_$name] -values [list $dispname]
}


# this is csp coroutine
proc ::airvpn::ImportClicked {tab name} {
    try {
        variable newprofilename
        set newprofileid [name2id $newprofilename]
        ::from_file::ImportClicked $tab $name
        set plans [dict-pop $::model::Profiles $newprofileid plans {}]
        lassign $plans planid plan
        set slist [dict-pop $plan slist {}]
        set sitem [lindex $slist 0]
        set ovses [dict-pop $sitem ovses {}]
        set ovs [lindex $ovses 0]
        set proto [dict-pop $ovs proto {}]
        set port [dict-pop $ovs port {}]

    } on error {e1 e2} {
        puts stderr [log $e1 $e2]
    }
}


lappend ::model::Supported_providers {150 airvpn}
