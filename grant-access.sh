#!/usr/bin/env bash
# Interactively grants the current user read/write access to Logitech hidraw devices,
# which logimouse needs to talk HID++ to them.
#
# Lists every Logitech (USB vendor 046d) device that has hidraw nodes, with its access
# and any udev rule already covering it, then, for the devices you pick, either:
#   - adds a persistent udev rule to /etc/udev/rules.d/70-logimouse.rules that tags the
#     device "uaccess", so the logged-in user gets access whenever it is plugged in; or
#   - grants a temporary ACL on the current nodes, lost on unplug or reboot.
# It can also remove the rules it added. Every privileged step shows what it will run
# and asks before calling sudo.
set -euo pipefail

VENDOR="046d"
RULES_FILE="/etc/udev/rules.d/70-logimouse.rules"
RULE_DIRS=(/etc/udev/rules.d /run/udev/rules.d /usr/lib/udev/rules.d)

bold=$'\e[1m'; dim=$'\e[2m'; green=$'\e[32m'; red=$'\e[31m'; yellow=$'\e[33m'; reset=$'\e[0m'
if [[ ! -t 1 ]]; then bold=""; dim=""; green=""; red=""; yellow=""; reset=""; fi

if [[ $EUID -eq 0 ]]; then
    echo "Run this as your normal user, not as root: it grants access to the user running it and uses sudo when needed." >&2
    exit 1
fi

# ── Discovery ──────────────────────────────────────────────────────────────

# One entry per Logitech USB device (vendor:product), with its hidraw nodes.
declare -a PIDS=() NAMES=() NODES=() DRIVERS=() HIDPP=()

find_index() {
    local pid=$1 i
    for i in "${!PIDS[@]}"; do
        [[ ${PIDS[$i]} == "$pid" ]] && { echo "$i"; return; }
    done
    echo -1
}

