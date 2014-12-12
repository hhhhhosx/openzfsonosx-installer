#!/bin/bash

set -e

version=1.3.1
owner=`logname`
dev_id_application="Developer ID Application: Joergen  Lundman (735AM5QEU3)"
dev_id_installer="Developer ID Installer: Joergen  Lundman (735AM5QEU3)"
keychain=`eval "echo ~${owner}"`/Library/Keychains/openzfs-login.keychain
#keychain_timeout=1200
keychain_timeout=none
should_unlock=1
should_sign_installer=1
require_version2_signature=1
zfs_kext="zfs.kext/"
spl_kext="spl.kext/"
spl_kernel_exports_kext="spl.kext/Contents/Plugins/KernelExports.kext/"
os_release_major_version=`uname -r | awk -F '.' '{print $1;}'`

if [ -z $os_release_major_version ]
then
	echo "Could not determine operating system release major version"
	exit 1
fi

if [[ $1 == *8* || $0 == *8* || $PWD == *8* ]]
then
	OS=108
else
	OS=109
fi

if [ $require_version2_signature -eq 1 -a $os_release_major_version -lt 13 -a $OS -gt 108 ]
then
	echo "It is necessary to sign code while running OS X Mavericks or higher to get a version 2 signature."
	exit 1
fi

re='^[0-9]+$'
if ! [[ ${keychain_timeout} =~ $re ]]
then
	if [ x"${keychain_timeout}" != x"none" ]
	then
		echo "The keychain timeout should be a number or \"none\"" >&2
		exit 1
	fi
fi

if [ $(id -u) -ne 0 ]
then
	set +e
	echo "" | sudo -S echo "" &>/dev/null
	ret=$?
	set -e

	if [ $ret -ne 0 ]
	then
		echo "Please enter your login password"
		read -s loginpassword
		export LP="$loginpassword"
		#die if the password doesn't work
		set +e
		echo "$LP" | sudo -S echo "" &>/dev/null
		if [ $? -ne 0 ]
		then
			echo "incorrect login password"
			exit 1
		fi
	fi
fi

if [ $should_unlock -eq 1 ]
then
	set +e
	&>/dev/null security show-keychain-info "${keychain}"
	ret=$?
	if [ $ret -ne 0 -a x"$OZP" != x ]
	then
		security unlock-keychain -p "$OZP" "${keychain}"
		ret=$?
	fi
	set -e

	if [ $ret -ne 0 ]
	then
		echo "Please enter openzfs-login.keychain's password"
			read -s openzfspassword
			export OZP="$openzfspassword"
			security unlock-keychain -p "$OZP" "${keychain}"
	fi

	if [ x"${keychain_timeout}" = x -o "${keychain_timeout}" = "none" ]
	then
		security set-keychain-settings "${keychain}"
	else
		security set-keychain-settings -t "${keychain_timeout}" "${keychain}"
	fi
fi

if [ $(id -u) -ne 0 ]
then
	if [ x"$LP" != x ]
	then
		echo "$LP" | sudo -S -E "$0" "$@"
	else
		sudo -n -E "$0" "$@"
	fi
	exit $?
fi

cd packages-o3x-${OS}

if [ $os_release_major_version -ge 13 ]
then
	productbuild_has_scripts_option=1
else
	productbuild_has_scripts_option=0
fi

if [ -e /usr/local/bin/rsync ]
then
	export RSYNC="/usr/local/bin/rsync"
	export RSYNC_OPTIONS="-rltDcAX --fileflags --itemize-changes"
else
	export RSYNC="/usr/bin/rsync"
	export RSYNC_OPTIONS="-rltDcE --itemize-changes"
fi

do_rsync() {
	"$RSYNC" $RSYNC_OPTIONS "$1" "$2"
}
if [ ${OS} -ge 109 ]
then
	pushd ${OS}/Library/Extensions &>/dev/null
	for path in "${zfs_kext}" "${spl_kernel_exports_kext}" "${spl_kext}"
	do
		set +e
		codesign -dv "${path}"
		ret=$?
		set -e
		if [ $ret -ne 0 ]
		then
			echo "Signing ${path}"
			codesign -fvs "${dev_id_application}" "${path}"
			spctl --assess --raw "${path}"
		fi
	done
	popd
fi

echo "Creating pkg"
sudo -u ${owner} packagesbuild -F . packages-o3x-${OS}.pkgproj

rm -rf conv ; mkdir conv
do_rsync build/OpenZFS\ on\ OS\ X.mpkg/Contents/ conv/

cd conv
mkdir Scripts
mv Resources/*.sh Scripts/
mv Packages/* ./
patch < ../distribution-dist-${OS}.patch

if [ ${productbuild_has_scripts_option} -eq 1 ]
then
	productbuild --version ${version} --distribution distribution.dist ../out-${OS}.pkg --resources Resources --scripts Scripts
	cd ..
else
	productbuild --version ${version} --distribution distribution.dist ../out-${OS}.pkg --resources Resources
	cd ..
	rm -rf ex-${OS}
	pkgutil --expand out-${OS}.pkg ex-${OS}
	rm out-${OS}.pkg
	mkdir ex-${OS}/Scripts
	do_rsync conv/Scripts/ ex-${OS}/Scripts/
	pkgutil --flatten ex-${OS} out-${OS}.pkg
fi

chown ${owner} out-${OS}.pkg
rm -rf ex-${OS}
sudo -u ${owner} pkgutil --expand out-${OS}.pkg ex-${OS}

rm -f ../out-${OS}.pkg
rm -f ../out-${OS}-signed.pkg

if [ ${should_sign_installer} -eq 1 ]
then
	productsign --sign "${dev_id_installer}" --keychain "${keychain}" out-${OS}.pkg out-${OS}-signed.pkg
	chown ${owner} out-${OS}-signed.pkg
	do_rsync out-${OS}-signed.pkg ../
	chown ${owner} ../out-${OS}-signed.pkg
else
	do_rsync out-${OS}.pkg ../
	chown ${owner} ../out-${OS}.pkg
fi
