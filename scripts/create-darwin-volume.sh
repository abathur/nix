#!/usr/bin/env bash
set -eu

# support import-only `. create-darwin-volume.sh no-main[ ...]`
if [ "${1-}" = "no-main" ]; then
    shift
    readonly _CREATE_VOLUME_NO_MAIN=1
else
    readonly _CREATE_VOLUME_NO_MAIN=0
    # declare some things we expect to inherit from install-multi-user
    # I don't love this...
    readonly NIX_ROOT="${NIX_ROOT:-/nix}"
    readonly ESC='\033[0m'
    readonly GREEN='\033[32m'
    readonly RED='\033[31m'
    _sudo() {
        shift # throw away the 'explanation'
        /usr/bin/sudo "$@"
    }
fi

# make it easy to play w/ 'Case-sensitive APFS'
readonly NIX_VOLUME_FS="${NIX_VOLUME_FS:-APFS}"
readonly NIX_VOLUME_LABEL="${NIX_VOLUME_LABEL:-Nix}"
# shellcheck disable=SC1003,SC2026
readonly NIX_VOLUME_FOR_FSTAB="${NIX_VOLUME_LABEL/ /'\\\'040}"
readonly NIX_VOLUME_MOUNTD_DEST="${NIX_VOLUME_MOUNTD_DEST:-/Library/LaunchDaemons/org.nixos.darwin-store.plist}"

# i.e., "disk1"
root_disk_identifier() {
    /usr/sbin/diskutil info -plist / | xmllint --xpath "/plist/dict/key[text()='ParentWholeDisk']/following-sibling::string[1]/text()" -
}

readonly ROOT_SPECIAL_DEVICE="$(root_disk_identifier)" # usually 'disk1'
# Strongly assuming we'll make a volume on the device root is on
# But you can override NIX_VOLUME_USE_DISK to create it on some other device
readonly NIX_VOLUME_USE_DISK="${NIX_VOLUME_USE_DISK:-$ROOT_SPECIAL_DEVICE}"

substep(){
    # shellcheck disable=SC2068
    printf "   %s\n" "" "- $1" "" ${@:2}
}

# TODO: document or variable-ify these
printf -v _UNCHANGED_GRP_FMT "%b" $'\033[2m%='"$ESC"
printf -v _OLD_LINE_FMT "%b" $'\033[1;7;31m-'"$ESC ${RED}%L${ESC}"
printf -v _NEW_LINE_FMT "%b" $'\033[4;32m+'"$ESC ${GREEN}%L${ESC}"
_diff() {
    # shellcheck disable=SC2068
    /usr/bin/diff --unchanged-group-format="$_UNCHANGED_GRP_FMT" --old-line-format="$_OLD_LINE_FMT" --new-line-format="$_NEW_LINE_FMT" --unchanged-line-format="  %L" $@
}

confirm_rm() {
    if ui_confirm "Can we remove $1?"; then
        # ok "Yay! Thanks! Let's get going!"
        _sudo "to remove $1" rm "$1"
    fi
}
confirm_edit() {
    echo "We might be able to help you make this edit. Here's the diff:"
    # TODO: technically we could also test the diff
    # (to ensure it differs) but it should...
    _diff "$1" "$2"
    if ui_confirm "Does the change above look right?"; then
        # ok "Yay! Thanks! Let's get going!"
        _sudo "remove nix from $1" cp "$2" "$1"
    fi
}

volume_uuid(){
    /usr/sbin/diskutil info -plist "$1" | xmllint --xpath "(/plist/dict/key[text()='VolumeUUID']/following-sibling::string[1]/text())" - 2>/dev/null
}