scan() {
    PIDS=(); NAMES=(); NODES=(); DRIVERS=(); HIDPP=()
    local dir uevent hid_id vendor pid name driver node i
    for dir in /sys/class/hidraw/hidraw*; do
        [[ -e $dir ]] || continue
        uevent=$(<"$dir/device/uevent")
        hid_id=$(sed -n 's/^HID_ID=//p' <<<"$uevent")
        vendor=$(cut -d: -f2 <<<"$hid_id" | tail -c 5 | tr 'A-F' 'a-f')
        [[ $vendor == "$VENDOR" ]] || continue
        pid=$(cut -d: -f3 <<<"$hid_id" | tail -c 5 | tr 'A-F' 'a-f')
        name=$(sed -n 's/^HID_NAME=//p' <<<"$uevent")
        driver=$(sed -n 's/^DRIVER=//p' <<<"$uevent")
        node="/dev/$(basename "$dir")"
        i=$(find_index "$pid")
        if [[ $i -lt 0 ]]; then
            PIDS+=("$pid"); NAMES+=("$name"); NODES+=("$node"); DRIVERS+=("$driver"); HIDPP+=("no")
            i=$(( ${#PIDS[@]} - 1 ))
        else
            NODES[i]+=" $node"
            [[ " ${DRIVERS[i]} " == *" $driver "* ]] || DRIVERS[i]+=" $driver"
        fi
        # A HID++ interface declares the long report, id 0x11.
        if LC_ALL=C grep -q $'\x85\x11' "$dir/device/report_descriptor" 2>/dev/null; then
            HIDPP[i]="yes"
        fi
    done
}

# "all", "some" or "none": whether the current user can read and write the nodes.
access_of() {
    local node ok=0 total=0
    for node in $1; do
        total=$((total + 1))
        [[ -r $node && -w $node ]] && ok=$((ok + 1))
    done
    if (( ok == total )); then echo all; elif (( ok == 0 )); then echo none; else echo some; fi
}

# The udev rule files that tag this product "uaccess", or nothing.
rules_for() {
    local pid=$1 dir file hits=()
    for dir in "${RULE_DIRS[@]}"; do
        [[ -d $dir ]] || continue
        for file in "$dir"/*.rules; do
            [[ -f $file ]] || continue
            if grep -iE "idVendor.*$VENDOR" "$file" | grep -iE "idProduct[^,]*$pid" | grep -q uaccess; then
                hits+=("$file")
            fi
        done
    done
    echo "${hits[*]:-}"
}

show() {
    echo
    echo "${bold}Logitech devices with hidraw nodes${reset}"
    echo
    if (( ${#PIDS[@]} == 0 )); then
        echo "  None found. Is the device plugged in?"
        return
    fi
    local i access label rules
    for i in "${!PIDS[@]}"; do
        access=$(access_of "${NODES[i]}")
        case $access in
            all) label="${green}read/write${reset}" ;;
            some) label="${yellow}partial${reset}" ;;
            none) label="${red}no access${reset}" ;;
        esac
        rules=$(rules_for "${PIDS[i]}")
        printf "  ${bold}%d)${reset} %s ${dim}(%s:%s)${reset}\n" "$((i + 1))" "${NAMES[i]}" "$VENDOR" "${PIDS[i]}"
        printf "     access: %s   HID++: %s   driver: %s\n" "$label" "${HIDPP[i]}" "${DRIVERS[i]}"
        printf "     nodes:  %s\n" "${NODES[i]}"
        printf "     rule:   %s\n" "${rules:-${dim}none${reset}}"
    done
}

# ── Actions ────────────────────────────────────────────────────────────────

confirm() {
    local answer
    read -r -p "$1 [y/N] " answer
    [[ $answer == [yY] || $answer == [yY][eE][sS] ]]
}

rule_line() {
    printf 'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="%s", ATTRS{idProduct}=="%s", TAG+="uaccess"' "$VENDOR" "$1"
}

reload_udev() {
    sudo udevadm control --reload-rules
    sudo udevadm trigger --action=change --subsystem-match=hidraw
    sudo udevadm settle
}

add_rules() {
    local indexes=("$@") i pid new=() existing=""
    [[ -f $RULES_FILE ]] && existing=$(<"$RULES_FILE")
    for i in "${indexes[@]}"; do
        pid=${PIDS[i]}
        if grep -qF "ATTRS{idProduct}==\"$pid\"" <<<"$existing"; then
            echo "  $pid is already in $RULES_FILE"
        else
            new+=("# ${NAMES[i]}" "$(rule_line "$pid")")
        fi
    done
    if (( ${#new[@]} == 0 )); then
        echo "Nothing to add."
        return
    fi
    echo
    echo "These lines will be appended to ${bold}$RULES_FILE${reset}:"
    printf '  %s\n' "${new[@]}"
    echo "Then udev reloads its rules and re-applies them to the hidraw devices."
    confirm "Proceed (uses sudo)?" || { echo "Cancelled."; return; }
    if [[ ! -f $RULES_FILE ]]; then
        printf '# Added by logimouse grant-access.sh: gives the logged-in user access to these\n# Logitech devices'"'"' hidraw nodes (HID++). Remove a device'"'"'s two lines to revoke it.\n' |
            sudo tee "$RULES_FILE" >/dev/null
    fi
    printf '%s\n' "${new[@]}" | sudo tee -a "$RULES_FILE" >/dev/null
    reload_udev
    echo "${green}Rule added.${reset}"
}

grant_acl() {
    local indexes=("$@") i nodes=""
    for i in "${indexes[@]}"; do
        nodes+=" ${NODES[i]}"
    done
    echo
    echo "This runs: sudo setfacl -m u:$USER:rw$nodes"
    echo "The access lasts until the device is unplugged or the system reboots."
    confirm "Proceed (uses sudo)?" || { echo "Cancelled."; return; }
    # shellcheck disable=SC2086
    sudo setfacl -m "u:$USER:rw" $nodes
    echo "${green}Access granted.${reset}"
}

# Copies stdin to stdout without the rule for product $1 and the comment line naming it
# just above.
filter_rule() {
    local pid=$1 line out=()
    while IFS= read -r line; do
        if [[ $line == *"ATTRS{idProduct}==\"$pid\""* ]]; then
            if (( ${#out[@]} > 0 )) && [[ ${out[-1]} == "# "* && ${out[-1]} != "# Added by"* && ${out[-1]} != "# Logitech devices"* ]]; then
                unset 'out[-1]'
            fi
            continue
        fi
        out+=("$line")
    done
    (( ${#out[@]} == 0 )) || printf '%s\n' "${out[@]}"
}

remove_rules() {
    if [[ ! -f $RULES_FILE ]]; then
        echo "No $RULES_FILE: nothing to remove."
        return
    fi
    echo
    echo "Current ${bold}$RULES_FILE${reset}:"
    sed 's/^/  /' "$RULES_FILE"
    local answer pid
    read -r -p "Product id to remove (e.g. c094), 'all' to delete the file, or Enter to cancel: " answer
    answer=$(tr 'A-F' 'a-f' <<<"$answer")
    if [[ -z $answer ]]; then
        echo "Cancelled."
        return
    fi
    if [[ $answer == all ]]; then
        confirm "Delete $RULES_FILE (uses sudo)?" || { echo "Cancelled."; return; }
        sudo rm "$RULES_FILE"
    else
        pid=$answer
        if ! grep -qF "ATTRS{idProduct}==\"$pid\"" "$RULES_FILE"; then
            echo "$pid is not in $RULES_FILE."
            return
        fi
        confirm "Remove the rule for $pid (uses sudo)?" || { echo "Cancelled."; return; }
        filter_rule "$pid" <"$RULES_FILE" | sudo tee "$RULES_FILE.new" >/dev/null
        sudo mv "$RULES_FILE.new" "$RULES_FILE"
    fi
    reload_udev
    echo "${green}Removed.${reset} Access already granted stays until the device is replugged."
}

# Turns "1,3" or "1 3" or "a" into zero-based indexes; prints nothing when invalid.
parse_selection() {
    local input=$1 token out=() i
    if [[ $input == a ]]; then
        for i in "${!PIDS[@]}"; do
            [[ $(access_of "${NODES[i]}") != all ]] && out+=("$i")
        done
        echo "${out[*]:-}"
        return
    fi
    for token in ${input//,/ }; do
        [[ $token =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#PIDS[@]} )) || { echo ""; return; }
        out+=("$((token - 1))")
    done
    echo "${out[*]:-}"
}

# ── Main loop ──────────────────────────────────────────────────────────────

while true; do
    scan
    show
    echo
    echo "Pick devices by number (e.g. ${bold}2${reset} or ${bold}1,3${reset}), ${bold}a${reset} for every device without access,"
    echo "${bold}r${reset} to remove rules added by this script, ${bold}s${reset} to scan again, or ${bold}q${reset} to quit."
    read -r -p "> " choice || exit 0
    case $choice in
        q|Q|"") exit 0 ;;
        s|S) continue ;;
        r|R) remove_rules; continue ;;
    esac
    selection=$(parse_selection "$choice")
    if [[ -z $selection ]]; then
        echo "${red}Nothing selected${reset}: use numbers from the list, a, r, s or q."
        continue
    fi
    read -r -a indexes <<<"$selection"
    echo
    echo "Selected:"
    for i in "${indexes[@]}"; do
        echo "  - ${NAMES[i]} ($VENDOR:${PIDS[i]})"
    done
    echo
    echo "  ${bold}1)${reset} Permanent: add a udev rule, so access is granted whenever it is plugged in (recommended)"
    echo "  ${bold}2)${reset} Temporary: grant access to the current nodes until unplug or reboot"
    read -r -p "How? [1/2, Enter to cancel] " method
    case $method in
        1) add_rules "${indexes[@]}" ;;
        2) grant_acl "${indexes[@]}" ;;
        *) echo "Cancelled." ;;
    esac
done
