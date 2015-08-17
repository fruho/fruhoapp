
## FBAPI - Fruho Backend API

/check-for-updates
/ip
/dns-resolve
...


## VPAPI - VPN Provider API

This is the API defined and used by the Fruho program to import VPN configurations and plan definitions from third party VPN services. This also applies to Fruho as an interim VPN service so it must be implemented on bootstrap hosts along with FBAPI

All calls must be HTTPS with username and password passed via Basic Authentication

GET /api/config
Result: config.ovpn with inline CA and optionally KEY and CERT

GET /api/plans
Result: JSON plan description with server list

POST /api/cert
Input: CSR or PUBKEY posted in body request
Result: signed CRT
