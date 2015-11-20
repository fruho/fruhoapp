
namespace eval ::cyberghost {
    namespace export *
    namespace ensemble create

    variable name cyberghost
    variable dispname CyberGhost
    # input entries - resettable/modifiable variables
    variable newprofilename ""
    variable username 4478671_Mjz3msabMw
    variable password PGexN8u3kV
}



proc ::cyberghost::create-import-frame {tab} {
    variable name
    variable dispname
    variable newprofilename

    set newprofilename [unique-profilename $dispname]

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
    ttk::label $pconf.usernamelabel -text "VPN username" -anchor e
    ttk::entry $pconf.usernameinput -textvariable ::${name}::username
    ttk::label $pconf.usernameinfo -foreground grey -text "e.g. 4384732_8j3StDv8Uw"
    ttk::label $pconf.passwordlabel -text "VPN password" -anchor e
    ttk::entry $pconf.passwordinput -textvariable ::${name}::password
    ttk::label $pconf.passwordinfo -foreground grey
    ttk::frame $pconf.importline
    ttk::button $pconf.importline.button -state disabled -text "Import configuration" -command [list go ::${name}::ImportClicked $tab $name]
    # must use non-ttk label for proper animated gif display
    label $pconf.importline.img
    img place 24/empty $pconf.importline.img
    ttk::label $pconf.importline.msg
    grid $pconf.importline.button -row 0 -column 0 -padx 10
    grid $pconf.importline.img -row 0 -column 1 -padx 10 -pady 10
    grid $pconf.importline.msg -row 0 -column 2 -padx 10 -pady 10

    hypertext $pconf.link "Only premium accounts and no support for auto import. See <https://fruho.com/howto/2><howto.>"

    grid columnconfigure $pconf 0 -weight 4 -uniform 1
    grid columnconfigure $pconf 1 -weight 4 -uniform 1
    grid columnconfigure $pconf 2 -weight 4 -uniform 1
    grid $pconf.profilelabel -row 1 -column 0 -sticky news -padx 5 -pady 5
    grid $pconf.profileinput -row 1 -column 1 -sticky news -padx 5 -pady 5
    grid $pconf.profileinfo -row 1 -column 2 -sticky news -pady 5
    grid $pconf.select -row 4 -column 0 -sticky news -columnspan 2
    grid $pconf.selectinfo -row 4 -column 2 -sticky news
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
        
proc ::cyberghost::add-to-treeview-plist {plist} {
    variable name
    variable dispname
    $plist insert {} end -id $name -image [img load 16/logo_$name] -values [list $dispname]
}

# this is csp coroutine
proc ::cyberghost::ImportClicked {tab name} {
    try {
        variable newprofilename
        variable username
        variable password
        set newprofileid [name2id $newprofilename]
        if {$username ne "" && $password ne ""} {
            dict-set-trim ::model::Profiles $newprofileid cache_custom_auth_user $username
            dict-set-trim ::model::Profiles $newprofileid cache_custom_auth_pass $password
        }
        ::from_file::ImportClicked $tab $name
        set plans [dict-pop $::model::Profiles $newprofileid plans {}]
        lassign $plans planid plan
        set slist [dict-pop $plan slist {}]
        set sitem [lindex $slist 0]
        set ovses [dict-pop $sitem ovses {}]
        set ovs [lindex $ovses 0]
        set proto [dict-pop $ovs proto {}]
        set port [dict-pop $ovs port {}]

        if {$slist ne "" && $proto ne "" && $port ne "" && $planid ne ""} {
            set endpoints {}
            foreach sitem $slist {
                lappend endpoints [list [dict-pop $sitem ip {}] $proto $port]
            }
            # hardcoded cyberghost hosts
            set hosts {1-au.cg-dialup.net 1-at.cg-dialup.net 1-be.cg-dialup.net 1-ca.cg-dialup.net 4-cz.cg-dialup.net 1-dk.cg-dialup.net 1-fi.cg-dialup.net 1-fr.cg-dialup.net 1-de.cg-dialup.net 4-de.cg-dialup.net 1-hk.cg-dialup.net 1-hu.cg-dialup.net 1-is.cg-dialup.net 1-ie.cg-dialup.net 1-il.cg-dialup.net 1-it.cg-dialup.net 1-jp.cg-dialup.net 1-lt.cg-dialup.net 1-lu.cg-dialup.net 1-mx.cg-dialup.net 5-nl.cg-dialup.net 1-no.cg-dialup.net 1-pl.cg-dialup.net 1-ro.cg-dialup.net 4-ro.cg-dialup.net 1-sg.cg-dialup.net 1-es.cg-dialup.net 1-se.cg-dialup.net 1-ch.cg-dialup.net 9-ch.cg-dialup.net 1-ua.cg-dialup.net 1-gb.cg-dialup.net}
            foreach host $hosts {
                lappend endpoints [list $host $proto $port]
            }
            set newslist [from_file::create-slist $endpoints]
            dict set ::model::Profiles $newprofileid plans $planid slist $newslist
        }

    } on error {e1 e2} {
        puts stderr [log $e1 $e2]
    }
}


lappend ::model::Supported_providers {200 cyberghost}
if 0 {
dict set model::Supported_providers cyberghost {
    order 200
    name $::cyberghost::name
    dispname $::cyberghost::dispname
}
}

