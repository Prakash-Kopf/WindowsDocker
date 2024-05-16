#!/usr/bin/env bash
set -Eeuo pipefail

handle_curl_error() {
    local error_code="$1"
    local fatal_error_action=2
    case "$error_code" in
        6)
            echo "Failed to resolve Microsoft servers! Is there an Internet connection? Exiting..."
            return "$fatal_error_action"
            ;;
        7)
            echo "Failed to contact Microsoft servers! Is there an Internet connection or is the server down?"
            ;;
        8)
            echo "Microsoft servers returned a malformed HTTP response!"
            ;;
        22)
            echo "Microsoft servers returned a failing HTTP status code!"
            ;;
        23)
            echo "Failed at writing Windows media to disk! Out of disk space or permission error? Exiting..."
            return "$fatal_error_action"
            ;;
        26)
            echo "Ran out of memory during download! Exiting..."
            return "$fatal_error_action"
            ;;
        36)
            echo "Failed to continue earlier download!"
            ;;
        63)
            echo "Microsoft servers returned an unexpectedly large response!"
            ;;
            # POSIX defines exit statuses 1-125 as usable by us
            # https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_08_02
            $((error_code <= 125)))
            # Must be some other server or network error (possibly with this specific request/file)
            # This is when accounting for all possible errors in the curl manual assuming a correctly formed curl command and an HTTP(S) request, using only the curl features we're using, and a sane build
            echo "Miscellaneous server or network error!"
            ;;
        126 | 127 )
            echo "Curl command not found! Please install curl and try again. Exiting..."
            return "$fatal_error_action"
            ;;
        # Exit statuses are undefined by POSIX beyond this point
        *)
            case "$(kill -l "$error_code")" in
            # Signals defined to exist by POSIX:
            # https://pubs.opengroup.org/onlinepubs/009695399/basedefs/signal.h.html
            INT)
                echo "Curl was interrupted!"
                ;;
            # There could be other signals but these are most common
            SEGV | ABRT )
                echo "Curl crashed! Failed exploitation attempt? Please report any core dumps to curl developers. Exiting..."
                return "$fatal_error_action"
                ;;
            *)
                echo "Curl terminated due to a fatal signal!"
                ;;
            esac
    esac
    return 1
}