volume_special_device(){
    /usr/sbin/diskutil info -plist "$1" | xmllint --xpath "(/plist/dict/key[text()='DeviceIdentifier']/following-sibling::string[1]/text())" - 2>/dev/null
}
find_nix_volume() {
    /usr/sbin/diskutil apfs list -plist "$1" | xmllint --xpath "(/plist/dict/array/dict/key[text()='Volumes']/following-sibling::array/dict/key[text()='Name']/following-sibling::string[text()='$NIX_VOLUME_LABEL'])[1]" - &>/dev/null
}
find_nix_volume_label() {
    /usr/sbin/diskutil apfs list -plist "$1" | xmllint --xpath "(/plist/dict/array/dict/key[text()='Volumes']/following-sibling::array/dict/key[text()='Name']/following-sibling::string[starts-with(translate(text(),'N','n'),'nix')]/text())[1]" - 2>/dev/null || true
}

test_fstab() {
    /usr/bin/grep -q "$NIX_ROOT apfs rw" /etc/fstab 2>/dev/null
}

# TODO: none of these 3 funcs are configurable
test_nix_symlink() {
    [ -L "/nix" ] || /usr/bin/grep -q "^nix." /etc/synthetic.conf 2>/dev/null
}
test_synthetic_conf_mountable() {
    /usr/bin/grep -q "^nix$" /etc/synthetic.conf 2>/dev/null
}
test_synthetic_conf_symlinked() {
    /usr/bin/grep -qE "^nix\s+\S{3,}" /etc/synthetic.conf 2>/dev/null
}

test_nix_volume_mountd_installed() {
    test -e "$NIX_VOLUME_MOUNTD_DEST"
}

# if there's no UUID match, true here is a cruft smell
test_keychain_by_label() {
    # Note: doesn't need sudo just to check; doesn't output pw
    security find-generic-password -a "$NIX_VOLUME_LABEL" &>/dev/null
}
# current volume password
test_keychain_by_uuid() {
    # Note: doesn't need sudo just to check; doesn't output pw
    security find-generic-password -s "$(volume_uuid "$NIX_VOLUME_LABEL")" &>/dev/null
}

# Create the paths defined in synthetic.conf, saving us a reboot.
create_synthetic_objects(){
    # Big Sur takes away the -B flag we were using and replaces it
    # with a -t flag that appears to do the same thing (but they
    # don't behave exactly the same way in terms of return values).
    # This feels a little dirty, but as far as I can tell the
    # simplest way to get the right one is to just throw away stderr
    # and call both... :]
    {
        /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -t || true # Big Sur
        /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -B || true # Catalina
    } >/dev/null 2>&1
}

test_nix() {
    test -d "$NIX_ROOT"
}

test_voldaemon() {
    test -f "$NIX_VOLUME_MOUNTD_DEST"
}

test_filevault_in_use() {
    /usr/bin/fdesetup isactive >/dev/null
}

# use after error msg for conditions we don't understand
suggest_report_error(){
    # ex "error: something sad happened :(" >&2
    echo "       please report this @ https://github.com/nixos/nix/issues" >&2
}

generate_mount_command(){
    # TODO: lilyball: If a volume exists starting with "Nix" already, we use that volume. This mount command needs to be parameterized accordingly ... for that matter we should probably embed the service too (pass the -s "$UUID" flag), so that way if I delete the volume and clean up everything except for my keychain password, when it creates a brand new password this won't accidentally read the old one.
    if test_filevault_in_use; then
        printf "    <string>%s</string>\n" /bin/sh -c "/usr/bin/security find-generic-password -a '$NIX_VOLUME_LABEL' -w | /usr/sbin/diskutil apfs unlockVolume '$NIX_VOLUME_LABEL' -mountpoint $NIX_ROOT -stdinpassphrase"
    else
        printf "    <string>%s</string>\n" /usr/sbin/diskutil mount -mountPoint "$NIX_ROOT" "$NIX_VOLUME_LABEL"
    fi
}

# TODO: thread uuid through these, I think?
generate_mount_daemon(){
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>RunAtLoad</key>
  <true/>
  <key>Label</key>
  <string>org.nixos.darwin-store</string>
  <key>ProgramArguments</key>
  <array>
$(generate_mount_command)
  </array>
</dict>
</plist>
EOF
}

