#!/bin/sh
# Hardened build (qirara/Surfing fork)
# 与上游的区别：
#   - 不打包 SurfingTile APK（闭源，内置 Firebase Analytics / Crashlytics / Remote Config / FCM）
#   - 下载的二进制都按 GitHub 发布资产的 sha256 digest 校验，结果写入 zip 内 BUILD-MANIFEST.txt
#   - 可通过环境变量锁定版本：MIHOMO_VERSION / ZASH_VERSION / CURL_REF
set -eu

isAlpha="${isAlpha:-false}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

CORE_DST="box_bll/bin/clash"
MIHOMO_REPO="MetaCubeX/mihomo"
MIHOMO_NAME="mihomo-android-arm64-v8"

CURL_DST="box_bll/bin/curl"
CURL_REPO="Zackptg5/Cross-Compiled-Binaries-Android"
CURL_PATH="curl/curl-arm64"

ZASH_REPO="Zephyruso/zashboard"
ZASH_DST="box_bll/clash/webroot/Zash"

MANIFEST="BUILD-MANIFEST.txt"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

api() {
    if [ -n "$GITHUB_TOKEN" ]; then
        curl -fsSL --retry 5 --retry-delay 5 -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" "$1"
    else
        curl -fsSL --retry 5 --retry-delay 5 -H "Accept: application/vnd.github+json" "$1"
    fi
}

# release_json <repo> <tag|latest>
release_json() {
    if [ "$2" = "latest" ]; then api "https://api.github.com/repos/$1/releases/latest"
    else api "https://api.github.com/repos/$1/releases/tags/$2"; fi
}

# fetch_asset <repo> <tag|latest> <asset-name-regex> <out>  -> 打印 "tag name sha256"
fetch_asset() {
    json=$(release_json "$1" "$2")
    tag=$(printf '%s' "$json" | jq -r '.tag_name')
    asset=$(printf '%s' "$json" | jq -c --arg re "$3" '[.assets[] | select(.name | test($re))][0]')
    [ "$asset" != "null" ] || { echo "Error: $1 $tag 没有匹配 $3 的资产" >&2; exit 1; }
    name=$(printf '%s' "$asset" | jq -r '.name')
    url=$(printf '%s' "$asset" | jq -r '.browser_download_url')
    digest=$(printf '%s' "$asset" | jq -r '.digest // empty' | sed 's/^sha256://')
    curl -fL --retry 5 --retry-delay 5 "$url" -o "$4"
    actual=$(sha256sum "$4" | awk '{print $1}')
    if [ -n "$digest" ]; then
        [ "$digest" = "$actual" ] || { echo "Error: $name sha256 不匹配 (GitHub $digest, 实际 $actual)" >&2; exit 1; }
        echo "$name: sha256 与 GitHub 发布记录一致" >&2
    else
        echo "Warn: $name 没有 GitHub digest，仅记录哈希" >&2
    fi
    echo "$tag $name $actual"
}

: > "$MANIFEST"
echo "Surfing hardened build $(date -u '+%Y-%m-%dT%H:%M:%SZ') commit ${SHORT_HASH:-$(git rev-parse --short=7 HEAD)}" >> "$MANIFEST"

# --- mihomo
out=$(fetch_asset "$MIHOMO_REPO" "${MIHOMO_VERSION:-latest}" "^${MIHOMO_NAME}-v[0-9.]+\\.gz$" "$WORK/core.gz") || exit 1
set -- $out
echo "mihomo $1 $2 sha256=$3" >> "$MANIFEST"
gunzip -c "$WORK/core.gz" > "$CORE_DST"
chmod +x "$CORE_DST"
echo "mihomo binary sha256=$(sha256sum "$CORE_DST" | awk '{print $1}')" >> "$MANIFEST"

# --- curl（仓库原始文件，没有发布 digest：锁定到 commit 并记录哈希）
if [ -z "${CURL_REF:-}" ]; then
    CURL_REF=$(api "https://api.github.com/repos/$CURL_REPO/commits?path=$CURL_PATH&per_page=1" | jq -r '.[0].sha') || exit 1
fi
curl -fL --retry 5 --retry-delay 5 "https://raw.githubusercontent.com/$CURL_REPO/$CURL_REF/$CURL_PATH" -o "$CURL_DST"
chmod +x "$CURL_DST"
echo "curl $CURL_REPO@$CURL_REF sha256=$(sha256sum "$CURL_DST" | awk '{print $1}')" >> "$MANIFEST"

# --- Zashboard（本地面板，构建时打包；运行时不再自动下载）
out=$(fetch_asset "$ZASH_REPO" "${ZASH_VERSION:-latest}" '^dist\.zip$' "$WORK/zash.zip") || exit 1
set -- $out
echo "zashboard $1 $2 sha256=$3" >> "$MANIFEST"
rm -rf "$ZASH_DST" "$WORK/zash"
unzip -q "$WORK/zash.zip" -d "$WORK/zash"
[ -d "$WORK/zash/dist" ] || { echo "Error: Zashboard ZIP 结构异常" >&2; exit 1; }
mkdir -p "$(dirname "$ZASH_DST")"
mv "$WORK/zash/dist" "$ZASH_DST"

# --- 仓库内自带的二进制 / 数据，只记录哈希
for f in box_bll/bin/busybox box_bll/clash/ASN.mmdb; do
    echo "$f (repo) sha256=$(sha256sum "$f" | awk '{print $1}')" >> "$MANIFEST"
done
echo "SurfingTile APK: not bundled" >> "$MANIFEST"

version=$(grep '^version=' module.prop | awk -F '=' '{print $2}' | sed 's/ (.*//')
short_hash=${SHORT_HASH:-$(git rev-parse --short=7 HEAD)}

if [ "$isAlpha" = "true" ]; then
    new_version="${version} (hardened-${short_hash})"
    filename="Surfing_hardened_${short_hash}.zip"
else
    new_version="${version} (hardened-release-${short_hash})"
    filename="Surfing_${version}_hardened.zip"
fi

sed -i "s/^version=.*/version=${new_version}/" module.prop

zip -r -o -X "$filename" ./ \
    -x 'app/*' \
    -x '.git/*' \
    -x '.github/*' \
    -x 'folder/*' \
    -x 'build.sh' \
    -x 'Surfing.json' \
    -x 'SECURITY_AUDIT.md'

cat "$MANIFEST"
echo "Build Completed: $filename"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "zip=$filename" >> "$GITHUB_OUTPUT"
exit 0
