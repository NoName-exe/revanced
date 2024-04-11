#!/usr/bin/env bash

MODULE_TEMPLATE_DIR="revanced-magisk"
TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"

if [ "${GITHUB_TOKEN-}" ]; then GH_HEADER="Authorization: token ${GITHUB_TOKEN}"; else GH_HEADER=; fi
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
REBUILD=${REBUILD:-false}
OS=$(uname -o)

# -------------------- json/toml --------------------
toml_prep() { __TOML__=$(tr -d '\t\r' <<<"$1" | tr "'" '"' | grep -o '^[^#]*' | grep -v '^$' | sed -r 's/(\".*\")|\s*/\1/g; 1i []'); }
toml_get_table_names() {
	local tn
	tn=$(grep -x '\[.*\]' <<<"$__TOML__" | tr -d '[]') || return 1
	if [ "$(sort <<<"$tn" | uniq -u | wc -l)" != "$(wc -l <<<"$tn")" ]; then
		abort "ERROR: Duplicate tables in TOML"
	fi
	echo "$tn"
}
toml_get_table() { sed -n "/\[${1}]/,/^\[.*]$/p" <<<"$__TOML__" | sed '${/^\[/d;}'; }
toml_get() {
	local table=$1 key=$2 val
	val=$(grep -m 1 "^${key}=" <<<"$table") && sed -e "s/^\"//; s/\"$//" <<<"${val#*=}"
}
# ---------------------------------------------------

pr() { echo -e "\033[0;32m[+] ${1}\033[0m"; }
epr() {
	echo >&2 -e "\033[0;31m[-] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo -e "::error::utils.sh [-] ${1}\n"; fi
}
abort() {
	epr "ABORT: ${1-}"
	exit 1
}