uninstall_launch_daemon_directions() {
    substep "Uninstall LaunchDaemon $1" \
      "  sudo launchctl bootout system/$1" \
      "  sudo rm $2"
}
uninstall_launch_daemon_prompt() {
    if ui_confirm "Can we uninstall the LaunchDaemon $2?"; then
        _sudo "to terminate the daemon" launchctl bootout "system/$1"
        _sudo "to remove the daemon definition" rm "$2"
    fi
}
nix_volume_mountd_uninstall_directions() {
    uninstall_launch_daemon_directions "org.nixos.darwin-store" "$NIX_VOLUME_MOUNTD_DEST"
}
nix_volume_mountd_uninstall_prompt() {
    uninstall_launch_daemon_prompt "org.nixos.darwin-store" "$NIX_VOLUME_MOUNTD_DEST"
}
nix_daemon_uninstall_directions() {
    uninstall_launch_daemon_directions "org.nixos.nix-daemon" "$NIX_DAEMON_DEST"
}
nix_daemon_uninstall_prompt() {
    uninstall_launch_daemon_prompt "org.nixos.nix-daemon" "$NIX_DAEMON_DEST"
}

synthetic_conf_uninstall_directions() {
    # :1 to strip leading slash
    # shellcheck disable=SC2086
    substep "Remove ${NIX_ROOT:1} from /etc/synthetic.conf" \
      "  If nix is the only entry: sudo rm /etc/synthetic.conf" \
      "  Otherwise: grep -v "^${NIX_ROOT:1}$" /etc/synthetic.conf | sudo dd of=/etc/synthetic.conf"
}

