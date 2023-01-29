#!/system/bin/sh
# shellcheck disable=SC2086
MODDIR=${0%/*}
RVPATH=/data/adb/rvhc/__PKGNAME_rv.apk
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 1; done
timeout 15 logcat -T1 -m1 -e HOME ActivityManager:I

err() {
	cp -n $MODDIR/module.prop $MODDIR/err
	sed -i "s/^des.*/description=⚠️ Module is inactive: ${1}/g" $MODDIR/module.prop
}

BASEPATH=$(pm path __PKGNAME | grep base)
BASEPATH=${BASEPATH#*:}
if [ $BASEPATH ] && [ -d ${BASEPATH%base.apk}lib ]; then
	VERSION=$(dumpsys package __PKGNAME | grep -m1 versionName)
	if [ ${VERSION#*=} = __PKGVER ]; then
		grep __PKGNAME /proc/mounts | while read -r line; do
			mp=${line#* }
			mp=${mp%% *}
			umount -l ${mp%%\\*}
		done
		if chcon u:object_r:apk_data_file:s0 $RVPATH; then
			mount -o bind $RVPATH $BASEPATH
			am force-stop __PKGNAME
			mv -f $MODDIR/err $MODDIR/module.prop 2>/dev/null
		else
			err "APK was not found"
		fi
	else
		err "Version mismatch (${VERSION#*=})"
	fi
else
	err "Invalid installation"
fi