get_rv_prebuilts() {
	local cli_src=$1 cli_ver=$2 integrations_src=$3 integrations_ver=$4 patches_src=$5 patches_ver=$6
	pr "Getting prebuilts (${patches_src%/*})" >&2
	for f in "${TEMP_DIR}"/*-rv; do : >"${f}/changelog.md"; done
	for src_ver in "$cli_src CLI $cli_ver" "$integrations_src Integrations $integrations_ver" "$patches_src Patches $patches_ver"; do
		set -- $src_ver
		local src=$1 tag=$2 ver=${3-} ext
		if [ "$tag" = "CLI" ] || [ "$tag" = "Patches" ]; then
			ext="jar"
		elif [ "$tag" = "Integrations" ]; then
			ext="apk"
		else abort unreachable; fi
		local dir=${src%/*}
		dir=${TEMP_DIR}/${dir,,}-rv
		[ -d "$dir" ] || mkdir "$dir"

		local rv_rel="https://api.github.com/repos/${src}/releases/"
		if [ "$ver" ]; then rv_rel+="tags/${ver}"; else rv_rel+="latest"; fi

		local resp asset url name file
		resp=$(gh_req "$rv_rel" -) || return 1
		asset=$(jq -e -r ".assets[] | select(.name | endswith(\"$ext\"))" <<<"$resp") || return 1
		url=$(jq -r .url <<<"$asset")
		name=$(jq -r .name <<<"$asset")
		file="${dir}/${name}"
		[ -f "$file" ] || REBUILD=true

		echo "$tag: $(cut -d/ -f5 <<<"$url")/${name}  " >>"$dir/changelog.md"
		gh_dl "$file" "$url" >&2 || return 1
		echo -n "$file "
		if [ "$tag" = "Patches" ]; then
			local tag_name
			tag_name=$(jq -r '.tag_name' <<<"$resp")
			name="patches-${tag_name}.json"
			file="${dir}/${name}"
			url=$(jq -e -r '.assets[] | select(.name | endswith("json")) | .url' <<<"$resp") || return 1
			gh_dl "$file" "$url" >&2 || return 1
			echo -n "$file "
			echo -e "[Changelog](https://github.com/${src}/releases/tag/${tag_name})\n" >>"$dir/changelog.md"
		fi
	done
	echo
}

get_prebuilts() {
	APKSIGNER="${BIN_DIR}/apksigner.jar"
	if [ "$OS" = Android ]; then
		local arch
		if [ "$(uname -m)" = aarch64 ]; then arch=arm64; else arch=arm; fi
		HTMLQ="${BIN_DIR}/htmlq/htmlq-${arch}"
		AAPT2="${BIN_DIR}/aapt2/aapt2-${arch}"
	else
		HTMLQ="${BIN_DIR}/htmlq/htmlq-x86_64"
	fi
	mkdir -p ${MODULE_TEMPLATE_DIR}/bin/arm64 ${MODULE_TEMPLATE_DIR}/bin/arm ${MODULE_TEMPLATE_DIR}/bin/x86 ${MODULE_TEMPLATE_DIR}/bin/x64
	gh_dl "${MODULE_TEMPLATE_DIR}/bin/arm64/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-arm64-v8a"
	gh_dl "${MODULE_TEMPLATE_DIR}/bin/arm/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-armeabi-v7a"
	gh_dl "${MODULE_TEMPLATE_DIR}/bin/x86/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-x86"
	gh_dl "${MODULE_TEMPLATE_DIR}/bin/x64/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-x86_64"
}

config_update() {
	declare -A sources
	: >$TEMP_DIR/skipped
	local conf=""
	# shellcheck disable=SC2154
	conf+=$(sed '1d' <<<"$main_config_t")
	conf+=$'\n'
	local prcfg=false
	for table_name in $(toml_get_table_names); do
		if [ -z "$table_name" ]; then continue; fi
		t=$(toml_get_table "$table_name")
		enabled=$(toml_get "$t" enabled) || enabled=true
		if [ "$enabled" = false ]; then continue; fi
		PATCHES_SRC=$(toml_get "$t" patches-source) || PATCHES_SRC=$DEF_PATCHES_SRC
		if [[ -v sources[$PATCHES_SRC] ]]; then
			if [ "${sources[$PATCHES_SRC]}" = 1 ]; then
				conf+="$t"
				conf+=$'\n'
			fi
		else
			sources[$PATCHES_SRC]=0
			if ! last_patches_url=$(gh_req "https://api.github.com/repos/${PATCHES_SRC}/releases/latest" - \
				| jq -e -r '.assets[] | select(.name | endswith("jar")) | .name'); then
				abort oops
			fi
			last_patches=${last_patches_url##*/}
			cur_patches=$(sed -n "s/.*Patches: ${PATCHES_SRC%%/*}\/\(.*\)/\1/p" build.md | xargs)
			if [ "$cur_patches" ] && [ "$last_patches" ]; then
				if [ "${cur_patches}" != "$last_patches" ]; then
					sources[$PATCHES_SRC]=1
					prcfg=true
					conf+="$t"
					conf+=$'\n'
				else
					echo "Patches: ${PATCHES_SRC%%/*}/${cur_patches}  " >>$TEMP_DIR/skipped
				fi
			fi
		fi
	done
	if [ "$prcfg" = true ]; then echo "$conf"; fi
}

_req() {
	local ip="$1" op="$2"
	shift 2
	if [ "$op" = - ]; then
		wget -nv -O "$op" "$@" "$ip"
	else
		local dlp
		dlp="$(dirname "$op")/tmp.$(basename "$op")"
		if [ -f "$dlp" ]; then
			while [ -f "$dlp" ]; do sleep 1; done
			return
		fi
		wget -nv -O "$dlp" "$@" "$ip" || return 1
		mv -f "$dlp" "$op"
	fi
}
req() { _req "$1" "$2" --header="User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0"; }
gh_req() { _req "$1" "$2" --header="$GH_HEADER"; }
gh_dl() {
	if [ ! -f "$1" ]; then
		pr "Getting '$1' from '$2'"
		_req "$2" "$1" --header="$GH_HEADER" --header="Accept: application/octet-stream"
	fi
}

