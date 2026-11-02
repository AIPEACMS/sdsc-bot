#!/usr/bin/env bash
# Written in [Amber](https://amber-lang.com/)
# version: 0.6.0-alpha
# setting(name: Text, fallback: Text)
setting__0_v0() {
    local name_6="${1}"
    local fallback_7="${2}"
    local command_0
    command_0="$(printenv "${name_6}")"
    __status=$?
    if [ "${__status}" != 0 ]; then
        ret_setting0_v0="${fallback_7}"
        return 0
    fi
    local value_8="${command_0}"
    if [ "$([ "_${value_8}" != "_" ]; echo $?)" != 0 ]; then
        ret_setting0_v0="${fallback_7}"
        return 0
    fi
    ret_setting0_v0="${value_8}"
    return 0
}

# rollback(install: Text, previous: Text, service: Text)
rollback__1_v0() {
    local install_21="${1}"
    local previous_22="${2}"
    local service_23="${3}"
    rm -r -- "${install_21}"
    __status=$?
    if [ "${__status}" != 0 ]; then
        ret_rollback1_v0="${__status}"
        return 0
    fi
    mv -- "${previous_22}" "${install_21}"
    __status=$?
    if [ "${__status}" != 0 ]; then
        ret_rollback1_v0="${__status}"
        return 0
    fi
    systemctl --user restart "${service_23}"
    __status=$?
    code_24="${__status}"
        ret_rollback1_v0="${code_24}"
        return 0
}

typeset -r args_0=("$0" "$@")
__length_2=("${args_0[@]}")
if [ "$(( ${#__length_2[@]} != 2 ))" != 0 ]; then
    echo "usage: deploy.sh /path/to/package.tar.gz"
    exit 2
fi
command_3="$(realpath -e -- "${args_0[1]?"Index out of bounds (at tool/deploy_local.ab:18:45)"}")"
__status=$?
if [ "${__status}" != 0 ]; then
    exit "${__status}"
fi
package_1="${command_3}"
command_4="$(printenv HOME)"
__status=$?
if [ "${__status}" != 0 ]; then
    exit "${__status}"
fi
home_2="${command_4}"
setting__0_v0 "SDSC_INSTALL_DIR" "${home_2}/app"
install_9="${ret_setting0_v0}"
setting__0_v0 "SDSC_SERVICE" "sdsc-bot.service"
service_10="${ret_setting0_v0}"
command_5="$(id -u)"
__status=$?
if [ "${__status}" != 0 ]; then
    exit "${__status}"
fi
uid_11="${command_5}"
setting__0_v0 "XDG_RUNTIME_DIR" "/run/user/${uid_11}"
runtime_12="${ret_setting0_v0}"
setting__0_v0 "DBUS_SESSION_BUS_ADDRESS" "unix:path=${runtime_12}/bus"
bus_13="${ret_setting0_v0}"
export XDG_RUNTIME_DIR="${runtime_12}" DBUS_SESSION_BUS_ADDRESS="${bus_13}"
__status=$?
if [ "${__status}" != 0 ]; then
    exit "${__status}"
fi
test -d "${install_9}" && test -O "${install_9}"
__status=$?
if [ "${__status}" != 0 ]; then
    echo "Run as the account that owns the existing installation."
    exit 1
fi
systemctl --user show "${service_10}" --property=LoadState --value | grep -qx loaded
__status=$?
if [ "${__status}" != 0 ]; then
    echo "The local user service is not installed."
    exit 1
fi
command_6="$(mktemp -d "${install_9}.stage.XXXXXX")"
__status=$?
if [ "${__status}" != 0 ]; then
    exit "${__status}"
fi
stage_14="${command_6}"
trap 'test ! -d "'"${stage_14}"'" || rm -r -- "'"${stage_14}"'"' EXIT
__status=$?
if [ "${__status}" != 0 ]; then
    exit "${__status}"
fi
tar --no-same-owner -xzf "${package_1}" -C "${stage_14}"
__status=$?
if [ "${__status}" != 0 ]; then
    exit "${__status}"
fi
test -x "${stage_14}/bin/main"
__status=$?
if [ "${__status}" != 0 ]; then
    echo "Package has no executable bin/main."
    exit 1
fi
previous_15="${install_9}.previous"
test ! -e "${previous_15}"
__status=$?
if [ "${__status}" != 0 ]; then
    rm -r -- "${previous_15}"
    __status=$?
    if [ "${__status}" != 0 ]; then
        exit "${__status}"
    fi
fi
mv -- "${install_9}" "${previous_15}"
__status=$?
if [ "${__status}" != 0 ]; then
    exit "${__status}"
fi
mv -- "${stage_14}" "${install_9}"
__status=$?
if [ "${__status}" != 0 ]; then
    mv -- "${previous_15}" "${install_9}"
    __status=$?
    if [ "${__status}" != 0 ]; then
        exit "${__status}"
    fi
    exit 1
fi
healthy_16=1
systemctl --user restart "${service_10}"
__status=$?
if [ "${__status}" != 0 ]; then
    healthy_16=0
fi
if [ "${healthy_16}" != 0 ]; then
    systemctl --user is-active --quiet "${service_10}"
    __status=$?
    if [ "${__status}" != 0 ]; then
        healthy_16=0
    fi
fi
if [ "$(( ! healthy_16 ))" != 0 ]; then
    rollback__1_v0 "${install_9}" "${previous_15}" "${service_10}"
    restored_25="${ret_rollback1_v0}"
    if [ "$(( restored_25 != 0 ))" != 0 ]; then
        echo "Rollback failed; check the local user service."
    fi
    exit 1
fi
rm -r -- "${previous_15}"
__status=$?
if [ "${__status}" != 0 ]; then
    exit "${__status}"
fi
echo "Local deployment complete."
