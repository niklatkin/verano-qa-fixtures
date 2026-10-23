#!/usr/bin/env bash
# zl-chunk-check.sh — finds JS files that a site's CDN serves cut short.
#
# Background (v4.10.0, 2026-10-21): through Cloudflare's Chicago edge (ORD), three
# /_next/static/chunks/*.js files on zenleafdispensaries.com came back truncated.
# The ORD responses carried x-envoy-upstream-service-time ~25000 ms and the cut copy
# was cached again after each purge. Other edges served the same files complete.
#
# What it does, per host:
#   1. reads build-info (sha, builtAt) and the home page HTML
#   2. fetches every /_next/static/chunks/*.js on the page the way a browser does
#      (Accept-Encoding: gzip, br)
#   3. compares the decoded size with the size encoded in the file's ETag
#      (W/"<hex size>-<hash>") and, if node is installed, checks the JS parses
#   4. prints one line per file and marks short / broken ones with BAD
#
# Usage:
#   bash zl-chunk-check.sh                          # one pass, both brands
#   bash zl-chunk-check.sh --repeat 10 --every 180  # 10 passes, 3 minutes apart
#   bash zl-chunk-check.sh --hosts zenleafdispensaries.com --log run.tsv
#
# Handles the versioned asset prefix (/v/<build>/_next/static/...) from COMPONENTS-17800: fetches the exact URL the page emits.
# Needs bash and curl. Optional: node (syntax check). Works on macOS, Linux, Git Bash.
# Read-only: it only sends GET requests, the same ones a visitor's browser sends.

set -u
HOSTS="zenleafdispensaries.com muvfl.com"
REPEAT=1
EVERY=180
LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hosts) HOSTS="$2"; shift 2 ;;
    --repeat) REPEAT="$2"; shift 2 ;;
    --every) EVERY="$2"; shift 2 ;;
    --log) LOG="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
done

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t zlchk)
trap 'rm -rf "$TMP"' EXIT
HAS_NODE=0; command -v node >/dev/null 2>&1 && HAS_NODE=1
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36 zl-chunk-check"
TAB=$(printf '\t')

hdr() { grep -i "^$1:" "$2" | tail -1 | cut -d' ' -f2- | tr -d '\r'; }

if [ -n "$LOG" ] && [ ! -s "$LOG" ]; then
  printf 'time_utc\thost\tfile\tstatus\tbytes\texpected\tcf_ray\tcf_cache\tage\tupstream_ms\tjs\n' > "$LOG"
fi

pass=0
while [ "$pass" -lt "$REPEAT" ]; do
  pass=$((pass + 1))
  for host in $HOSTS; do
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bi=$(curl -s -A "$UA" "https://$host/api/build-info?zlchk=$(date +%s)")
    builtAt=$(echo "$bi" | sed -n 's/.*"builtAt":"\([^"]*\)".*/\1/p')
    sha=$(echo "$bi" | sed -n 's/.*"sha":"\([0-9a-f]\{9\}\).*/\1/p')
    curl -s --compressed -A "$UA" -H 'Accept: text/html' "https://$host/" -o "$TMP/home.html"
    # Asset paths, with the versioned prefix when the build has one (COMPONENTS-17800: /v/<build time>/_next/static/...).
    files=$(grep -oE '(/v/[A-Za-z0-9]+)?/_next/static/chunks/[A-Za-z0-9_.~-]+\.js' "$TMP/home.html" | sort -u)
    prefix=$(echo "$files" | sed -n 's#^\(/v/[A-Za-z0-9]*\)/_next/.*#\1#p' | sort -u | tr '\n' ' ')
    bare=$(echo "$files" | grep -c '^/_next/' )
    n=0; bad=0
    for f in $files; do
      n=$((n + 1))
      curl -s --compressed -A "$UA" -H 'Accept-Encoding: gzip, br' -D "$TMP/h" -o "$TMP/c.js" "https://$host$f"
      bytes=$(wc -c < "$TMP/c.js" | tr -d ' ')
      etag=$(hdr etag "$TMP/h")
      hex=$(echo "$etag" | sed -n 's/^W\/"\([0-9a-fA-F]*\)-.*/\1/p')
      expected=""; [ -n "$hex" ] && expected=$((16#$hex))
      ray=$(hdr cf-ray "$TMP/h"); cache=$(hdr cf-cache-status "$TMP/h"); age=$(hdr age "$TMP/h")
      up=$(hdr x-envoy-upstream-service-time "$TMP/h")
      js="-"
      if [ "$HAS_NODE" = 1 ]; then node --check "$TMP/c.js" >/dev/null 2>&1 && js="ok" || js="SyntaxError"; fi
      status="ok"
      if [ -n "$expected" ] && [ "$bytes" != "$expected" ]; then status="BAD"; fi
      [ "$js" = "SyntaxError" ] && status="BAD"
      [ "$status" = "BAD" ] && bad=$((bad + 1))
      if [ -n "$LOG" ]; then
        echo "$now$TAB$host$TAB${f##*/}$TAB$status$TAB$bytes$TAB${expected:-?}$TAB$ray$TAB$cache$TAB${age:-}$TAB${up:-}$TAB$js" >> "$LOG"
      fi
      if [ "$status" = "BAD" ]; then
        echo "  BAD ${f##*/}  got $bytes of ${expected:-?} bytes  ray $ray  cache $cache  age ${age:-?}  upstream ${up:-?} ms  js $js"
      fi
    done
    echo "$now  $host  build $sha builtAt $builtAt  prefix ${prefix:-none} bare $bare  chunks $n  bad $bad"
  done
  if [ "$pass" -lt "$REPEAT" ]; then sleep "$EVERY"; fi
done
