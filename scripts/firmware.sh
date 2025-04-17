#!/bin/bash
#

# shellcheck disable=SC2154,SC2086,SC2059 

#############################
# Install Full ROM Firmware #
#############################
function flash_full_rom()
{
    echo_green "\nInstall/Update UEFI Full ROM Firmware"
    echo_yellow "IMPORTANT: flashing the firmware has the potential to brick your device,
requiring relatively inexpensive hardware and some technical knowledge to
recover.Not all boards can be tested prior to release, and even then slight
differences in hardware can lead to unforseen failures.
If you don't have the ability to recover from a bad flash, you're taking a risk.

You have been warned."

    [[ "$isChromeOS" = true ]] && echo_yellow "Also, flashing Full ROM firmware will remove your ability to run ChromeOS."

    read -rep "Do you wish to continue? [y/N] "
    [[ "$REPLY" = "y" || "$REPLY" = "Y" ]] || return

    #spacing
    echo -e ""

    # ensure hardware write protect disabled
    [[ "$wpEnabled" = true ]] && { exit_red "\nHardware write-protect enabled, cannot flash Full ROM firmware."; return 1; }

    #special warning for CR50 devices
    if [[ "$isStock" = true && "$hasCR50" = true ]]; then
    echo_yellow "NOTICE: flashing your Chromebook is serious business.
To ensure recovery in case something goes wrong when flashing,
be sure to set the ccd capability 'FlashAP Always' using your
USB-C debug cable, otherwise recovery will involve disassembling
your device (which is very difficult in some cases)."

    echo_yellow "If you wish to continue, type: 'I ACCEPT' and press enter."
    read -re
    [[ "$REPLY" = "I ACCEPT" ]] || return
    fi

    #UEFI notice if flashing from ChromeOS or Legacy
    if [[ ! -d /sys/firmware/efi ]]; then
        [[ "$isChromeOS" = true ]] && currOS="ChromeOS" || currOS="Your Legacy-installed OS"
        echo_yellow "
NOTE: After flashing UEFI firmware, you will need to install a UEFI-compatible
OS; ${currOS} will no longer be bootable. See https://mrchromebox.tech/#faq"
        REPLY=""
        read -rep "Press Y to continue or any other key to abort. "
        [[ "$REPLY" = "y" || "$REPLY" = "Y" ]] || return
    fi

    # PCO boot device notice
    if [[ "$isPCO" = true && ! -d /sys/firmware/efi ]]; then
        echo_yellow "
NOTE: Booting from eMMC on AMD Picasso-based devices does not currently work --
only NVMe, SD and USB. If you have a device with eMMC storage you will not be
able to boot from it after installing the UEFI Full ROM firmware."
        REPLY=""
        read -rep "Press Y to continue or any other key to abort. "
        [[ "$REPLY" = "y" || "$REPLY" = "Y" ]] || return
    fi

    #determine correct file / URL
    firmware_source=${fullrom_source}
    eval coreboot_file="$`echo "coreboot_uefi_${device}"`"

    #rammus special case (upgrade from older UEFI firmware)
    if [ "$device" = "rammus" ]; then
        echo -e ""
        echo_yellow "Unable to determine Chromebook model"
        echo -e "Because of your current firmware, I'm unable to
determine the exact mode of your Chromebook.  Are you using
an Asus C425 (LEONA) or Asus C433/C434 (SHYVANA)?
"
        REPLY=""
        while [[ "$REPLY" != "L" && "$REPLY" != "l" && "$REPLY" != "S" && "$REPLY" != "s"  ]]
        do
            read -rep "Enter 'L' for LEONA, 'S' for SHYVANA: "
            if [[ "$REPLY" = "S" || "$REPLY" = "s" ]]; then
                coreboot_file=${coreboot_uefi_shyvana}
            else
                coreboot_file=${coreboot_uefi_leona}
            fi
        done
    fi

    #coral special case (variant not correctly identified)
    if [ "$device" = "coral" ]; then
        echo -e ""
        echo_yellow "Unable to determine correct Chromebook model"
        echo -e "Because of your current firmware, I'm unable to determine the exact mode of your Chromebook.
Please select the number for the correct option from the list below:"

        coral_boards=(
            "ASTRONAUT (Acer Chromebook 11 [C732])"
            "BABYMEGA (Asus Chromebook C223NA)"
            "BABYTIGER (Asus Chromebook C523NA)"
            "BLACKTIP (CTL Chromebook NL7/NL7T)"
            "BLUE (Acer Chromebook 15 [CB315])"
            "BRUCE (Acer Chromebook Spin 15 [CP315])"
            "EPAULETTE (Acer Chromebook 514)"
            "LAVA (Acer Chromebook Spin 11 [CP311])"
            "NASHER (Dell Chromebook 11 5190)"
            "NASHER360 (Dell Chromebook 11 5190 2-in-1)"
            "RABBID (Asus Chromebook C423)"
            "ROBO (Lenovo 100e Chromebook)"
            "ROBO360 (Lenovo 500e Chromebook)"
            "SANTA (Acer Chromebook 11 [CB311-8H])"
            "WHITETIP (CTL Chromebook J41/J41T)"
            )

        select board in "${coral_boards[@]}"; do
            board=$(echo ${board,,} | cut -f1 -d ' ')
            eval coreboot_file=$`echo "coreboot_uefi_${board}"`
            break;
        done
    fi

    # ensure we have a file to flash
    if [[ "$coreboot_file" = "" ]]; then
        exit_red "The script does not currently have a firmware file for your device (${device^^}); cannot continue."; return 1
    fi

    #extract device serial if present in cbfs
    ${cbfstoolcmd} /tmp/bios.bin extract -n serial_number -f /tmp/serial.txt >/dev/null 2>&1

    #extract device HWID
    if [[ "$isStock" = "true" ]]; then
        ${gbbutilitycmd} /tmp/bios.bin --get --hwid | sed 's/[^ ]* //' > /tmp/hwid.txt 2>/dev/null
    else
        ${cbfstoolcmd} /tmp/bios.bin extract -n hwid -f /tmp/hwid.txt >/dev/null 2>&1
    fi

    # create backup if existing firmware is stock
    if [[ "$isStock" = "true" ]]; then
        if [[ "$isEOL" = "false" ]]; then
            REPLY=y
        else
            echo_yellow "\nCreate a backup copy of your stock firmware?"
            read -erp "This is highly recommended in case you wish to return your device to stock
configuration/run ChromeOS, or in the (unlikely) event that things go south
and you need to recover using an external EEPROM programmer. [Y/n] "
        fi
        [[ "$REPLY" = "n" || "$REPLY" = "N" ]] && true || backup_firmware
        #check that backup succeeded
        [ $? -ne 0 ] && return 1
    fi

    #download firmware file
    cd /tmp || { exit_red "Error changing to tmp dir; cannot proceed"; return 1; }
    echo_yellow "\nDownloading Full ROM firmware\n(${coreboot_file})"
    if ! $CURL -sLO "${firmware_source}${coreboot_file}"; then
        exit_red "Firmware download failed; cannot flash. curl error code $?"; return 1
    fi
    if ! $CURL -sLO "${firmware_source}${coreboot_file}.sha1"; then
        exit_red "Firmware checksum download failed; cannot flash."; return 1
    fi

    #verify checksum on downloaded file
    if ! sha1sum -c "${coreboot_file}.sha1" > /dev/null 2>&1; then
        exit_red "Firmware image checksum verification failed; download corrupted, cannot flash."; return 1
    fi

    #persist serial number?
    if [ -f /tmp/serial.txt ]; then
        echo_yellow "Persisting device serial number"
        ${cbfstoolcmd} "${coreboot_file}" add -n serial_number -f /tmp/serial.txt -t raw > /dev/null 2>&1
    fi

    #persist device HWID?
    if [ -f /tmp/hwid.txt ]; then
        echo_yellow "Persisting device HWID"
        ${cbfstoolcmd} "${coreboot_file}" add -n hwid -f /tmp/hwid.txt -t raw > /dev/null 2>&1
    fi

    #Persist RW_MRC_CACHE UEFI Full ROM firmware
    ${cbfstoolcmd} /tmp/bios.bin read -r RW_MRC_CACHE -f /tmp/mrc.cache > /dev/null 2>&1
    if [[ $isFullRom = "true" && $? -eq 0 ]]; then
        ${cbfstoolcmd} "${coreboot_file}" write -r RW_MRC_CACHE -f /tmp/mrc.cache > /dev/null 2>&1
    fi

    #Persist SMMSTORE if exists
    if ${cbfstoolcmd} /tmp/bios.bin read -r SMMSTORE -f /tmp/smmstore > /dev/null 2>&1; then
        ${cbfstoolcmd} "${coreboot_file}" write -r SMMSTORE -f /tmp/smmstore > /dev/null 2>&1
    fi

    # persist VPD if possible
    if extract_vpd /tmp/bios.bin; then
        # try writing to RO_VPD FMAP region
        if ! ${cbfstoolcmd} "${coreboot_file}" write -r RO_VPD -f /tmp/vpd.bin > /dev/null 2>&1; then
            # fall back to vpd.bin in CBFS
            ${cbfstoolcmd} "${coreboot_file}" add -n vpd.bin -f /tmp/vpd.bin -t raw > /dev/null 2>&1
        fi
    fi

    #disable software write-protect
    echo_yellow "Disabling software write-protect and clearing the WP range"
    if ! ${flashromcmd} --wp-disable > /dev/null 2>&1 && [[ "$swWp" = "enabled" ]]; then
        exit_red "Error disabling software write-protect; unable to flash firmware."; return 1
    fi

    #clear SW WP range
    if ! ${flashromcmd} --wp-range 0 0 > /dev/null 2>&1; then
        # use new command format as of commit 99b9550
        if ! ${flashromcmd} --wp-range 0,0 > /dev/null 2>&1 && [[ "$swWp" = "enabled" ]]; then
            exit_red "Error clearing software write-protect range; unable to flash firmware."; return 1
        fi
    fi

    #flash Full ROM firmware

    # clear log file
    rm -f /tmp/flashrom.log

    echo_yellow "Installing Full ROM firmware (may take up to 90s)"
    #check if flashrom supports --noverify-all
    if ${flashromcmd} -h | grep -q "noverify-all" ; then
        noverify="-N"
    else
        noverify="-n"
    fi
    #check if flashrom supports logging to file
    if ${flashromcmd} -V -o /dev/null > /dev/null 2>&1; then
        output_params=">/dev/null 2>&1 -o /tmp/flashrom.log"
        ${flashromcmd} ${flashrom_params} ${noverify} -w ${coreboot_file} >/dev/null 2>&1 -o /tmp/flashrom.log
    else
        output_params=">/tmp/flashrom.log 2>&1"
        ${flashromcmd} ${flashrom_params} ${noverify} -w ${coreboot_file} >/tmp/flashrom.log 2>&1
    fi
    if [ $? -ne 0 ]; then
        echo_red "Error running cmd: ${flashromcmd} ${flashrom_params} ${noverify} -w ${coreboot_file} ${output_params}"
        if [ -f /tmp/flashrom.log ]; then
            read -rp "Press enter to view the flashrom log file, then space for next page, q to quit"
            more /tmp/flashrom.log
        fi
        exit_red "An error occurred flashing the Full ROM firmware. DO NOT REBOOT!"; return 1
    else
        echo_green "Full ROM firmware successfully installed/updated."

        #Prevent from trying to boot stock ChromeOS install
        if [[ "$isStock" = true && "$isChromeOS" = true && "$boot_mounted" = true ]]; then
            rm -rf /tmp/boot/efi > /dev/null 2>&1
            rm -rf /tmp/boot/syslinux > /dev/null 2>&1
        fi

        #Warn about long RAM training time
        echo_yellow "IMPORTANT:\nThe first boot after flashing may take substantially
longer than subsequent boots -- up to 30s or more.
Be patient and eventually your device will boot :)"

        # Add note on touchpad firmware for EVE
        if [[ "${device^^}" = "EVE" && "$isStock" = true ]]; then
            echo_yellow "IMPORTANT:\n
