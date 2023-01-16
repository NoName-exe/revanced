#!/usr/bin/env bash

MODULE_TEMPLATE_DIR="revanced-magisk"
MODULE_SCRIPTS_DIR="scripts"
TEMP_DIR="temp"
BUILD_DIR="build"
PKGS_LIST="${TEMP_DIR}/module-pkgs"

if [ "${GITHUB_TOKEN+x}" ]; then
	GH_AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"
else
	GH_AUTH_HEADER=""
fi
GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-"NoName-exe/revanced"}
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
WGET_HEADER="User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0"
DRYRUN=false

SERVICE_SH=$(cat $MODULE_SCRIPTS_DIR/service.sh)
CUSTOMIZE_SH=$(cat $MODULE_SCRIPTS_DIR/customize.sh)
UNINSTALL_SH=$(cat $MODULE_SCRIPTS_DIR/uninstall.sh)

# -------------------- json/toml --------------------
json_get() { grep -o "\"${1}\":[^\"]*\"[^\"]*\"" | sed -E 's/".*".*"(.*)"/\1/'; }
toml_prep() { __TOML__=$(echo "$1" | tr -d '\t\r' | tr "'" '"' | grep -o '^[^#]*' | grep -v '^$' | sed -r 's/(\".*\")|\s*/\1/g; 1i []'); }
toml_get_table_names() {
	local tn
	tn=$(echo "$__TOML__" | grep -x '\[.*\]' | tr -d '[]') || return 1
	if [ "$(echo "$tn" | sort | uniq -u | wc -l)" != "$(echo "$tn" | wc -l)" ]; then
		echo >&2 "ERROR: Duplicate tables in TOML"
		return 1
	fi
	echo "$tn"
}
toml_get_table() { sed -n "/\[${1}]/,/^\[.*]$/p" <<<"$__TOML__"; }
toml_get() {
	local table=$1 key=$2 val
	val=$(grep -m 1 "^${key}=" <<<"$table") && echo "${val#*=}" | sed -e "s/^\"//; s/\"$//"
}
# ---------------------------------------------------

