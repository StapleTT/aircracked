# aircracked
A script utilizing aircrack-ng to (somewhat) automatically crack WiFi handshakes using GPU acceleration via hashcat.
## Prerequisites
- Linux distro with strong wireless & GPU support (e.g., Kali, Arch, Ubuntu)
- Wordlists for testing (https://weakpass.com)
- Compatible wireless interface that supports:
  - Monitor mode
  - Paket injection
- Packages:
  - `aircrack-ng`
  - `hashcat`
  - `hcxtools`
- For GPU Acceleration (optional), reference hashcat's requirements: https://hashcat.net
- Authorization to test on targeted networks
