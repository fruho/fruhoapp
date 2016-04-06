# Fruho VPN Manager - Universal VPN client

### What is Fruho?

Fruho is an open-source, zero-configuration, VPN client software for Linux. It supports automatic setup and allows importing configurations from VPN services and connecting to your own VPN server. Visit https://fruho.com for more details.

&nbsp;

![Fruho screenshot](https://fruho.com/images/screenshots/screenshot000.png)

### What problem does Fruho solve?

Fruho solves a number of problems and provides benefits for 3 different actors.

For the **End User:**

Installing VPN client on a PC or mobile requires full administration privileges. That's the nature of the VPN software that it requires access to low level networking so admin rights are needed. Most VPN services provide their own proprietary software. Installing powerful and opaque software is a potential danger because the user cannot be sure what the software is actually doing, what deliberate or unintended security holes, backdoors or vulnerabilities contains. It means that the user has to trust the VPN service not only with the data it transmits but also with giving the full access to the user's device.

Fruho program on the other hand is completely transparent and opensource, so the code can be reviewed by developers and security experts, so the user can be sure it does not do evil things.

It also hides the complexities and idiosyncracies of individual VPN service programs, and gives the user a unified facade for accessing multiple VPN services.

For the **VPN Provider:**

VPN provider does not need to release their own VPN client software. It means lower cost of operating.

They can outsource client side software for free. It also means that there is a lower barrier of entry for new VPN providers.

For the **Developer:**

Fruho makes it easy to set up your own micro VPN service.

It provides the user friendly client application with documented API to connect to your own VPN server.

### Is Fruho a VPN service provider?

No, although we run a few VPN servers to let the user test Fruho VPN software without having an account with a commercial VPN service.

We are a software producer.

Instead of reading reviews that may be outdated or relying on recommendations that may not be genuine, you can evaluate VPN providers yourself.

Fruho makes it easy to switch between VPN services and to set up your own VPN server.

### What is an interim account?

Interim account is a short term VPN account created automatically when the program runs first time.

It is a full-featured VPN account provided by Fruho. It is valid for 1 hour and allows VPN tunneling to our servers so the user can test the software and import configurations from other VPN services over a secure channel.

### You are giving only 1 hour of the free VPN service. Are you kidding?

As explained above we are not a VPN service provider. Servers and bandwidth are expensive and we pay for it while not earning any money.

We run a few supporting VPN servers as a way to bootstrap the application and provide smooth user experience. The interim accounts are not long-term but they are important because the initial out-of-the-box connection allows importing other VPN provider configurations over an additional secure channel. VPN provider domains and websites are often blocked by ISPs so getting configurations would not be possible otherwise.

### How to import configuration from my VPN provider?

In most cases it's as easy as on this [screenshot:](https://fruho.com/screenshots/6)

*   Create an account with VPN provider if you don't have one (many of them are free)
*   Enter account's username and password in the program and click "Import configuration"

### Which VPN services are supported?

Curently we support "one click" import from the following providers:

*   [VpnBook](https://fruho.com/redirect?urlid=vpnbook) (free)
*   [SecurityKISS](https://fruho.com/redirect?urlid=securitykiss) (free or premium)
*   [Mullvad](https://fruho.com/redirect?urlid=mullvad) (free trial or premium)
*   [HideIpVPN](https://fruho.com/redirect?urlid=hideipvpn) (free trial or premium)
*   [VyprVPN](https://fruho.com/redirect?urlid=vyprvpn) (free trial or premium)
*   [AirVPN](https://fruho.com/redirect?urlid=airvpn) (premium only)

Basically any VPN provier is supported who provides OpenVPN config files. See how to import config files [manually.](https://fruho.com/howto/1)

[Let us know](https://fruho.com/contact) if you would like to include your favorite service into "one click" import.

---