get_prebuilts() {
	echo "Getting prebuilts"
	local rv_cli_url rv_integrations_url rv_patches rv_patches_changelog rv_patches_dl rv_patches_url
	rv_cli_url=$(gh_req https://api.github.com/repos/j-hc/revanced-cli/releases/latest - | json_get 'browser_download_url')
	RV_CLI_JAR="${TEMP_DIR}/${rv_cli_url##*/}"
	log "CLI: ${rv_cli_url##*/}"

	rv_integrations_url=$(gh_req https://api.github.com/repos/revanced/revanced-integrations/releases/latest - | json_get 'browser_download_url')
	RV_INTEGRATIONS_APK="${TEMP_DIR}/${rv_integrations_url##*/}"
	log "Integrations: ${rv_integrations_url##*/}"

	rv_patches=$(gh_req https://api.github.com/repos/revanced/revanced-patches/releases/latest -)
	rv_patches_changelog=$(echo "$rv_patches" | json_get 'body' | sed 's/\(\\n\)\+/\\n/g')
	rv_patches_dl=$(json_get 'browser_download_url' <<<"$rv_patches")
	RV_PATCHES_JSON="${TEMP_DIR}/patches-$(json_get 'tag_name' <<<"$rv_patches").json"
	rv_patches_url=$(grep 'jar' <<<"$rv_patches_dl")
	RV_PATCHES_JAR="${TEMP_DIR}/${rv_patches_url##*/}"
	log "Patches: ${rv_patches_url##*/}"
	log "\n${rv_patches_changelog//# [/### [}\n"

	dl_if_dne "$RV_CLI_JAR" "$rv_cli_url"
	dl_if_dne "$RV_INTEGRATIONS_APK" "$rv_integrations_url"
	dl_if_dne "$RV_PATCHES_JAR" "$rv_patches_url"
	dl_if_dne "$RV_PATCHES_JSON" "$(grep 'json' <<<"$rv_patches_dl")"
}

get_cmpr() {
	mkdir -p revanced-magisk/bin/arm64 revanced-magisk/bin/arm
	dl_if_dne "${MODULE_TEMPLATE_DIR}/bin/arm64/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-arm64-v8a"
	dl_if_dne "${MODULE_TEMPLATE_DIR}/bin/arm/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-armeabi-v7a"
}

abort() { echo "abort: $1" && exit 1; }

set_prebuilts() {
	[ -d "$TEMP_DIR" ] || abort "${TEMP_DIR} directory could not be found"
	RV_CLI_JAR=$(find "$TEMP_DIR" -maxdepth 1 -name "revanced-cli-*.jar" | tail -n1)
	[ "$RV_CLI_JAR" ] || abort "revanced cli not found"
	log "CLI: ${RV_CLI_JAR#"$TEMP_DIR/"}"
	RV_INTEGRATIONS_APK=$(find "$TEMP_DIR" -maxdepth 1 -name "revanced-integrations-*.apk" | tail -n1)
	[ "$RV_INTEGRATIONS_APK" ] || abort "revanced integrations not found"
	log "Integrations: ${RV_INTEGRATIONS_APK#"$TEMP_DIR/"}"
	RV_PATCHES_JAR=$(find "$TEMP_DIR" -maxdepth 1 -name "revanced-patches-*.jar" | tail -n1)
	[ "$RV_PATCHES_JAR" ] || abort "revanced patches not found"
	log "Patches: ${RV_PATCHES_JAR#"$TEMP_DIR/"}"
	RV_PATCHES_JSON=$(find "$TEMP_DIR" -maxdepth 1 -name "patches-*.json" | tail -n1)
	[ "$RV_PATCHES_JSON" ] || abort "patches.json not found"
}

req() { wget -nv -O "$2" --header="$WGET_HEADER" "$1"; }
gh_req() { wget -nv -O "$2" --header="$GH_AUTH_HEADER" "$1"; }
log() { echo -e "$1  " >>build.md; }
get_largest_ver() {
	read -r max
	while read -r v; do
		if ! semver_validate "$max" "$v"; then continue; fi
		if [ "$(semver_cmp "$max" "$v")" = 1 ]; then max=$v; fi
	done
	echo "$max"
}
get_patch_last_supported_ver() {
	jq ".[] | select(.compatiblePackages[].name==\"${1}\") | .compatiblePackages[].versions" "$RV_PATCHES_JSON" | tr -d ' ,\t[]"' | sort -u | grep -v '^$' | get_largest_ver || :
}
semver_cmp() {
	IFS=. read -r -a v1 <<<"${1//[^.0-9]/}"
	IFS=. read -r -a v2 <<<"${2//[^.0-9]/}"
	local c1="${1//[^.]/}"
	local c2="${2//[^.]/}"
	local mi=$((${#c1} < ${#c2} ? ${#c1} : ${#c2}))
	for ((i = 0; i <= mi; i++)); do
		if ((v1[i] > v2[i])); then
			echo -1
			return 0
		elif ((v2[i] > v1[i])); then
			echo 1
			return 0
		fi
	done
	echo 0
}
semver_validate() {
	local a1="${1%-*}" a2="${2%-*}"
	local a1c="${a1//[.0-9]/}" a2c="${a2//[.0-9]/}"
	[ ${#a1c} = 0 ] && [ ${#a2c} = 0 ]
}

dl_if_dne() {
	if [ ! -f "$1" ]; then
		echo -e "\nGetting '$1' from '$2'"
		req "$2" "$1"
	fi
}

# -------------------- apkmirror --------------------
dl_apkmirror() {
	local url=$1 version=$2 regexp=$3 output=$4
	if [ $DRYRUN = true ]; then
		echo "#" >"$output"
		return
	fi
	local resp
	version=${version// /-}
	url="${url}/${url##*/}-${version//./-}-release/"
	resp=$(req "$url" -) || return 1
	url="https://www.apkmirror.com$(echo "$resp" | tr '\n' ' ' | sed -n "s/href=\"/@/g; s;.*${regexp}.*;\1;p")"
	[ "$url" != https://www.apkmirror.com ] || return 1
	url="https://www.apkmirror.com$(req "$url" - | tr '\n' ' ' | sed -n 's;.*href="\(.*key=[^"]*\)">.*;\1;p')"
	url="https://www.apkmirror.com$(req "$url" - | tr '\n' ' ' | sed -n 's;.*href="\(.*key=[^"]*\)">.*;\1;p')"
	req "$url" "$output"
}
get_apkmirror_vers() {
	local apkmirror_category=$1 allow_alpha_version=$2
	local vers
	apkm_resp=$(req "https://www.apkmirror.com/uploads/?appcategory=${apkmirror_category}" -)
	# apkm_name=$(echo "$apkm_resp" | sed -n 's;.*Latest \(.*\) Uploads.*;\1;p')
	vers=$(sed -n 's;.*Version:</span><span class="infoSlide-value">\(.*\) </span>.*;\1;p' <<<"$apkm_resp")
	if [ "$allow_alpha_version" = false ]; then
		local IFS=$'\n'
		vers=$(grep -i -v "\(beta\|alpha\)" <<<"$vers")
		local r_vers=()
		for v in $vers; do
			grep -iq "${v} \(beta\|alpha\)" <<<"$apkm_resp" || r_vers+=("$v")
		done
		echo "${r_vers[*]}"
	else
		echo "$vers"
	fi
}
get_apkmirror_pkg_name() { req "$1" - | sed -n 's;.*id=\(.*\)" class="accent_color.*;\1;p'; }
# --------------------------------------------------

# -------------------- uptodown --------------------
get_uptodown_resp() { req "${1}/versions" -; }
get_uptodown_vers() { echo "$1" | grep -x '^[0-9.]* <span>.*</span>' | sed 's/ <s.*//'; }
dl_uptodown() {
	local uptwod_resp=$1 version=$2 output=$3
	url=$(echo "$uptwod_resp" | grep "${version} <span>" -B 1 | head -1 | sed -n 's;.*data-url="\(.*\)".*;\1;p')
	url=$(req "$url" - | sed -n 's;.*data-url="\(.*\)".*;\1;p')
	req "$url" "$output"
}
get_uptodown_pkg_name() {
	local p
	p=$(req "${1}/download" - | grep -A 1 "Package Name" | tail -1)
	echo "${p:4:-5}"
}
# --------------------------------------------------

patch_apk() {
	local stock_input=$1 patched_apk=$2 patcher_args=$3
	declare -r tdir=$(mktemp -d -p $TEMP_DIR)
	local cmd="java -jar $RV_CLI_JAR --rip-lib x86_64 --rip-lib x86 --temp-dir=$tdir -c -a $stock_input -o $patched_apk -b $RV_PATCHES_JAR --keystore=ks.keystore $patcher_args"
	echo "$cmd"
	if [ $DRYRUN = true ]; then
		cp -f "$stock_input" "$patched_apk"
	else
		eval "$cmd"
	fi
}

zip_module() {
	local patched_apk=$1 module_name=$2 stock_apk=$3 pkg_name=$4 template_dir=$5
	cp -f "$patched_apk" "${template_dir}/base.apk"
	cp -f "$stock_apk" "${template_dir}/${pkg_name}.apk"
	pushd "$template_dir" || abort "Module template dir not found"
	zip -"$COMPRESSION_LEVEL" -FSr "../../${BUILD_DIR}/${module_name}" .
	popd || :
}

build_rv() {
	local -n args=$1
	local version patcher_args build_mode_arr pkg_name uptwod_resp
	local mode_arg=${args[build_mode]} version_mode=${args[version]}
	local app_name=${args[app_name]}
	local app_name_l=${app_name,,}
	local dl_from=${args[dl_from]}
	local arch=${args[arch]}

	if [ "$mode_arg" = module ]; then
		build_mode_arr=(module)
	elif [ "$mode_arg" = apk ]; then
		build_mode_arr=(apk)
	elif [ "$mode_arg" = both ]; then
		build_mode_arr=(apk module)
	else
		echo "ERROR: undefined build mode for '${app_name}': '${mode_arg}'"
		echo "    only 'both', 'apk' or 'module' are allowed"
		return 1
	fi

	for build_mode in "${build_mode_arr[@]}"; do
		patcher_args="${args[patcher_args]}"
		echo -n "Building '${app_name}' (${arch}) in "
		if [ "$build_mode" = module ]; then echo "'module' mode"; else echo "'APK' mode"; fi
		if [ "${args[microg_patch]}" ]; then
			if [ "$build_mode" = module ]; then
				patcher_args="$patcher_args -e ${args[microg_patch]}"
			elif [[ "${args[patcher_args]}" = *"${args[microg_patch]}"* ]]; then
				abort "UNREACHABLE $LINENO"
			fi
		fi
		if [ "$dl_from" = apkmirror ]; then
			pkg_name=$(get_apkmirror_pkg_name "${args[apkmirror_dlurl]}")
		elif [ "$dl_from" = uptodown ]; then
			uptwod_resp=$(get_uptodown_resp "${args[uptodown_dlurl]}")
			pkg_name=$(get_uptodown_pkg_name "${args[uptodown_dlurl]}")
		fi

		local get_latest_ver=false
		if [ "$version_mode" = auto ]; then
			version=$(get_patch_last_supported_ver "$pkg_name")
			if [ -z "$version" ]; then get_latest_ver=true; fi
		elif [ "$version_mode" = latest ]; then
			get_latest_ver=true
			patcher_args="$patcher_args --experimental"
		else
			version=$version_mode
			patcher_args="$patcher_args --experimental"
		fi
		if [ "$build_mode" = module ]; then
			# --unsigned and --rip-lib is only available in my revanced-cli builds
			patcher_args="$patcher_args --unsigned --rip-lib arm64-v8a --rip-lib armeabi-v7a"
		fi
		if [ $get_latest_ver = true ]; then
			local apkmvers uptwodvers
			if [ "$dl_from" = apkmirror ]; then
				apkmvers=$(get_apkmirror_vers "${args[apkmirror_dlurl]##*/}" "${args[allow_alpha_version]}")
				version=$(echo "$apkmvers" | get_largest_ver)
				[ "$version" ] || version=$(echo "$apkmvers" | head -1)
			elif [ "$dl_from" = uptodown ]; then
				uptwodvers=$(get_uptodown_vers "$uptwod_resp")
				version=$(echo "$uptwodvers" | get_largest_ver)
				[ "$version" ] || version=$(echo "$uptwodvers" | head -1)
			fi
		fi
		if [ -z "$version" ]; then
			echo "ERROR: empty version"
			return 1
		fi
		echo "Choosing version '${version}' (${app_name})"

		version=${version// /-}
		local stock_apk="${TEMP_DIR}/${pkg_name}-stock-${version}-${arch}.apk"
		local apk_output="${BUILD_DIR}/${app_name_l}-revanced-v${version}-${arch}.apk"
		if [ "${args[microg_patch]}" ]; then
			local patched_apk="${TEMP_DIR}/${app_name_l}-revanced-${version}-${arch}-${build_mode}.apk"
		else
			local patched_apk="${TEMP_DIR}/${app_name_l}-revanced-${version}-${arch}.apk"
		fi
		if [ ! -f "$stock_apk" ]; then
			if [ "$dl_from" = apkmirror ]; then
				echo "Downloading '${app_name}' from APKMirror"
				if ! dl_apkmirror "${args[apkmirror_dlurl]}" "$version" "${args[apkmirror_regex]}" "$stock_apk"; then
					echo "ERROR: Could not find any release of '${app_name}' with the given version ('${version}') and regex from APKMirror"
					return 1
				fi
			elif [ "$dl_from" = uptodown ]; then
				echo "Downloading '${app_name}' from Uptodown"
				if ! dl_uptodown "$uptwod_resp" "$version" "$stock_apk"; then
					echo "ERROR: Could not download ${app_name} from Uptodown"
					return 1
				fi
			else
				abort "UNREACHABLE $LINENO"
			fi
		fi

		if [ "${arch}" = "all" ]; then
			grep -q "${app_name}:" build.md || log "${app_name}: ${version}"
		else
			grep -q "${app_name} (${arch}):" build.md || log "${app_name} (${arch}): ${version}"
		fi

		if [ ! -f "$patched_apk" ]; then patch_apk "$stock_apk" "$patched_apk" "$patcher_args"; fi
		if [ ! -f "$patched_apk" ]; then
			echo "BUILDING '${app_name}' FAILED"
			return
		fi
		if [ "$build_mode" = apk ]; then
			cp -f "$patched_apk" "$apk_output"
			echo "Built ${app_name} (${arch}) (non-root): '${apk_output}'"
			continue
		fi
		if [ "$BUILD_MINDETACH_MODULE" = true ] && ! grep -q "$pkg_name" $PKGS_LIST; then echo "$pkg_name" >>$PKGS_LIST; fi

		declare -r base_template=$(mktemp -d -p $TEMP_DIR)
		cp -a $MODULE_TEMPLATE_DIR/. "$base_template"

		uninstall_sh "$pkg_name" "$base_template"
		service_sh "$pkg_name" "$version" "$base_template"
		customize_sh "$pkg_name" "$version" "$base_template"

		local upj
		upj=$([ "${arch}" = "all" ] && echo "${app_name_l}-update.json" || echo "${app_name_l}-${arch}-update.json")
		module_prop "${args[module_prop_name]}" \
			"${app_name} ReVanced" \
			"$version" \
			"${app_name} ReVanced Magisk Module" \
			"https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/update/${upj}" \
			"$base_template"

		local module_output="${app_name_l}-revanced-magisk-v${version}-${arch}.zip"
		zip_module "$patched_apk" "$module_output" "$stock_apk" "$pkg_name" "$base_template"

		echo "Built ${app_name} (${arch}) (root): '${BUILD_DIR}/${module_output}'"
	done
}

join_args() {
	echo "$1" | tr -d '\t\r' | tr ' ' '\n' | grep -v '^$' | sed "s/^/${2} /" | paste -sd " " - || :
}

uninstall_sh() { echo "${UNINSTALL_SH//__PKGNAME/$1}" >"${2}/uninstall.sh"; }
customize_sh() {
	local s="${CUSTOMIZE_SH//__PKGNAME/$1}"
	echo "${s//__PKGVER/$2}" >"${3}/customize.sh"
}
service_sh() {
	local s="${SERVICE_SH//__PKGNAME/$1}"
	echo "${s//__PKGVER/$2}" >"${3}/service.sh"
}
module_prop() {
	echo "id=${1}
name=${2}
version=v${3}
versionCode=${NEXT_VER_CODE}
author=NoName-exe
description=${4}" >"${6}/module.prop"

	if [ "$ENABLE_MAGISK_UPDATE" = true ]; then echo "updateJson=${5}" >>"${6}/module.prop"; fi
}
