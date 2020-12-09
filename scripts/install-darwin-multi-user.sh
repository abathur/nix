#!/usr/bin/env bash

set -eu
set -o pipefail

readonly NIX_DAEMON_DEST=/Library/LaunchDaemons/org.nixos.nix-daemon.plist
# create by default; set 0 to DIY, use a symlink, etc.
readonly NIX_VOLUME_CREATE=${NIX_VOLUME_CREATE:-1} # now default

# caution: may update times on / if not run as normal non-root user
read_only_root() {
    # this touch command ~should~ always produce an error for a normal
    # as of this change I confirmed /usr/bin/touch emits:
    # "touch: /: Read-only file system" Catalina+ and Big Sur
    # "touch: /: Permission denied" Mojave
    # (not matching prefix for compat w/ coreutils touch in case using
    # an explicit path causes problems; its prefix differs)
    [[ "$(/usr/bin/touch / 2>&1)" = *"Read-only file system" ]]

    # Avoiding the slow semantic way to get this information (~330ms vs ~8ms)
    # unless using touch causes problems. Just in case, that approach is:
    # diskutil info -plist / | <find the Writable or WritableVolume keys>, i.e.
    # diskutil info -plist / | xmllint --xpath "name(/plist/dict/key[text()='Writable']/following-sibling::*[1])" -
}

if read_only_root && [ "$NIX_VOLUME_CREATE" = 1 ]; then
    should_create_volume() { return 0; }
else
    should_create_volume() { return 1; }
fi

is_arm(){
    [[ "$(/usr/bin/uname -m)" =~ arm64|aarch64 ]]
}

readonly EXPECTED_ROSETTA_ARTIFACT=\
    "/Library/Apple/System/Library/LaunchDaemons/com.apple.oahd.plist"

rosetta_installed(){
    [[ -f "$EXPECTED_ROSETTA_ARTIFACT" ]]
}

install_rosetta(){
    # TODO: debate --agree-to-license;
    # I gather they'll be prompted at terminal if we don't do this
    # we could:
    # - always --agree-to-license
    # - only --agree-to-license if headless?
    # - always use --agree-to-license, but wrap it in a message and
    #   a mandatory password-prompt?
    if _sudo "to install Rosetta 2" \
        softwareupdate --install-rosetta --agree-to-license; then
        ok "successfully installed Rosetta 2 "
    else
        failure "failed to install Rosetta 2"
    fi

    local wait_increment=5
    # TODO: debate retry/resiliency measures and failure cases
    # I could also imagine doing something like
    for try in {1..3}; do
        if _sudo "to install Rosetta 2" \
            softwareupdate --install-rosetta --agree-to-license; then
            ok "successfully installed Rosetta 2 "
            break
        else
            local wait_time=((wait_increment * try))
            warning <<EOF
failed to install Rosetta 2 (attempt $try of 3)
I'll try again in $wait_time seconds.
EOF
            sleep $wait_time
        fi
    fi
}

if is_arm && ! rosetta_installed; then
    should_install_rosetta(){ return 0; }
else
    should_install_rosetta(){ return 1; }
fi

# shellcheck source=./create-darwin-volume.sh
. "$EXTRACTED_NIX_PATH/create-darwin-volume.sh" "no-main"

dsclattr() {
    /usr/bin/dscl . -read "$1" \
        | /usr/bin/awk "/$2/ { print \$2 }"
}

test_nix_daemon_installed() {
  test -e "$NIX_DAEMON_DEST"
}

poly_cure_artifacts() {
    if should_create_volume; then
        task "Fixing any leftover Nix volume state"
        cat <<EOF
Before I try to install, I'll check for any existing Nix volume config
and ask for your permission to remove it (so that the installer can
start fresh). I'll also ask for permission to fix any issues I spot.
EOF
        cure_volumes
        remove_volume_artifacts
    fi
}

poly_service_installed_check() {
    if should_create_volume; then
        test_nix_daemon_installed || test_nix_volume_mountd_installed
    else
        test_nix_daemon_installed
    fi
}

poly_service_uninstall_directions() {
    echo "$1. Remove macOS-specific components:"
    if should_create_volume && test_nix_volume_mountd_installed; then
        darwin_volume_uninstall_directions
    fi
    if test_nix_daemon_installed; then
        nix_daemon_uninstall_directions
    fi
}

