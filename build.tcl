##############################################################
# Build configuration file
#
# Run run.bat or run.sh to run the build
#
##############################################################

# Build command syntax:
# build <os> <arch> <project_name> <basekit> <list_of_packages>
# where basekit may be: base-tcl-<ver> or base-tk-<ver> or base-tcl-thread-<ver> or base-tk-thread-<ver>
#


# Examples

# Prepare library project samplelib. Version number not relevant
# One library project may contain multiple tcl packages with different names
# Artifacts are placed in lib/generic and are ready to use by other projects
#prepare-lib samplelib 0.0.0

# Build project sample for linux-ix86 with basekit base-tcl-8.6.3.1.298687 and packages tls-1.6.7.1 autoproxy-1.5.3
#build linux ix86 sample base-tcl-8.6.3.1.298687 {tls-1.6.7.1 autoproxy-1.5.3}

# Run project sample as starpack - recommended since it tests end-to-end
#ex ./build/sample/linux-ix86/sample.bin

# Run project sample not as starpack but from unwrapped vfs
# Project must be built for this platform first!
#run sample

proc base-ver {arch} {
    if {$arch eq "x86_64"} {
        return "8.6.3.1.298687"
    } elseif {$arch eq "ix86"} {
        return "8.6.3.1.298685"
    } else {
        error "base-ver unrecognized arch: $arch"
    }
}


proc copy-flags {countries {sizes {16 24 64}}} {
    set from [file normalize ../images/flag/shiny]
    set to [file normalize ./fruho/images]
    foreach size $sizes {
        file mkdir [file join $to $size flag]
        foreach c $countries {
            file copy -force [file join $from $size $c.png] [file join $to $size flag]
        }
    }
}


proc build-fruho {os arch} {
    spit fruho/builddate.txt $::builddate
    spit fruho/buildver.txt $::FRUHO_VERSION
    #copy-flags {PL GB UK DE FR US EMPTY}
    #build $os $arch fruho base-tk-[base-ver $arch] {sklib-0.0.0 Tkhtml-3.0 tls-1.6.7.1 Tclx-8.4 cmdline-1.5 json-1.3.3 snit-2.3.2 doctools-1.4.19 textutil::expander-1.3.1}
    build $os $arch fruho base-tk-[base-ver $arch] {sklib-0.0.0 tls-1.6.7.1 Tclx-8.4 cmdline-1.5 json-1.3.3 uri-1.2.5 base64-2.4.2 tktray-1.3.9}

    # this is necessary to prevent "cp: cannot create regular file ‘/usr/local/sbin/fruho.bin’: Text file busy"
    if {[file exists /usr/local/bin/fruho.bin]} {
        ex sudo mv /usr/local/bin/fruho.bin /tmp/fruho.bin-tmp
    }
    ex sudo cp build/fruho/linux-$arch/fruho.bin /usr/local/bin/fruho.bin
}

proc build-fruhod {os arch} {
    spit fruhod/builddate.txt $::builddate
    spit fruhod/buildver.txt $::FRUHO_VERSION
    build $os $arch fruhod base-tk-[base-ver $arch] {sklib-0.0.0 Tclx-8.4}
    #ex sudo service fruhod stop

    # this is necessary to prevent "cp: cannot create regular file ‘/usr/local/sbin/fruhod.bin’: Text file busy"
    # do the same when auto-upgrading inside fruhod
    if {[file exists /usr/local/sbin/fruhod.bin]} {
        ex sudo mv /usr/local/sbin/fruhod.bin /tmp/fruhod.bin-tmp
    }
    ex sudo cp build/fruhod/linux-$arch/fruhod.bin /usr/local/sbin/fruhod.bin

    ex sudo cp fruhod/exclude/etc/init.d/fruhod /etc/init.d/fruhod
    #ex sudo service fruhod restart
}

proc build-deb-rpm {arch} {
    puts "Building deb/rpm dist package"
    install-fpm
    if {$::tcl_platform(platform) eq "unix"} { 
        set distdir dist/linux-$arch
        file delete -force $distdir
        file mkdir $distdir
        file copy fruhod/exclude/etc $distdir
        file copy fruho/exclude/usr $distdir
        file mkdir $distdir/usr/local/sbin
        file copy build/fruhod/linux-$arch/fruhod.bin $distdir/usr/local/sbin/fruhod.bin
        file mkdir $distdir/usr/local/bin
        file copy build/fruho/linux-$arch/fruho.bin $distdir/usr/local/bin/fruho.bin
        file copy fruho/exclude/fruho $distdir/usr/local/bin/fruho
        cd $distdir
        set fpmopts "-a [fpm-arch $arch] -s dir -n fruho -v $::FRUHO_VERSION --before-install ../../fruhod/exclude/fruhod.preinst --after-install ../../fruhod/exclude/fruhod.postinst --before-remove ../../fruhod/exclude/fruhod.prerm --after-remove ../../fruhod/exclude/fruhod.postrm usr etc"
        ex fpm -t deb {*}$fpmopts
        ex fpm -t rpm --rpm-autoreqprov {*}$fpmopts
        cd ../..
    } 
}