download_windows_server() {
    local iso_download_page_html=""
    # Copyright (C) 2024 Elliot Killick <contact@elliotkillick.com>
    # This function is adapted from the Mido project:
    # https://github.com/ElliotKillick/Mido

    # Download enterprise evaluation Windows versions
    local windows_version="$1"
    local enterprise_type="$2"
    local PRETTY_RELEASE=""

    case "${RELEASE}" in
        "10-ltsc") PRETTY_RELEASE="10 LTSC";;
        "2012-r2") PRETTY_RELEASE="2012 R2";;
        *) PRETTY_RELEASE="${RELEASE}";;
    esac

    echo "Downloading $(pretty_name "${OS}") ${PRETTY_RELEASE} (${I18N})"

    local url="https://www.microsoft.com/en-us/evalcenter/download-$windows_version"

    echo " - Parsing download page: ${url}"
    iso_download_page_html="$(curl --silent --location --max-filesize 1M --fail --proto =https --tlsv1.2 --http1.1 -- "$url")" || {
        handle_curl_error $?
        return $?
    }

    if ! [ "$iso_download_page_html" ]; then
        # This should only happen if there's been some change to where this download page is located
        echo " - Windows server download page gave us an empty response"
        return 1
    fi

    local CULTURE=""
    local COUNTRY=""
    case "${I18N}" in
        "English (Great Britain)")
            CULTURE="en-gb"
            COUNTRY="GB";;
        "Chinese (Simplified)")
            CULTURE="zh-cn"
            COUNTRY="CN";;
        "Chinese (Traditional)")
            CULTURE="zh-tw"
            COUNTRY="TW";;
        "French")
            CULTURE="fr-fr"
            COUNTRY="FR";;
        "German")
            CULTURE="de-de"
            COUNTRY="DE";;
        "Italian")
            CULTURE="it-it"
            COUNTRY="IT";;
        "Japanese")
            CULTURE="ja-jp"
            COUNTRY="JP";;
        "Korean")
            CULTURE="ko-kr"
            COUNTRY="KR";;
        "Portuguese (Brazil)")
            CULTURE="pt-br"
            COUNTRY="BR";;
        "Spanish")
            CULTURE="es-es"
            COUNTRY="ES";;
        "Russian")
            CULTURE="ru-ru"
            COUNTRY="RU";;
        *)
            CULTURE="en-us"
            COUNTRY="US";;
    esac

    echo " - Getting download link.."
    iso_download_links="$(echo "$iso_download_page_html" | grep -o "https://go.microsoft.com/fwlink/p/?LinkID=[0-9]\+&clcid=0x[0-9a-z]\+&culture=${CULTURE}&country=${COUNTRY}")" || {
        # This should only happen if there's been some change to the download endpoint web address
        echo " - Windows server download page gave us no download link"
        return 1
    }

    # Limit untrusted size for input validation
    iso_download_links="$(echo "$iso_download_links" | head -c 1024)"

    case "$enterprise_type" in
        # Select x64 download link
        "enterprise") iso_download_link=$(echo "$iso_download_links" | head -n 2 | tail -n 1) ;;
        # Select x64 LTSC download link
        "ltsc") iso_download_link=$(echo "$iso_download_links" | head -n 4 | tail -n 1) ;;
        *) iso_download_link="$iso_download_links" ;;
    esac

    # Follow redirect so proceeding log message is useful
    # This is a request we make this Fido doesn't
    # We don't need to set "--max-filesize" here because this is a HEAD request and the output is to /dev/null anyway
    iso_download_link="$(curl --silent --location --output /dev/null --silent --write-out "%{url_effective}" --head --fail --proto =https --tlsv1.2 --http1.1 -- "$iso_download_link")" || {
        # This should only happen if the Microsoft servers are down
        handle_curl_error $?
        return $?
    }

    # Limit untrusted size for input validation
    iso_download_link="$(echo "$iso_download_link" | head -c 1024)"

    echo " - URL: $iso_download_link"

    # Download ISO
    FILE_NAME="${iso_download_link##*/}"
    web_get "${iso_download_link}" "${VM_PATH}" "${FILE_NAME}"
    OS="windows-server"
}

