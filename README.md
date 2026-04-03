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
## Getting Started
```
git clone https://github.com/StapleTT/aircracked.git
cd aircracked
./aircracked.sh
```
To show hidden networks, run:
```
./aircracked.sh --show-hidden
```
## Disclaimer
This tool is intended for educational and authorized testing purposes only. Only use this tool on networks you own or have explicit written permission to test. Unauthorized use against networks you do not own is illegal and punishable under computer crime laws. The author accepts no responsibility for any misuse or damage caused by this tool. You are solely responsible for your actions.