proc build-total {} {
    foreach arch {x86_64 ix86} {
        build-fruho linux $arch
        build-fruhod linux $arch
        build-deb-rpm $arch
    }
}

proc test {} {
    package require tcltest
    tcltest::configure -testdir [file normalize ./sklib]
    tcltest::runAllTests
}




proc parse-commits {commits} {
    set commit2msg [dict create]
    set prev ""
    set commit ""
    foreach line [split $commits \n] {
        set line [string trim $line]
        if {[regexp {commit ([0-9a-f]+)} $line _ commit]} {
            puts "commit=$commit"
        } elseif {$prev eq ""} {
            dict set commit2msg $commit $line
        }
        set prev $line
    }
    puts "\n$commit2msg\n"
    return $commit2msg
}



proc github-latest-release-date {} {
    set latest_s [exec -ignorestderr curl https://api.github.com/repos/fruho/fruhoapp/releases/latest]
    set latest [json::json2dict $latest_s]
    set published_at [dict get $latest published_at]
    return $published_at
}

proc github-create-release {gituser gitpass} {
    set js1 "{\"tag_name\": \"fruho-$::FRUHO_VERSION\"}"
    set created_release_s [exec -ignorestderr curl https://api.github.com/repos/fruho/fruhoapp/releases -XPOST -d$js1 -u "$gituser:$gitpass"]
    puts "created_release_s: $created_release_s"
    set created_release [json::json2dict $created_release_s]
    set id [dict get $created_release id]
    set upload_url [dict get $created_release upload_url]
    puts "Release id: $id"
    puts "Release upload_url: $upload_url"

    #set id 1713418
    #set upload_url "https://uploads.github.com/repos/fruho/fruhoapp/releases/1713418/assets{?name}"
    set braceindex [string first \{ $upload_url]
    set upload_url [string range $upload_url 0 [incr braceindex -1]]
    return $upload_url
}

proc github-upload-artifacts {upload_url gituser gitpass} {
    set artifacts {}
    foreach file [concat [glob dist/linux-*/*.deb] [glob dist/linux-*/*.rpm]] {
        set filename [file tail $file]
        set uurl $upload_url?name=$filename
        set uploaded [exec -ignorestderr curl -XPOST --header "Content-Type: application/zip" -d @$file $uurl -u "$gituser:$gitpass"]
        set u [json::json2dict $uploaded]
        set downurl [dict get $u browser_download_url]
        lappend artifacts $downurl
    }
    return $artifacts
}

proc html-changelog {commit2msg} {
    set html ""
    dict for {commit msg} $commit2msg {
        set shortcommit [string range $commit 0 5]
        append html "<li>$msg <a href=\"https://github.com/fruho/fruhoapp/commit/$commit\">#$shortcommit</a></li>\n"
        
    }
    return $html
}

proc release {gituser} {

    lappend ::auto_path [file normalize ./lib/generic]
    package require json

    puts "Enter your github password:"
    set gitpass [gets stdin]

    #set published_at [github-latest-release-date]

    set published_at 2015-06-23T20:10:07Z

    set commits [exec git log --since="$published_at"]
    #puts "commits:\n$commits"
    set commit2msg [parse-commits $commits]
    
    set html [html-changelog $commit2msg]

    set upload_url [github-create-release $gituser $gitpass]

    set artifacts [github-upload-artifacts $upload_url $gituser $gitpass]

    puts "Release changes:\n\n$html\n\n"
    puts "Uploaded artifacts:\n\n$artifacts\n\n"

}


set ::FRUHO_VERSION 0.0.7

prepare-lib sklib 0.0.0



#build-total
#package require i18n
#i18n code2msg ./fruho/main.tcl {es pl} ./fruho/messages.txt 


build-fruho linux [this-arch]
#build-fruhod linux [this-arch]
#build-deb-rpm [this-arch]

#release hypatia2


# sudo dpkg -i ./dist/linux-x86_64/fruho_${::FRUHO_VERSION}_amd64.deb
# sudo dpkg -i ./dist/linux-ix86/fruho_${::FRUHO_VERSION}_i386.deb

exit