log() { echo -e "$1  " >>"build.md"; }
get_largest_ver() {
	local vers m
	vers=$(tee)
	m=$(head -1 <<<"$vers")
	if ! semver_validate "$m"; then echo "$m"; else sort -rV <<<"$vers" | head -1; fi
}
semver_validate() {
	local a="${1%-*}"
	local ac="${a//[.0-9]/}"
	[ ${#ac} = 0 ]
}
get_patch_last_supported_ver() {
	local inc_sel exc_sel vs
	inc_sel=$(list_args "$2" | sed 's/.*/\.name == &/' | paste -sd '~' | sed 's/~/ or /g' || :)
	exc_sel=$(list_args "$3" | sed 's/.*/\.name != &/' | paste -sd '~' | sed 's/~/ and /g' || :)
	inc_sel=${inc_sel:-false}
	if [ "$4" = false ]; then inc_sel="${inc_sel} or .use==true"; fi
	if ! vs=$(jq -e -r ".[]
			| select(.compatiblePackages // [] | .[] | .name==\"${1}\")
			| select(${inc_sel})
			| select(${exc_sel:-true})
			| .compatiblePackages[].versions // []" "$5"); then
		abort "error in jq query"
	fi
	tr -d ' ,\t[]"' <<<"$vs" | sort -u | grep -v '^$' | get_largest_ver || :
}

isoneof() {
	local i=$1 v
	shift
	for v; do [ "$v" = "$i" ] && return 0; done
	return 1
}

# -------------------- apkmirror --------------------
dl_apkmirror() {
	local url=$1 version=${2// /-} output=$3 arch=$4 dpi=$5 apkorbundle=APK
	if [ "$arch" = "arm-v7a" ]; then arch="armeabi-v7a"; fi
	local apparch resp node app_table dlurl=""
	if [ "$arch" = all ]; then
		apparch=(universal noarch 'arm64-v8a + armeabi-v7a')
	else apparch=("$arch" universal noarch 'arm64-v8a + armeabi-v7a'); fi
	url="${url}/${url##*/}-${version//./-}-release/"
	resp=$(req "$url" -) || return 1
	node=$($HTMLQ "div.table-row.headerFont:nth-last-child(1)" -r "span:nth-child(n+3)" <<<"$resp")
	if [ "$node" ]; then
		for ((n = 1; n < 40; n++)); do
			node=$($HTMLQ "div.table-row.headerFont:nth-last-child($n)" -r "span:nth-child(n+3)" <<<"$resp")
			if [ -z "$node" ]; then break; fi
			app_table=$($HTMLQ --text --ignore-whitespace <<<"$node")
			if [ "$(sed -n 3p <<<"$app_table")" = "$apkorbundle" ] && { [ "$apkorbundle" = BUNDLE ] \
				|| { [ "$apkorbundle" = APK ] && [ "$(sed -n 6p <<<"$app_table")" = "$dpi" ] \
					&& isoneof "$(sed -n 4p <<<"$app_table")" "${apparch[@]}"; }; }; then
				dlurl=$($HTMLQ --base https://www.apkmirror.com --attribute href "div:nth-child(1) > a:nth-child(1)" <<<"$node")
				break
			fi
		done
		[ -z "$dlurl" ] && return 1
		resp=$(req "$dlurl" -)
	fi
	url=$(echo "$resp" | $HTMLQ --base https://www.apkmirror.com --attribute href "a.btn") || return 1
	if [ "$apkorbundle" = BUNDLE ] && [[ $url != *"&forcebaseapk=true" ]]; then url="${url}&forcebaseapk=true"; fi
	url=$(req "$url" - | $HTMLQ --base https://www.apkmirror.com --attribute href "span > a[rel = nofollow]") || return 1
	req "$url" "$output"
}
get_apkmirror_vers() {
	local vers apkm_resp
	apkm_resp=$(req "https://www.apkmirror.com/uploads/?appcategory=${__APKMIRROR_CAT__}" -)
	vers=$(sed -n 's;.*Version:</span><span class="infoSlide-value">\(.*\) </span>.*;\1;p' <<<"$apkm_resp")
	if [ "$__AAV__" = false ]; then
		local IFS=$'\n'
		vers=$(grep -iv "\(beta\|alpha\)" <<<"$vers")
		local v r_vers=()
		for v in $vers; do
			grep -iq "${v} \(beta\|alpha\)" <<<"$apkm_resp" || r_vers+=("$v")
		done
		echo "${r_vers[*]}"
	else
		echo "$vers"
	fi
}
get_apkmirror_pkg_name() { sed -n 's;.*id=\(.*\)" class="accent_color.*;\1;p' <<<"$__APKMIRROR_RESP__"; }
get_apkmirror_resp() {
	__APKMIRROR_RESP__=$(req "${1}" -)
	__APKMIRROR_CAT__="${1##*/}"
}
# --------------------------------------------------

# -------------------- uptodown --------------------
get_uptodown_resp() {
	__UPTODOWN_RESP__=$(req "${1}/versions" -)
	__UPTODOWN_RESP_PKG__=$(req "${1}/download" -)
}
get_uptodown_vers() { $HTMLQ --text ".version" <<<"$__UPTODOWN_RESP__"; }
dl_uptodown() {
	local uptodown_dlurl=$1 version=$2 output=$3
	local url
	url=$(grep -F "${version}</span>" -B 2 <<<"$__UPTODOWN_RESP__" | head -1 | sed -n 's;.*data-url=".*download\/\(.*\)".*;\1;p') || return 1
	url="https://dw.uptodown.com/dwn/$(req "${uptodown_dlurl}/post-download/${url}" - | sed -n 's;.*class="post-download" data-url="\(.*\)".*;\1;p')" || return 1
	req "$url" "$output"
}
get_uptodown_pkg_name() { $HTMLQ --text "tr.full:nth-child(1) > td:nth-child(3)" <<<"$__UPTODOWN_RESP_PKG__"; }
# --------------------------------------------------

# -------------------- apkmonk ---------------------
get_apkmonk_resp() {
	__APKMONK_RESP__=$(req "${1}" -)
	__APKMONK_PKG_NAME__=$(awk -F/ '{print $NF}' <<<"$1")
}
get_apkmonk_vers() { grep -oP 'download_ver.+?>\K([0-9,\.]*)' <<<"$__APKMONK_RESP__"; }
dl_apkmonk() {
	local url=$1 version=$2 output=$3
	url="https://www.apkmonk.com/down_file?pkg="$(grep -F "$version</a>" <<<"$__APKMONK_RESP__" | grep -oP 'href=\"/download-app/\K.+?(?=/?\">)' | sed 's;/;\&key=;') || return 1
	url=$(req "$url" - | grep -oP 'https.+?(?=\",)') || return 1
	req "$url" "$output"
}
get_apkmonk_pkg_name() { echo "$__APKMONK_PKG_NAME__"; }
# --------------------------------------------------
dl_archive() {
	local url=$1 version=$2 output=$3 arch=$4
	local path version=${version// /}
	path=$(grep "${version_f#v}-${arch// /}" <<<"$__ARCHIVE_RESP__") || return 1
	req "${url}/${path}" "$output"
}
get_archive_resp() {
	local r
	r=$(req "$1" -)
	if [ -z "$r" ]; then return 1; else __ARCHIVE_RESP__=$(sed -n 's;^<a href="\(.*\)"[^"]*;\1;p' <<<"$r"); fi
	__ARCHIVE_PKG_NAME__=$(awk -F/ '{print $NF}' <<<"$1")
}
get_archive_vers() { sed 's/^[^-]*-//;s/-\(all\|arm64-v8a\|arm-v7a\)\.apk//g' <<<"$__ARCHIVE_RESP__"; }
get_archive_pkg_name() { echo "$__ARCHIVE_PKG_NAME__"; }
# --------------------------------------------------

patch_apk() {
	local stock_input=$1 patched_apk=$2 patcher_args=$3 rv_cli_jar=$4 rv_patches_jar=$5
	local cmd="java -jar $rv_cli_jar patch $stock_input -p -o $patched_apk -b $rv_patches_jar  $patcher_args --keystore=ks.keystore \
--keystore-entry-password=123456789 --keystore-password=123456789 --signer=jhc --keystore-entry-alias=jhc --options=options.json"
	if [ "$OS" = Android ]; then cmd+=" --custom-aapt2-binary=${AAPT2}"; fi
	pr "$cmd"
	eval "$cmd"
	[ -f "$patched_apk" ]
}

check_sig() {
	local file=$1 pkg_name=$2
	local sig
	if grep -q "$pkg_name" sig.txt; then
		sig=$(java -jar "$APKSIGNER" verify --print-certs "$file" | grep ^Signer | grep SHA-256 | tail -1 | awk '{print $NF}')
		grep -qFx "$sig $pkg_name" sig.txt
	fi
}

build_rv() {
	eval "declare -A args=${1#*=}"
	local version build_mode_arr pkg_name
	local mode_arg=${args[build_mode]} version_mode=${args[version]}
	local app_name=${args[app_name]}
	local app_name_l=${app_name,,}
	app_name_l=${app_name_l// /-}
	local table=${args[table]}
	local dl_from=${args[dl_from]}
	local arch=${args[arch]}
	local arch_f="${arch// /}"

	local p_patcher_args=()
	p_patcher_args+=("$(join_args "${args[excluded_patches]}" -e) $(join_args "${args[included_patches]}" -i)")
	[ "${args[exclusive_patches]}" = true ] && p_patcher_args+=("--exclusive")

	for dl_p in archive apkmirror uptodown apkmonk; do
		if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
		if ! get_"${dl_p}"_resp "${args[${dl_p}_dlurl]}" || ! pkg_name=$(get_"${dl_p}"_pkg_name); then
			args[${dl_p}_dlurl]=""
			epr "ERROR: Could not find ${table} in ${dl_p}"
			continue
		fi
		dl_from=$dl_p
		break
	done
	if [ -z "$pkg_name" ]; then
		epr "empty pkg name, not building ${table}."
		return 0
	fi
	local get_latest_ver=false
	if [ "$version_mode" = auto ]; then
		if ! version=$(get_patch_last_supported_ver "$pkg_name" \
			"${args[included_patches]}" "${args[excluded_patches]}" "${args[exclusive_patches]}" "${args[ptjs]}"); then
			exit 1
		elif [ -z "$version" ]; then get_latest_ver=true; fi
	elif isoneof "$version_mode" latest beta; then
		get_latest_ver=true
		p_patcher_args+=("-f")
	else
		version=$version_mode
		p_patcher_args+=("-f")
	fi
	if [ $get_latest_ver = true ]; then
		if [ "$version_mode" = beta ]; then __AAV__="true"; else __AAV__="false"; fi
		pkgvers=$(get_"${dl_from}"_vers)
		version=$(get_largest_ver <<<"$pkgvers") || version=$(head -1 <<<"$pkgvers")
	fi
	if [ -z "$version" ]; then
		epr "empty version, not building ${table}."
		return 0
	fi
	pr "Choosing version '${version}' for ${table}"
	local version_f=${version// /}
	version_f=${version_f#v}
	local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"
	if [ ! -f "$stock_apk" ]; then
		for dl_p in archive apkmirror uptodown apkmonk; do
			if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
			pr "Downloading '${table}' from ${dl_p}"
			if ! dl_${dl_p} "${args[${dl_p}_dlurl]}" "$version" "$stock_apk" "$arch" "${args[dpi]}"; then
				epr "ERROR: Could not download '${table}' from ${dl_p} with version '${version}', arch '${arch}', dpi '${args[dpi]}'"
				continue
			fi
			break
		done
		if [ ! -f "$stock_apk" ]; then return 0; fi
	fi
	if ! check_sig "$stock_apk" "$pkg_name"; then
		abort "apk signature mismatch '$stock_apk'"
	fi
	log "${table}: ${version}"

	p_patcher_args+=("-m ${args[integ]}")
	local microg_patch
	microg_patch=$(jq -r ".[] | select(.compatiblePackages // [] | .[] | .name==\"${pkg_name}\") | .name" "${args[ptjs]}" | grep -i "gmscore\|microg" || :)
	if [ -n "$microg_patch" ] && [[ ${p_patcher_args[*]} =~ $microg_patch ]]; then
		epr "You cant include/exclude microg patches as that's done by rvmm builder automatically."
		p_patcher_args=("${p_patcher_args[@]//-[ei] ${microg_patch}/}")
	fi

	if [ "$mode_arg" = module ]; then
		build_mode_arr=(module)
	elif [ "$mode_arg" = apk ]; then
		build_mode_arr=(apk)
	elif [ "$mode_arg" = both ]; then
		build_mode_arr=(apk module)
	fi
	local patcher_args patched_apk build_mode
	local rv_brand_f=${args[rv_brand],,}
	rv_brand_f=${rv_brand_f// /-}
	for build_mode in "${build_mode_arr[@]}"; do
		patcher_args=("${p_patcher_args[@]}")
		pr "Building '${table}' in '$build_mode' mode"
		if [ -n "$microg_patch" ]; then
			patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}-${build_mode}.apk"
			if [ "$build_mode" = apk ]; then
				patcher_args+=("-i \"${microg_patch}\"")
			elif [ "$build_mode" = module ]; then
				patcher_args+=("-e \"${microg_patch}\"")
			fi
		else
			patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}.apk"
		fi
		if [ "${args[riplib]}" = true ]; then
			patcher_args+=("--rip-lib x86_64 --rip-lib x86")
			if [ "$build_mode" = module ]; then
				patcher_args+=("--rip-lib arm64-v8a --rip-lib armeabi-v7a --unsigned")
			else
				if [ "$arch" = "arm64-v8a" ]; then
					patcher_args+=("--rip-lib armeabi-v7a")
				elif [ "$arch" = "arm-v7a" ]; then
					patcher_args+=("--rip-lib arm64-v8a")
				fi

			fi
		fi
		if [ ! -f "$patched_apk" ] || [ "$REBUILD" = true ]; then
			if ! patch_apk "$stock_apk" "$patched_apk" "${patcher_args[*]}" "${args[cli]}" "${args[ptjar]}"; then
				epr "Building '${table}' failed!"
				return 0
			fi
		fi
		if [ "$build_mode" = apk ]; then
			local apk_output="${BUILD_DIR}/${app_name_l}-${rv_brand_f}-v${version_f}-${arch_f}.apk"
			cp -f "$patched_apk" "$apk_output"
			pr "Built ${table} (non-root): '${apk_output}'"
			continue
		fi
		local base_template
		base_template=$(mktemp -d -p $TEMP_DIR)
		cp -a $MODULE_TEMPLATE_DIR/. "$base_template"
		local upj="${table,,}-update.json"

		module_config "$base_template" "$pkg_name" "$version" "$arch"
		module_prop \
			"${args[module_prop_name]}" \
			"${app_name} ${args[rv_brand]}" \
			"$version" \
			"${app_name} ${args[rv_brand]} Magisk Module" \
			"https://raw.githubusercontent.com/${GITHUB_REPOSITORY-}/update/${upj}" \
			"$base_template"

		local module_output="${app_name_l}-${rv_brand_f}-magisk-v${version_f}-${arch_f}.zip"
		if [ ! -f "$module_output" ] || [ "$REBUILD" = true ]; then
			pr "Packing module ${table}"
			cp -f "$patched_apk" "${base_template}/base.apk"
			if [ "${args[include_stock]}" = true ]; then cp -f "$stock_apk" "${base_template}/${pkg_name}.apk"; fi
			pushd >/dev/null "$base_template" || abort "Module template dir not found"
			zip -"$COMPRESSION_LEVEL" -FSqr "../../${BUILD_DIR}/${module_output}" .
			popd >/dev/null || :
		fi
		pr "Built ${table} (root): '${BUILD_DIR}/${module_output}'"
	done
}

list_args() { tr -d '\t\r' <<<"$1" | tr -s ' ' | sed 's/" "/"\n"/g' | sed 's/\([^"]\)"\([^"]\)/\1'\''\2/g' | grep -v '^$' || :; }
join_args() { list_args "$1" | sed "s/^/${2} /" | paste -sd " " - || :; }

module_config() {
	local ma=""
	if [ "$4" = "arm64-v8a" ]; then
		ma="arm64"
	elif [ "$4" = "arm-v7a" ]; then
		ma="arm"
	fi
	echo "PKG_NAME=$2
PKG_VER=$3
MODULE_ARCH=$ma" >"$1/config"
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