poly_service_setup_note() {
    if should_create_volume; then
        echo " - create a Nix volume and a LaunchDaemon to mount it"
    fi
    echo " - create a LaunchDaemon (at $NIX_DAEMON_DEST) for nix-daemon"
    echo ""
}

poly_extra_try_me_commands() {
    :
}

poly_configure_nix_daemon_service() {
    task "Setting up the nix-daemon LaunchDaemon"
    _sudo "to set up the nix-daemon as a LaunchDaemon" \
          /bin/cp -f "/nix/var/nix/profiles/default$NIX_DAEMON_DEST" "$NIX_DAEMON_DEST"

    _sudo "to load the LaunchDaemon plist for nix-daemon" \
          launchctl load /Library/LaunchDaemons/org.nixos.nix-daemon.plist

    _sudo "to start the nix-daemon" \
          launchctl kickstart -k system/org.nixos.nix-daemon
}

poly_group_exists() {
    /usr/bin/dscl . -read "/Groups/$1" > /dev/null 2>&1
}

poly_group_id_get() {
    dsclattr "/Groups/$1" "PrimaryGroupID"
}

poly_create_build_group() {
    _sudo "Create the Nix build group, $NIX_BUILD_GROUP_NAME" \
          /usr/sbin/dseditgroup -o create \
          -r "Nix build group for nix-daemon" \
          -i "$NIX_BUILD_GROUP_ID" \
          "$NIX_BUILD_GROUP_NAME" >&2
}

poly_user_exists() {
    /usr/bin/dscl . -read "/Users/$1" > /dev/null 2>&1
}

poly_user_id_get() {
    dsclattr "/Users/$1" "UniqueID"
}

poly_user_hidden_get() {
    dsclattr "/Users/$1" "IsHidden"
}

poly_user_hidden_set() {
    _sudo "in order to make $1 a hidden user" \
          /usr/bin/dscl . -create "/Users/$1" "IsHidden" "1"
}

poly_user_home_get() {
    dsclattr "/Users/$1" "NFSHomeDirectory"
}

poly_user_home_set() {
    # This can trigger a permission prompt now:
    # "Terminal" would like to administer your computer. Administration can include modifying passwords, networking, and system settings.
    _sudo "in order to give $1 a safe home directory" \
          /usr/bin/dscl . -create "/Users/$1" "NFSHomeDirectory" "$2"
}

poly_user_note_get() {
    dsclattr "/Users/$1" "RealName"
}

poly_user_note_set() {
    _sudo "in order to give $username a useful note" \
          /usr/bin/dscl . -create "/Users/$1" "RealName" "$2"
}

poly_user_shell_get() {
    dsclattr "/Users/$1" "UserShell"
}

poly_user_shell_set() {
    _sudo "in order to give $1 a safe home directory" \
          /usr/bin/dscl . -create "/Users/$1" "UserShell" "$2"
}

poly_user_in_group_check() {
    username=$1
    group=$2
    /usr/sbin/dseditgroup -o checkmember -m "$username" "$group" > /dev/null 2>&1
}

poly_user_in_group_set() {
    username=$1
    group=$2

    _sudo "Add $username to the $group group"\
          /usr/sbin/dseditgroup -o edit -t user \
          -a "$username" "$group"
}

poly_user_primary_group_get() {
    dsclattr "/Users/$1" "PrimaryGroupID"
}

poly_user_primary_group_set() {
    _sudo "to let the nix daemon use this user for builds (this might seem redundant, but there are two concepts of group membership)" \
          /usr/bin/dscl . -create "/Users/$1" "PrimaryGroupID" "$2"
}

poly_create_build_user() {
    username=$1
    uid=$2
    builder_num=$3

    _sudo "Creating the Nix build user (#$builder_num), $username" \
          /usr/bin/dscl . create "/Users/$username" \
          UniqueID "${uid}"
}

poly_prepare_to_install() {
    if should_install_rosetta; then
        task "Installing Rosetta 2"
        # TODO: explain why?
        install_rosetta
    fi
    if should_create_volume; then
        header "Preparing a Nix volume"
        # intentional indent below to match task indent
        cat <<EOF
    Nix traditionally stores its data in the root directory $NIX_ROOT, but
    macOS now (starting in 10.15 Catalina) has a read-only root directory.
    To support Nix, I will create a volume and configure macOS to mount it
    at $NIX_ROOT.
EOF
        setup_darwin_volume
    fi
}