download_windows_workstation() {
    local HASH=""
    local session_id=""
    local iso_download_page_html=""
    local product_edition_id=""
    local language_skuid_table_html=""
    local sku_id=""
    local iso_download_link_html=""
    local iso_download_link=""

    echo "Downloading Windows ${RELEASE} (${I18N})"
    # This function is adapted from the Mido project:
    # https://github.com/ElliotKillick/Mido
    # Download newer consumer Windows versions from behind gated Microsoft API

    # Either 8, 10, or 11
    local windows_version="$1"

    local url="https://www.microsoft.com/en-us/software-download/windows$windows_version"
    case "$windows_version" in
        8 | 10) url="${url}ISO";;
    esac

    local user_agent="Mozilla/5.0 (X11; Linux x86_64; rv:100.0) Gecko/20100101 Firefox/100.0"
    # uuidgen: For MacOS (installed by default) and other systems (e.g. with no /proc) that don't have a kernel interface for generating random UUIDs
    session_id="$(cat /proc/sys/kernel/random/uuid 2> /dev/null || uuidgen --random)"

    # Get product edition ID for latest release of given Windows version
    # Product edition ID: This specifies both the Windows release (e.g. 22H2) and edition ("multi-edition" is default, either Home/Pro/Edu/etc., we select "Pro" in the answer files) in one number
    # This is the *only* request we make that Fido doesn't. Fido manually maintains a list of all the Windows release/edition product edition IDs in its script (see: $WindowsVersions array). This is helpful for downloading older releases (e.g. Windows 10 1909, 21H1, etc.) but we always want to get the newest release which is why we get this value dynamically
    # Also, keeping a "$WindowsVersions" array like Fido does would be way too much of a maintenance burden
    # Remove "Accept" header that curl sends by default
    echo " - Parsing download page: ${url}"
    iso_download_page_html="$(curl --silent --user-agent "$user_agent" --header "Accept:" --max-filesize 1M --fail --proto =https --tlsv1.2 --http1.1 -- "$url")" || {
        handle_curl_error $?
        return $?
    }

    echo -n " - Getting Product edition ID: "
    # tr: Filter for only numerics to prevent HTTP parameter injection
    # head -c was recently added to POSIX: https://austingroupbugs.net/view.php?id=407
    product_edition_id="$(echo "$iso_download_page_html" | grep -Eo '<option value="[0-9]+">Windows' | cut -d '"' -f 2 | head -n 1 | tr -cd '0-9' | head -c 16)"
    echo "$product_edition_id"

    echo " - Permit Session ID: $session_id"
    # Permit Session ID
    # "org_id" is always the same value
    curl --silent --output /dev/null --user-agent "$user_agent" --header "Accept:" --max-filesize 100K --fail --proto =https --tlsv1.2 --http1.1 -- "https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=$session_id" || {
        # This should only happen if there's been some change to how this API works
        handle_curl_error $?
        return $?
    }

    # Extract everything after the last slash
    local url_segment_parameter="${url##*/}"

    echo -n " - Getting language SKU ID: "
    # Get language -> skuID association table
    # SKU ID: This specifies the language of the ISO. We always use "English (United States)", however, the SKU for this changes with each Windows release
    # We must make this request so our next one will be allowed
    # --data "" is required otherwise no "Content-Length" header will be sent causing HTTP response "411 Length Required"
    language_skuid_table_html="$(curl --silent --request POST --user-agent "$user_agent" --data "" --header "Accept:" --max-filesize 10K --fail --proto =https --tlsv1.2 --http1.1 -- "https://www.microsoft.com/en-US/api/controls/contentinclude/html?pageId=a8f8f489-4c7f-463a-9ca6-5cff94d8d041&host=www.microsoft.com&segments=software-download,$url_segment_parameter&query=&action=getskuinformationbyproductedition&sessionId=$session_id&productEditionId=$product_edition_id&sdVersion=2")" || {
        handle_curl_error $?
        return $?
    }

    # Limit untrusted size for input validation
    language_skuid_table_html="$(echo "$language_skuid_table_html" | head -c 10240)"

    # tr: Filter for only alphanumerics or "-" to prevent HTTP parameter injection
    sku_id="$(echo "$language_skuid_table_html" | grep "${I18N}" | sed 's/&quot;//g' | cut -d ',' -f 1  | cut -d ':' -f 2 | tr -cd '[:alnum:]-' | head -c 16)"
    echo "$sku_id"

    echo " - Getting ISO download link..."
    # Get ISO download link
    # If any request is going to be blocked by Microsoft it's always this last one (the previous requests always seem to succeed)
    # --referer: Required by Microsoft servers to allow request
    iso_download_link_html="$(curl --silent --request POST --user-agent "$user_agent" --data "" --referer "$url" --header "Accept:" --max-filesize 100K --fail --proto =https --tlsv1.2 --http1.1 -- "https://www.microsoft.com/en-US/api/controls/contentinclude/html?pageId=6e2a1789-ef16-4f27-a296-74ef7ef5d96b&host=www.microsoft.com&segments=software-download,$url_segment_parameter&query=&action=GetProductDownloadLinksBySku&sessionId=$session_id&skuId=$sku_id&language=English&sdVersion=2")"

    local failed=0

    if ! [ "$iso_download_link_html" ]; then
        # This should only happen if there's been some change to how this API works
        echo " - Microsoft servers gave us an empty response to our request for an automated download."
        failed=1
    fi

    if echo "$iso_download_link_html" | grep -q "We are unable to complete your request at this time."; then
        echo " - WARNING! Microsoft blocked the automated download request based on your IP address."
        failed=1
    fi

    if [ ${failed} -eq 1 ]; then
        echo "   Manually download the Windows ${windows_version} ISO using a web browser from: ${url}"
        echo "   Save the downloaded ISO to: $(realpath "${VM_PATH}")"
        echo "   Update the config file to reference the downloaded ISO: ./${VM_PATH}.conf"
        echo "   Continuing with the VM creation process..."
        return 1
    fi

    # Filter for 64-bit ISO download URL
    # sed: HTML decode "&" character
    # tr: Filter for only alphanumerics or punctuation
    iso_download_link="$(echo "$iso_download_link_html" | grep -o "https://software.download.prss.microsoft.com.*IsoX64" | cut -d '"' -f 1 | sed 's/&amp;/\&/g' | tr -cd '[:alnum:][:punct:]')"

    if ! [ "$iso_download_link" ]; then
        # This should only happen if there's been some change to the download endpoint web address
        echo " - Microsoft servers gave us no download link to our request for an automated download. Please manually download this ISO in a web browser: $url"
        return 1
    fi

    echo " - URL: ${iso_download_link%%\?*}"

    # Download ISO
    FILE_NAME="$(echo "$iso_download_link" | cut -d'?' -f1 | cut -d'/' -f5)"
    web_get "${iso_download_link}" "${VM_PATH}" "${FILE_NAME}"
}