If you're going to run Windows on your Pixelbook, you must downgrade
the touchpad firmware now (before rebooting) otherwise it will not work.
Select the D option from the main main in order to do so."
        fi
        #set vars to indicate new firmware type
        isStock=false
        isFullRom=true
        # Add NVRAM reset note for 4.12 release
        if [[ "$isUEFI" = true && "$useUEFI" = true ]]; then
            echo_yellow "IMPORTANT:\n
This update uses a new format to store UEFI NVRAM data, and
will reset your BootOrder and boot entries. You may need to
manually Boot From File and reinstall your bootloader if
booting from the internal storage device fails."
        fi
        firmwareType="Full ROM / UEFI (pending reboot)"
        isUEFI=true
    fi

    read -rep "Press [Enter] to return."
}


##########################
# Restore Stock Firmware #
##########################
function restore_stock_firmware()
{
    echo_green "\nRestore Stock Firmware"

    #spacing
    echo -e ""

    # ensure hardware write protect disabled
    [[ "$wpEnabled" = true ]] && { exit_red "\nHardware write-protect enabled, cannot restore stock firmware."; return 1; }

    # default file to download to
    firmware_file="/tmp/stock-firmware.rom"
	
	restore_fw_from_usb || return 1;
	
    restore_option=1

    [[ "$restore_option" = "Q" ]] && return

    if [[ $restore_option -eq 2 ]]; then
        #extract VPD from current firmware if present
        if extract_vpd /tmp/bios.bin ; then
            #merge with recovery image firmware
            if [ -f /tmp/vpd.bin ]; then
                echo_yellow "Merging VPD into recovery image firmware"
                ${cbfstoolcmd} ${firmware_file} write -r RO_VPD -f /tmp/vpd.bin > /dev/null 2>&1
            fi
        fi

        #extract hwid from current firmware if present
        if ${cbfstoolcmd} /tmp/bios.bin extract -n hwid -f /tmp/hwid.txt > /dev/null 2>&1; then
            #merge with recovery image firmware
            hwid="$(sed 's/^hardware_id: //' /tmp/hwid.txt 2>/dev/null)"
            if [[ "$hwid" != "" ]]; then
                echo_yellow "Injecting HWID into recovery image firmware"
                ${gbbutilitycmd} ${firmware_file} --set --hwid="$hwid" > /dev/null 2>&1
            fi
        fi
    fi

    #clear GBB flags before flashing
    ${gbbutilitycmd} ${firmware_file} --set --flags=0x0 > /dev/null 2>&1

    #flash stock firmware
    echo_yellow "Restoring stock firmware"
    # only verify part of flash we write
    if ! ${flashromcmd} ${flashrom_params} -N -w "${firmware_file}" -o /tmp/flashrom.log > /dev/null 2>&1; then
        cat /tmp/flashrom.log
        exit_red "An error occurred restoring the stock firmware. DO NOT REBOOT!"; return 1
    fi

    #re-enable software WP to prevent recovery issues
    echo_yellow "Re-enabling software write-protect"
    ${flashromcmd} --wp-region WP_RO --fmap > /dev/null 2>&1
    if ! ${flashromcmd} --wp-enable > /dev/null 2>&1; then
        echo_red "Warning: unable to re-enable software write-protect;
you may need to perform ChromeOS recovery with the battery disconnected."
    fi

    #all good
    echo_green "Stock firmware successfully restored."
    echo_green "After rebooting, you need to restore ChromeOS using ChromeOS Recovery media.
See: https://google.com/chromeos/recovery for more info."
    read -rep "Press [Enter] to return."
    umount /tmp/usb > /dev/null 2>&1
    #set vars to indicate new firmware type
    isStock=true
    isFullRom=false
    isUEFI=false
    firmwareType="Stock ChromeOS (pending reboot)"
}