# TODO: this prompted for removal, but context was poor
synthetic_conf_uninstall_prompt() {
    # there are a few things we can do here
    # 1. if grep -v didn't match anything (also, if there's no diff), we know this is moot
    # 2. if grep -v was empty (but did match?) I think we know that we can just remove the file
    # 3. if the edit doesn't ~empty the file, show them the diff and ask
    # shellcheck disable=SC2086
    if ! grep -v "^${NIX_ROOT:1}$" /etc/synthetic.conf > $SCRATCH/synthetic.conf.edit; then
        if confirm_rm "/etc/synthetic.conf"; then
            return 0
        fi
    else
        if cmp <<<"" "$SCRATCH/synthetic.conf.edit"; then
            # this edit would leave it empty; propose deleting it
            if confirm_rm "/etc/synthetic.conf"; then
                return 0
            fi
        else
            if confirm_edit "$SCRATCH/synthetic.conf.edit" "/etc/synthetic.conf"; then
                return 0
            fi
        fi
    fi
    # fallback instructions
    echo "Manually remove nix from /etc/synthetic.conf"
}
fstab_uninstall_directions() {
    substep "Remove ${NIX_ROOT} from /etc/fstab" \
      "  If nix is the only entry: sudo rm /etc/fstab" \
      "  Otherwise, run 'sudo vifs' to remove the nix line"
}
# oh_hush() {
#     our_ed="$(mktemp)"
#     chmod 700 "$our_ed"
#     cat >"$our_ed" <<EOF
# #!/bin/sh
# cat "$1" - >/etc/fstab
# rm "$our_ed"
# EOF
# }
add_nix_vol_fstab_line() {
    # shellcheck disable=SC2068
    EDITOR="ex" _sudo "to add nix to fstab" "$@" <<EOF
:a
LABEL=$NIX_VOLUME_FOR_FSTAB $NIX_ROOT apfs rw,noauto,nobrowse
.
:x
EOF
#     <<EOF
# 0a1,5
# > #
# > # Warning - this file should only be modified with vifs(8)
# > #
# > # Failure to do so is unsupported and may be destructive.
# > #
# 6c6
# < 
# ---
# > LABEL=${NIX_VOLUME_FOR_FSTAB} $NIX_ROOT apfs rw,noauto,nobrowse
# EOF
#     <<EOF
# \$a
# LABEL=$NIX_VOLUME_FOR_FSTAB $NIX_ROOT apfs rw,noauto,nobrowse
# .
# w
# q
# EOF
}
# patch blah <<EOF
# 0a1,5
# > #
# > # Warning - this file should only be modified with vifs(8)
# > #
# > # Failure to do so is unsupported and may be destructive.
# > #
# 6c6
# <
# ---
# > LABEL=${NIX_VOLUME_FOR_FSTAB} $NIX_ROOT apfs rw,nobrowse
# EOF
# patch --dry-run --verbose blah <<EOF
# 1c1
# < LABEL=${NIX_VOLUME_FOR_FSTAB} $NIX_ROOT apfs rw,nobrowse
# ---
# >
# EOF
delete_nix_vol_fstab_line() {
    # TODO: I'm scaffolding this to handle the new nix volumes
    # but it might be nice to generalize a smidge further to
    # go ahead and set up a pattern for curing "old" things
    # we no longer do?
    # shellcheck disable=SC2068
    EDITOR="patch" _sudo "to cut nix from fstab" "$@" < <(diff /etc/fstab <(grep -v "LABEL=$NIX_VOLUME_FOR_FSTAB $NIX_ROOT apfs rw" /etc/fstab))
    # left ",noauto,nobrowse" out of the grep; people might fiddle this a little
#     <<EOF
# 1c1
# < LABEL=${NIX_VOLUME_FOR_FSTAB} $NIX_ROOT apfs rw,noauto,nobrowse
# ---
# >
# EOF
#     <<EOF
# /LABEL=${NIX_VOLUME_FOR_FSTAB}[[:space:]]\{1,\}${NIX_ROOT/\//\\/}[[:space:]]\{1,\}apfs[[:space:]]\{1,\}rw,noauto,nobrowse/
# .d
# w
# q
# EOF
}
fstab_uninstall_prompt() {
    cp /etc/fstab "$SCRATCH/fstab.edit"
    delete_nix_vol_fstab_line patch "$SCRATCH/fstab.edit"

    if cmp <<<"" <(grep -v "^#" "$SCRATCH/fstab.edit") &>/dev/null; then
        # this edit would leave it empty; propose deleting it
        if confirm_rm "/etc/fstab"; then
            return 0
        else
            # fallback instructions
            echo "Manually remove nix from /etc/fstab"
        fi
    else
        echo "We might be able to help you make this edit. Here's the diff:"
        if ! _diff "/etc/fstab" "$SCRATCH/fstab.edit" && ui_confirm "Does the change above look right?"; then
            delete_nix_vol_fstab_line vifs
        else
            # fallback instructions
            echo "Manually remove nix from /etc/fstab"
        fi
    fi
#     EDITOR=ed sudo vifs &>/dev/null <<EOF
# /LABEL=${NIX_VOLUME/ /'\\\'040}[[:space:]]\{1,\}${NIX_ROOT/\//\\/}[[:space:]]\{1,\}apfs[[:space:]]\{1,\}rw,noauto,nobrowse/
# .d
# w
# q
# EOF
}
volume_uninstall_directions() {
    if test_keychain_by_uuid; then
        keychain_uuid_uninstall_directions
    fi
    substep "Destroy the nix data volume" \
      "  sudo diskutil apfs deleteVolume $(volume_special_device "$NIX_VOLUME_LABEL")"
}
darwin_volume_uninstall_directions() {
    if test_synthetic_conf_mountable; then
        synthetic_conf_uninstall_directions
    fi
    if test_fstab; then
        fstab_uninstall_directions
    fi
    if find_nix_volume "$NIX_VOLUME_USE_DISK"; then
        volume_uninstall_directions
        # also handles a keychain entry for this volume
    fi
    # TODO: I'm a little unsure about the below. Target case is an
    # orphaned credential...
    if ! test_keychain_by_uuid && test_keychain_by_label; then
        keychain_label_uninstall_directions
    fi
    if test_nix_volume_mountd_installed; then
        nix_volume_mountd_uninstall_directions
    fi
}
darwin_volume_uninstall_prompts() {
    if test_synthetic_conf_mountable; then
        synthetic_conf_uninstall_prompt
    fi
    if test_fstab; then
        fstab_uninstall_prompt
    fi
    if find_nix_volume "$NIX_VOLUME_USE_DISK"; then
        volume_uninstall_prompt
    fi
    # TODO: I'm a little unsure about the below. Target case is an
    # orphaned credential...
    if ! test_keychain_by_uuid && test_keychain_by_label; then
        keychain_label_uninstall_prompt
    fi
    if test_nix_volume_mountd_installed; then
        nix_volume_mountd_uninstall_prompt
    fi
}
# only a function for keychain_label; the keychain_uuid
# case is handled in volume_uninstall_prompt.
keychain_label_uninstall_prompt() {
    cat <<EOF
It looks like your keychain as one or more orphaned volume passwords.
We can delete them if you like, or you can clean them up later.
EOF
    if ui_confirm "Do you want to review them now?"; then
        cat <<EOF
We'll review each one individually by displaying the raw keychain
entry. Don't worry--it doesn't show the actual password.
EOF
        while test_keychain_by_label; do
            security find-generic-password -a "$NIX_VOLUME_LABEL"
            if ui_confirm "Can we delete this entry?"; then
                _sudo "to remove an old volume password from keychain" \
                security delete-generic-password -a "$NIX_VOLUME_LABEL"
            fi
        done
    else
        keychain_label_uninstall_directions
    fi
}
volume_uninstall_prompt() {
    and_keychain=""
    if test_keychain_by_uuid; then
        and_keychain=" (and its encryption key)"
    fi
    cat <<EOF
We can delete the Nix volume if you're certain you don't need it.

Here are the details of the Nix volume:
$(diskutil info "$NIX_VOLUME_LABEL")
EOF
    if ui_confirm "Can we delete this volume$and_keychain?"; then
        if [ -n "$and_keychain" ]; then
            _sudo "to remove the volume password from keychain" \
                security delete-generic-password -s "$(volume_uuid "$NIX_VOLUME_LABEL")"
        fi
        diskID="$(volume_special_device "$NIX_VOLUME_LABEL")"
        _sudo "to unmount the Nix volume" \
            diskutil unmount force "$diskID"
        _sudo "to delete the Nix volume" \
            diskutil apfs deleteVolume "$diskID"
    else
        # TODO: no clue if it should behave this way.
        if [ -n "$and_keychain" ]; then
            keychain_uuid_uninstall_directions
        fi
        volume_uninstall_directions
    fi
}
keychain_uuid_uninstall_directions() {
    substep "Remove the volume password from keychain" \
      "  sudo security delete-generic-password -s '$(volume_uuid "$NIX_VOLUME_LABEL")'"
}
keychain_label_uninstall_directions() {
    substep "Remove the volume password from keychain" \
      "  sudo security delete-generic-password -a '$NIX_VOLUME_LABEL'"
}