get_windows() {

    if [ "${RELEASE}" == "10-ltsc" ]; then
        download_windows_server windows-10-enterprise ltsc
    elif [ "${OS}" == "windows-server" ]; then
        download_windows_server "windows-server-${RELEASE}"
    else
        download_windows_workstation "${RELEASE}"
    fi

}

verifyFile() {

  local iso="$1"
  local size="$2"
  local total="$3"
  local check="$4"

  if [ -n "$size" ] && [[ "$total" != "$size" ]] && [[ "$size" != "0" ]]; then
    warn "The downloaded file has an unexpected size: $total bytes, while expected value was: $size bytes. Please report this at $SUPPORT/issues"
  fi

  local hash=""
  local algo="SHA256"

  [ -z "$check" ] && return 0
  [[ "$VERIFY" != [Yy1]* ]] && return 0
  [[ "${#check}" == "40" ]] && algo="SHA1"

  local msg="Verifying downloaded ISO..."
  info "$msg" && html "$msg"

  if [[ "${algo,,}" != "sha256" ]]; then
    hash=$(sha1sum "$iso" | cut -f1 -d' ')
  else
    hash=$(sha256sum "$iso" | cut -f1 -d' ')
  fi

  if [[ "$hash" == "$check" ]]; then
    info "Succesfully verified ISO!" && return 0
  fi

  error "The downloaded file has an invalid $algo checksum: $hash , while expected value was: $check. Please report this at $SUPPORT/issues"

  rm -f "$iso"
  return 1
}

doMido() {

  local iso="$1"
  local version="$2"
  local desc="$3"
  local rc sum size total

  rm -f "$iso"
  rm -f "$iso.PART"

  size=$(getMido "$version" "size")
  sum=$(getMido "$version" "sum")

  local msg="Downloading $desc..."
  info "$msg" && html "$msg"
  /run/progress.sh "$iso.PART" "$size" "Downloading $desc ([P])..." &

  cd "$TMP"
  { /run/xmido.sh "${version,,}"; rc=$?; } || :
  cd /run

  fKill "progress.sh"

  if (( rc == 0 )) && [ -f "$iso" ]; then
    total=$(stat -c%s "$iso")
    if [ "$total" -gt 100000000 ]; then
      ! verifyFile "$iso" "$size" "$total" "$sum" && return 1
      html "Download finished successfully..." && return 0
    fi
  fi

  rm -f "$iso"
  rm -f "$iso.PART"

  return 1
}

downloadFile() {

  local iso="$1"
  local url="$2"
  local sum="$3"
  local size="$4"
  local desc="$5"
  local rc total progress domain dots

  rm -f "$iso"

  # Check if running with interactive TTY or redirected to docker log
  if [ -t 1 ]; then
    progress="--progress=bar:noscroll"
  else
    progress="--progress=dot:giga"
  fi

  local msg="Downloading $desc..."
  html "$msg"

  domain=$(echo "$url" | awk -F/ '{print $3}')
  dots=$(echo "$domain" | tr -cd '.' | wc -c)
  (( dots > 1 )) && domain=$(expr "$domain" : '.*\.\(.*\..*\)')

  if [ -n "$domain" ] && [[ "${domain,,}" != *"microsoft.com" ]]; then
    msg="Downloading $desc from $domain..."
  fi

  info "$msg"
  /run/progress.sh "$iso" "$size" "Downloading $desc ([P])..." &

  { wget "$url" -O "$iso" -q --timeout=10 --show-progress "$progress"; rc=$?; } || :

  fKill "progress.sh"

  if (( rc == 0 )) && [ -f "$iso" ]; then
    total=$(stat -c%s "$iso")
    if [ "$total" -gt 100000000 ]; then
      ! verifyFile "$iso" "$size" "$total" "$sum" && return 1
      html "Download finished successfully..." && return 0
    fi
  fi

  error "Failed to download $url , reason: $rc"

  rm -f "$iso"
  return 1
}

