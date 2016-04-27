#
# sample/main.tcl
#
# This should be the preamble to every application
# It makes it possible to run as starpack or as a sourced script
if {![catch {package require starkit}]} {
  #this is to initialize starkit variables
  starkit::startup
}

package require http
package require tls
package require https
package require csp
namespace import csp::*


proc run {} {
#    https init -cadir /etc/ssl/certs
    https curl https://www.fruho.com/ip -command [-> chhttp] 
    set tok [<- $chhttp]
    upvar #0 $tok state
    set ncode [http::ncode $tok]
    if {[string is integer -strict $ncode]} {
        set ncode_nonempty $ncode
    }
    set status [http::status $tok]
    if {$status eq "ok" && $ncode == 200} {
        set data [http::data $tok]
        puts "data: $data"
    }
    puts "exit"
}



go run

vwait ::until