darwin_volume_validate_assumptions() {
    if test -e "$NIX_ROOT"; then
        if test_nix_symlink; then
            if test_synthetic_conf_symlinked; then
                failure <<EOF
$NIX_ROOT is a symlink (maybe because it is included in /etc/synthetic.conf?)
Remove it from synthetic.conf, reboot, and confirm it is not linked.
  $NIX_ROOT -> $(readlink "$NIX_ROOT")
EOF
            else
                failure <<EOF
$NIX_ROOT is a symlink (to $(readlink "$NIX_ROOT")) for some reason.
You'll have to remove this symlink before we can create the Nix volume.
EOF
            fi
        elif test_synthetic_conf_symlinked; then
            failure "Please remove the nix line from /etc/synthetic.conf and reboot before continuing."
        elif test_synthetic_conf_mountable; then
            # TODO: consider whether this is an error or a warning.
            # It would be more ideal to just collect this as a bit of known cruft
            # but only tell the user to go clean everything up if we hit something
            # that is absolutely a dealbreaker later...
            failure <<EOF
nix is already in /etc/synthetic.conf, probably from a previous install.
Please remove it and reboot before continuing.
EOF
        else
            failure "$NIX_ROOT already exists."
        fi
    fi
    if test_synthetic_conf_symlinked; then
        failure "Please remove the nix line from /etc/synthetic.conf before continuing."
    fi
    if test_synthetic_conf_mountable; then
        # TODO: consider whether this is an error or a warning.
        # It would be more ideal to just collect this as a bit of known cruft
        # but only tell the user to go clean everything up if we hit something
        # that is absolutely a dealbreaker later...
        failure <<EOF
nix is already in /etc/synthetic.conf, probably from a previous install.
Please remove it before continuing.
EOF
    fi
    if find_nix_volume "$NIX_VOLUME_USE_DISK"; then
        failure <<EOF
$NIX_VOLUME_USE_DISK already has a '$NIX_VOLUME_LABEL' volume, but the
installer is configured to create a new one. Set NIX_VOLUME_CREATE=0
to tell the installer to use your volume instead of creating one.

Volume information:
$(diskutil info "$NIX_VOLUME_LABEL")
EOF
    fi
    if test_fstab; then
        # TODO: re-use uninstall instrs?
        failure <<EOF
$NIX_ROOT is already in /etc/fstab, probably from a previous install.
Please remove it before continuing.
EOF
    fi
    if test_nix_volume_mountd_installed; then
        # TODO: better message, less haste
        failure "Nix volume mounter already installed."
    fi
    if test_keychain_by_label; then
        # TODO: better message, less haste
        failure "Keychain already has a credential for Nix volume mounter."
    fi
}