getESD() {

  local dir="$1"
  local version="$2"
  local editionName
  local winCatalog size

  if ! isESD "${version,,}"; then
    error "Invalid VERSION specified, value \"$version\" is not recognized!" && return 1
  fi

  winCatalog=$(getCatalog "$version" "url")
  editionName=$(getCatalog "$version" "edition")

  local msg="Downloading product information from Microsoft..."
  info "$msg" && html "$msg"

  rm -rf "$dir"
  mkdir -p "$dir"

  local wFile="catalog.cab"
  local xFile="products.xml"
  local eFile="esd_edition.xml"
  local fFile="products_filter.xml"

  { wget "$winCatalog" -O "$dir/$wFile" -q --timeout=10; rc=$?; } || :
  (( rc != 0 )) && error "Failed to download $winCatalog , reason: $rc" && return 1

  cd "$dir"

  if ! cabextract "$wFile" > /dev/null; then
    cd /run
    error "Failed to extract $wFile!" && return 1
  fi

  cd /run

  if [ ! -s "$dir/$xFile" ]; then
    error "Failed to find $xFile in $wFile!" && return 1
  fi

  local esdLang="en-us"
  local edQuery='//File[Architecture="'${PLATFORM}'"][Edition="'${editionName}'"]'

  echo -e '<Catalog>' > "$dir/$fFile"
  xmllint --nonet --xpath "${edQuery}" "$dir/$xFile" >> "$dir/$fFile" 2>/dev/null
  echo -e '</Catalog>'>> "$dir/$fFile"
  xmllint --nonet --xpath '//File[LanguageCode="'${esdLang}'"]' "$dir/$fFile" >"$dir/$eFile"

  size=$(stat -c%s "$dir/$eFile")
  if ((size<20)); then
    error "Failed to find Windows product in $eFile!" && return 1
  fi

  local tag="FilePath"
  ESD=$(xmllint --nonet --xpath "//$tag" "$dir/$eFile" | sed -E -e "s/<[\/]?$tag>//g")

  if [ -z "$ESD" ]; then
    error "Failed to find ESD URL in $eFile!" && return 1
  fi

  tag="Sha1"
  ESD_SUM=$(xmllint --nonet --xpath "//$tag" "$dir/$eFile" | sed -E -e "s/<[\/]?$tag>//g")
  tag="Size"
  ESD_SIZE=$(xmllint --nonet --xpath "//$tag" "$dir/$eFile" | sed -E -e "s/<[\/]?$tag>//g")

  rm -rf "$dir"
  return 0
}

downloadImage() {

  local iso="$1"
  local version="$2"
  local tried="n"
  local url sum size base desc

  if [[ "${version,,}" == "http"* ]]; then
    base=$(basename "$iso")
    desc=$(fromFile "$base")
    downloadFile "$iso" "$version" "" "" "$desc" && return 0
    return 1
  fi

  if ! validVersion "$version"; then
    error "Invalid VERSION specified, value \"$version\" is not recognized!" && return 1
  fi

  desc=$(printVersion "$version" "")

  if isMido "$version"; then
    tried="y"
    doMido "$iso" "$version" "$desc" && return 0
  fi

  switchEdition "$version"

  if isESD "$version"; then

    if [[ "$tried" != "n" ]]; then
      info "Failed to download $desc using Mido, will try a diferent method now..."
    fi

    tried="y"

    if getESD "$TMP/esd" "$version"; then
      ISO="${ISO%.*}.esd"
      downloadFile "$ISO" "$ESD" "$ESD_SUM" "$ESD_SIZE" "$desc" && return 0
      ISO="$iso"
    fi

  fi

  for ((i=1;i<=MIRRORS;i++)); do

    url=$(getLink "$i" "$version")

    if [ -n "$url" ]; then
      if [[ "$tried" != "n" ]]; then
        info "Failed to download $desc, will try another mirror now..."
      fi
      tried="y"
      size=$(getSize "$i" "$version")
      sum=$(getHash "$i" "$version")
      downloadFile "$iso" "$url" "$sum" "$size" "$desc" && return 0
    fi

  done

  return 1
}

return 0
