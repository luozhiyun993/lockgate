#!/bin/bash
# 下载内嵌的 mihomo 内核（固定版本并校验 SHA256）和规则数据，输出到 .build/core。
# 升级内嵌版本时，同时修改下面的版本号和两个校验值（取自 GitHub Release 资源的 digest）。
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MIHOMO_VERSION="v1.19.34"
ARM64_SHA256="1a7a20eca63fbbaec90137717465bfde488d0db2a3a79b8fadebf9b2545b6e4c"
AMD64_SHA256="703bceaa494732fa456f47e6ac2f06bf0bc5593d4c927d5f61e10f1a31039c37"
RELEASE="https://github.com/MetaCubeX/mihomo/releases/download/$MIHOMO_VERSION"
GEO_RELEASE="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest"
OUT="$PROJECT_DIR/.build/core"
CACHE="$OUT/cache"
mkdir -p "$CACHE" "$OUT/geo"

fetch() {
    local url="$1" target="$2" expected="${3:-}"
    if [ ! -s "$target" ] || { [ -n "$expected" ] && [ "$(shasum -a 256 "$target" | cut -d' ' -f1)" != "$expected" ]; }; then
        curl -fL --retry 3 --connect-timeout 20 -o "$target.part" "$url"
        mv "$target.part" "$target"
    fi
    if [ -n "$expected" ] && [ "$(shasum -a 256 "$target" | cut -d' ' -f1)" != "$expected" ]; then
        rm -f "$target"
        printf 'SHA256 mismatch: %s\n' "$url" >&2
        exit 1
    fi
}

fetch "$RELEASE/mihomo-darwin-arm64-$MIHOMO_VERSION.gz" "$CACHE/arm64-$MIHOMO_VERSION.gz" "$ARM64_SHA256"
fetch "$RELEASE/mihomo-darwin-amd64-compatible-$MIHOMO_VERSION.gz" "$CACHE/amd64-$MIHOMO_VERSION.gz" "$AMD64_SHA256"
gunzip -c "$CACHE/arm64-$MIHOMO_VERSION.gz" > "$CACHE/mihomo-arm64"
gunzip -c "$CACHE/amd64-$MIHOMO_VERSION.gz" > "$CACHE/mihomo-amd64"
lipo -create "$CACHE/mihomo-arm64" "$CACHE/mihomo-amd64" -output "$OUT/mihomo"
chmod 755 "$OUT/mihomo"
"$OUT/mihomo" -v | grep -q "$MIHOMO_VERSION"

# 规则数据每天更新、没有固定版本，这里只保证经 HTTPS 从官方仓库取得；已有缓存时不重复下载。
fetch "$GEO_RELEASE/geoip.metadb" "$OUT/geo/geoip.metadb"
fetch "$GEO_RELEASE/geosite.dat" "$OUT/geo/GeoSite.dat"
printf '%s\n' "$MIHOMO_VERSION" > "$OUT/version.txt"
printf 'Core ready: %s (%s)\n' "$OUT/mihomo" "$MIHOMO_VERSION"