setup_synthetic_conf() {
    if ! test_synthetic_conf_mountable; then
        echo "Configuring /etc/synthetic.conf..." >&2
        # TODO: technically /etc/synthetic.d/nix is supported in Big Sur+
        # but handling both takes even more code...

        echo "${NIX_ROOT:1}" | _sudo "to add Nix to /etc/synthetic.conf" \
            /usr/bin/tee -a /etc/synthetic.conf
        if ! test_synthetic_conf_mountable; then
            # TODO failure? figure out how to reconcile two modes here...
            echo "error: failed to configure synthetic.conf;" >&2
            suggest_report_error
            exit 1
        fi
        create_synthetic_objects
        if ! test_nix; then
            echo "error: failed to bootstrap /nix; if a reboot doesn't help," >&2
            suggest_report_error
            exit 1
        fi
    fi
}
# fstab used to be responsible for mounting the volume. Now the last
# step adds a LaunchDaemon responsible for mounting. This is technically
# redundant for mounting, but diskutil appears to pick up mount options
# from fstab (and diskutil's support for specifying them directly is not
# consistent across versions/subcommands), enabling us to specify mount
# options by *label*.
#
# Being able to do all of this by label is helpful because it's a stable
# identifier that we can know at code-time, letting us skirt some logistic
# complexity that comes with doing this by UUID (which is stable, but not
# known ahead of time) or special device name/path (which is not stable).
setup_fstab() {
    if ! test_fstab; then
        echo "Configuring /etc/fstab..." >&2
        add_nix_vol_fstab_line vifs
        # printf "\$a\nLABEL=%s %s apfs rw,noauto,nobrowse\n.\nwq\n" "${NIX_VOLUME_FOR_FSTAB}" "$NIX_ROOT"| EDITOR=/bin/ed /usr/bin/sudo /usr/sbin/vifs
    fi
}
setup_volume() {
    echo "Creating a Nix volume..." >&2
    _sudo "to create the Nix volume" \
        /usr/sbin/diskutil apfs addVolume "$NIX_VOLUME_USE_DISK" "$NIX_VOLUME_FS" "$NIX_VOLUME_LABEL" -mountpoint "$NIX_ROOT"
    new_uuid="$(volume_uuid "$NIX_VOLUME_LABEL")"

    # if [ "$INSTALL_MODE" = "no-daemon" ]; then # exported by caller
    #     # TODO:
    #     # - is there a better way to do this?
    #     # - technically not needed since daemon is default, but I'm trying
    #     # to minimize unnecessary breaks for now
    #     /usr/bin/sudo /usr/sbin/chown "$USER:admin" /nix
    # fi
    #
    #
    # Notes:
    # 1) system is in some sense less secure than user keychain... (it's
    # possible to read the password for decrypting the keychain) but
    # the user keychain appears to be available too late. As far as I
    # can tell, the file with this password (/var/db/SystemKey) is
    # inside the FileVault envelope. If that isn't true, it may make
    # sense to store the password inside the envelope?
    #
    # 2) At some point it would be ideal to have a small binary to serve
    # as the daemon itself, and for it to replace /usr/bin/security here.
    #
    # 3) *UserAgent exemptions should let the system seamlessly supply the
    # password if noauto is removed from fstab entry. This is intentional;
    # the user will hopefully look for help if the volume stops mounting,
    # rather than failing over into subtle race-condition problems.

    if test_filevault_in_use; then
        password="$(/usr/bin/xxd -l 32 -p -c 256 /dev/random)"
        _sudo "to add your Nix volume's password to Keychain" \
        /usr/bin/security -i <<EOF
add-generic-password -a "$NIX_VOLUME_LABEL" -s "$new_uuid" -l "$NIX_VOLUME_LABEL encryption password" -D "Encrypted volume password" -j "Added automatically by the Nix installer for use by $NIX_VOLUME_MOUNTD_DEST" -w "$password" -T /System/Library/CoreServices/APFSUserAgent -T /System/Library/CoreServices/CSUserAgent -T /usr/bin/security "/Library/Keychains/System.keychain"
EOF
        builtin printf "%s" "$password" | _sudo "to encrypt your Nix volume" \
            /usr/sbin/diskutil apfs encryptVolume "$NIX_VOLUME_LABEL" -user disk -stdinpassphrase
    fi
}

