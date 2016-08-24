#!/bin/bash

# called by dracut
check() {
    local _rootdev

    is_mpath() {
        local _dev=$1
        [ -e /sys/dev/block/$_dev/dm/uuid ] || return 1
        [[ $(cat /sys/dev/block/$_dev/dm/uuid) =~ mpath- ]] && return 0
        return 1
    }

    [[ $hostonly ]] || [[ $mount_needs ]] && {
        for_each_host_dev_and_slaves is_mpath || return 255
    }

    # if there's no multipath binary, no go.
    require_binaries multipath || return 1

    return 0
}

# called by dracut
depends() {
    echo rootfs-block
    echo dm
    return 0
}

# called by dracut
cmdline() {
    for m in scsi_dh_alua scsi_dh_emc scsi_dh_rdac dm_multipath; do
        if module_is_host_only $m ; then
            printf 'rd.driver.pre=%s ' "$m"
        fi
    done
}

# called by dracut
installkernel() {
    local _ret
    local _arch=$(uname -m)
    mp_mod_filter() {
        local _funcs='scsi_register_device_handler|dm_dirty_log_type_register|dm_register_path_selector|dm_register_target'
        # subfunctions inherit following FDs
        local _merge=8 _side2=9
        function bmf1() {
            local _f
            while read _f || [ -n "$_f" ]; do
                case "$_f" in
                    *.ko)    [[ $(<         $_f) =~ $_funcs ]] && echo "$_f" ;;
                    *.ko.gz) [[ $(gzip -dc <$_f) =~ $_funcs ]] && echo "$_f" ;;
                    *.ko.xz) [[ $(xz -dc   <$_f) =~ $_funcs ]] && echo "$_f" ;;
                esac
            done
            return 0
        }

        function rotor() {
            local _f1 _f2
            while read _f1 || [ -n "$_f1" ]; do
                echo "$_f1"
                if read _f2; then
                    echo "$_f2" 1>&${_side2}
                fi
            done | bmf1 1>&${_merge}
            return 0
        }
        # Use two parallel streams to filter alternating modules.
        set +x
        eval "( ( rotor ) ${_side2}>&1 | bmf1 ) ${_merge}>&1"
        [[ $debug ]] && set -x
        return 0
    }

    ( find_kernel_modules_by_path drivers/scsi; if [ "$_arch" = "s390" -o "$_arch" = "s390x" ]; then find_kernel_modules_by_path drivers/s390/scsi; fi;
      find_kernel_modules_by_path drivers/md )  |  mp_mod_filter  |  hostonly='' instmods
}

# called by dracut
install() {
    local _f
    inst_multiple -o  \
        dmsetup \
        kpartx \
        mpath_wait \
        multipath  \
        multipathd \
        mpathpersist \
        xdrgetuid \
        xdrgetprio \
        /etc/xdrdevices.conf \
        /etc/multipath.conf \
        /etc/multipath/*

    inst $(command -v partx) /sbin/partx

    inst_libdir_file "libmultipath*" "multipath/*"
    inst_libdir_file 'libgcc_s.so*'

    if [[ $hostonly_cmdline ]] ; then
        local _conf=$(cmdline)
        [[ $_conf ]] && echo "$_conf" >> "${initdir}/etc/cmdline.d/90multipath.conf"
    fi

    if dracut_module_included "systemd"; then
        inst_simple "${moddir}/multipathd.service" "${systemdsystemunitdir}/multipathd.service"
        mkdir -p "${initdir}${systemdsystemunitdir}/sysinit.target.wants"
        ln -rfs "${initdir}${systemdsystemunitdir}/multipathd.service" "${initdir}${systemdsystemunitdir}/sysinit.target.wants/multipathd.service"
    else
        inst_hook pre-trigger 02 "$moddir/multipathd.sh"
        inst_hook cleanup   02 "$moddir/multipathd-stop.sh"
    fi

    inst_hook cleanup   80 "$moddir/multipathd-needshutdown.sh"

    inst_rules 40-multipath.rules 56-multipath.rules \
	62-multipath.rules 65-multipath.rules \
	66-kpartx.rules 67-kpartx-compat.rules \
	11-dm-mpath.rules
}

