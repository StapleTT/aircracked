# aircracked
A script utilizing aircrack-ng to (somewhat) automatically crack WiFi handshakes using GPU acceleration via hashcat.
## Prerequisites
- an Arch or Debian based Linux distro
- an existing wordlist (https://weakpass.com)
- a wireless interface that supports monitor mode (and its respective driver)
- Packages:
  - `aircrack-ng`
  - `hashcat`
  - `hcxtools`
- For GPU Acceleration (optional), reference hashcat's requirements: https://hashcat.net
- permission to test on targeted networks