setup_volume_daemon() {
    if ! test_voldaemon; then
        echo "Configuring LaunchDaemon to mount '$NIX_VOLUME_LABEL'..." >&2
        # generate_mount_daemon > "$SCRATCH/mount_daemon"

        # _sudo "to install the Nix volume mounter" \
        #     cp "$SCRATCH/mount_daemon" "$NIX_VOLUME_MOUNTD_DEST"
        generate_mount_daemon | _sudo "to install the Nix volume mounter" \
            dd of="$NIX_VOLUME_MOUNTD_DEST" 2>/dev/null

        _sudo "to launch the Nix volume mounter" \
            /bin/launchctl bootstrap system "$NIX_VOLUME_MOUNTD_DEST"
    fi
}

setup_darwin_volume() {
    setup_synthetic_conf
    setup_fstab
    setup_volume
    setup_volume_daemon
}

if [ "$_CREATE_VOLUME_NO_MAIN" = 1 ]; then
    # shellcheck disable=SC2198
    if [ -n "$@" ]; then
        "$@" # expose functions in case we want multiple routines?
    fi
else
    # no reason to pay for bash to process this
    main() {
        # TODO: refactor me

        {
            echo ""
            echo "     ------------------------------------------------------------------ "
            echo "    | This installer will create a volume for the nix store and        |"
            echo "    | configure it to mount at /nix.  Follow these steps to uninstall. |"
            echo "     ------------------------------------------------------------------ "
            echo ""
            echo "  1. Remove the entry from fstab using 'sudo vifs'"
            echo "  2. Run 'sudo launchctl bootout system/org.nixos.darwin-store'"
            echo "  3. Remove $NIX_VOLUME_MOUNTD_DEST"
            echo "  4. Destroy the data volume using 'diskutil apfs deleteVolume'"
            echo "  5. Remove the 'nix' line from /etc/synthetic.conf (or the file)"
            echo ""
        } >&2

        if test_nix_symlink; then
            echo "error: /nix is a symlink, please remove it and make sure it's not in synthetic.conf (in which case a reboot is required)" >&2
            echo "  /nix -> $(readlink "/nix")" >&2
            exit 2
        fi

        setup_darwin_volume
    }

    main "$@"
fi