function restore_fw_from_usb()
{
    read -rep "
Connect the USB/SD device which contains the backed-up stock firmware and press [Enter] to continue. "

    list_usb_devices || { exit_red "No USB devices available to read firmware backup."; return 1; }

    usb_dev_index=""
    while [[ "$usb_dev_index" = "" || "$usb_dev_index" -le 0 || "$usb_dev_index" -gt $num_usb_devs ]]; do
        read -rep "Enter the number for the device which contains the stock firmware backup: " usb_dev_index
        if [[ "$usb_dev_index" = "" || "$usb_dev_index" -le 0 || "$usb_dev_index" -gt $num_usb_devs ]]; then
            echo -e "Error: Invalid option selected; enter a number from the list above."
        fi
    done

    usb_device="${usb_devs[$((usb_dev_index - 1))]}"
    mkdir /tmp/usb > /dev/null 2>&1
    mount "${usb_device}" /tmp/usb > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        mount "${usb_device}1" /tmp/usb
    fi
    if [ $? -ne 0 ]; then
        echo_red "USB device failed to mount; cannot proceed."
        read -rep "Press [Enter] to return."
        umount /tmp/usb > /dev/null 2>&1
        return
    fi

    echo_yellow "\n(Potential) Firmware Files on USB:"

    mapfile -t firmware_files < <(find /tmp/usb -maxdepth 1 -type f \( -iname "*.rom" -o -iname "*.bin" \) -exec basename {} \;)
    
    if [ ${#firmware_files[@]} -eq 0 ]; then
        echo_red "No firmware files found on USB device."
        read -rep "Press [Enter] to return."
        umount /tmp/usb > /dev/null 2>&1
        return 1
    fi

    for i in "${!firmware_files[@]}"; do
        printf "%3d) %s\n" $((i + 1)) "${firmware_files[$i]}"
    done

    selected_index=""
    while [[ "$selected_index" = "" || "$selected_index" -le 0 || "$selected_index" -gt ${#firmware_files[@]} ]]; do
        read -rep "Select the firmware file by number: " selected_index
        if [[ "$selected_index" = "" || "$selected_index" -le 0 || "$selected_index" -gt ${#firmware_files[@]} ]]; then
            echo -e "Error: Invalid option selected; enter a number from the list above."
        fi
    done

    firmware_file="/tmp/usb/${firmware_files[$((selected_index - 1))]}"

    if [ ! -f "$firmware_file" ]; then
        echo_red "Unexpected error: selected firmware file not found."
        read -rep "Press [Enter] to return."
        umount /tmp/usb > /dev/null 2>&1
        return 1
    fi

    echo -e ""
    echo_green "Firmware file selected: $firmware_file"
	if [ ! -f ${firmware_file} ]; then
		echo_red "Invalid filename entered; unable to restore stock firmware."
		read -rep "Press [Enter]  to return."
		umount /tmp/usb > /dev/null 2>&1
		return 1
	fi
	#text spacing
	echo -e ""
}


########################
# Extract firmware VPD #
########################
function extract_vpd()
{
    #check params
    [[ -z "$1" ]] && { exit_red "Error: extract_vpd(): missing function parameter"; return 1; }

    local firmware_file="$1"

    #try FMAP extraction
    if ! ${cbfstoolcmd} ${firmware_file} read -r RO_VPD -f /tmp/vpd.bin >/dev/null 2>&1 ; then
        #try CBFS extraction
        if ! ${cbfstoolcmd} ${firmware_file} extract -n vpd.bin -f /tmp/vpd.bin >/dev/null 2>&1 ; then
            echo_yellow "No VPD found in current firmware"
            return 1
        fi
    fi
    echo_yellow "VPD extracted from current firmware"
    return 0
}


#########################
# Backup stock firmware #
#########################
function backup_firmware()
{
    echo -e ""
    read -rep "Connect the USB/SD device to store the firmware backup and press [Enter]
to continue.  This is non-destructive, but it is best to ensure no other
USB/SD devices are connected. "

    if ! list_usb_devices; then
        backup_fail "No USB devices available to store firmware backup."
        return 1
    fi

    usb_dev_index=""
    while [[ "$usb_dev_index" = "" || ($usb_dev_index -le 0 && $usb_dev_index -gt $num_usb_devs) ]]; do
        read -rep "Enter the number for the device to be used for firmware backup: " usb_dev_index
        if [[ "$usb_dev_index" = "" || ($usb_dev_index -le 0 && $usb_dev_index -gt $num_usb_devs) ]]; then
            echo -e "Error: Invalid option selected; enter a number from the list above."
        fi
    done

    usb_device="${usb_devs[${usb_dev_index}-1]}"
    mkdir /tmp/usb > /dev/null 2>&1
    if ! mount "${usb_device}" /tmp/usb > /dev/null 2>&1; then
        if ! mount "${usb_device}1" /tmp/usb > /dev/null 2>&1; then
            backup_fail "USB backup device failed to mount; cannot proceed."
            return 1
        fi
    fi
    backupname="stock-firmware-${boardName}-$(date +%Y%m%d).rom"
    echo_yellow "\nSaving firmware backup as ${backupname}"
    if ! cp /tmp/bios.bin /tmp/usb/${backupname}; then
        backup_fail "Failure copying stock firmware to USB; cannot proceed."
        return 1
    fi
    sync
    umount /tmp/usb > /dev/null 2>&1
    rmdir /tmp/usb
    echo_green "Firmware backup complete. Remove the USB stick and press [Enter] to continue."
    read -rep ""
}

function backup_fail()
{
    umount /tmp/usb > /dev/null 2>&1
    rmdir /tmp/usb > /dev/null 2>&1
    exit_red "\n$@"
}



########################
# Firmware Update Menu #
########################
function menu_fwupdate() {

    if [[ "$isFullRom" = true ]]; then
        uefi_menu
    else
        stock_menu
    fi
}

function show_header() {
    printf "\ec"
    echo -e "${NORMAL}\n ChromeOS Device Firmware Utility Script ${script_date} ${NORMAL}"
    echo -e "${NORMAL} (c) Mr Chromebox <mrchromebox@gmail.com> ${NORMAL}"
    echo -e "${MENU}*********************************************************${NORMAL}"
    echo -e "${MENU}**${NUMBER}     Device: ${NORMAL}${deviceDesc}"
    echo -e "${MENU}**${NUMBER} Board Name: ${NORMAL}${boardName^^}"
    echo -e "${MENU}**${NUMBER}   Platform: ${NORMAL}$deviceCpuType"
    echo -e "${MENU}**${NUMBER}    Fw Type: ${NORMAL}$firmwareType"
    echo -e "${MENU}**${NUMBER}     Fw Ver: ${NORMAL}$fwVer ($fwDate)"
    if [[ $isUEFI = true && $hasUEFIoption = true ]]; then
        # check if update available
        curr_yy=$(echo $fwDate | cut -f 3 -d '/')
        curr_mm=$(echo $fwDate | cut -f 1 -d '/')
        curr_dd=$(echo $fwDate | cut -f 2 -d '/')
        eval coreboot_file=$`echo "coreboot_uefi_${device}"`
        date=$(echo $coreboot_file | grep -o "mrchromebox.*" | cut -f 2 -d '_' | cut -f 1 -d '.')
        uefi_yy=$(echo $date | cut -c1-4)
        uefi_mm=$(echo $date | cut -c5-6)
        uefi_dd=$(echo $date | cut -c7-8)
        if [[ ("$firmwareType" != *"pending"*) && (($uefi_yy > $curr_yy) || \
            ("$uefi_yy" = "$curr_yy" && "$uefi_mm" > "$curr_mm") || \
            ("$uefi_yy" = "$curr_yy" && "$uefi_mm" = "$curr_mm" && "$uefi_dd" > "$curr_dd")) ]]; then
            echo -e "${MENU}**${NORMAL}             ${GREEN_TEXT}Update Available ($uefi_mm/$uefi_dd/$uefi_yy)${NORMAL}"
        fi
    fi
    if [ "$wpEnabled" = true ]; then
        echo -e "${MENU}**${NUMBER}      Fw WP: ${RED_TEXT}Enabled${NORMAL}"
        WP_TEXT=${RED_TEXT}
    else
        echo -e "${MENU}**${NUMBER}      Fw WP: ${NORMAL}Disabled"
        WP_TEXT=${GREEN_TEXT}
    fi
    echo -e "${MENU}*********************************************************${NORMAL}"
}

function stock_menu() {
	show_header
    restore_stock_firmware
    cleanup
    reboot
}

function uefi_menu() {
	show_header
    restore_stock_firmware
    cleanup
    reboot
}
