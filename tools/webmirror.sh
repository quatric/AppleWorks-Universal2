#!/bin/sh
# Builds the Web Mirror for the Starting Points "Web" tab: AppleWorks fetched its
# web Starting Points (the Newsletter, the Templates catalog and the template sets
# it links to) from awpicts.apple.com, which is gone. This takes the copies the
# Internet Archive kept of that server's US documents (the latest good capture of
# each) into game/AppleWorks 6/.Web Mirror/awpicts.apple.com/, dated as captured,
# and adds the gzipped 6.1 names the Web tab's items ask for (newsletter6-1.cwk.gz,
# templates6-1.cwk.gz), made from the same documents. xlate/build.sh copies the
# mirror into the bundle; the runtime answers that host's requests from it.
# Extras (extras6-1.cwk.gz) was never archived, so that item stays unavailable.
# usage: tools/webmirror.sh
set -e
cd "$(dirname "$0")/.."
PY=${PY:-python3}
OUT="game/AppleWorks 6/.Web Mirror/awpicts.apple.com"
[ -d "game/AppleWorks 6" ] || { echo "install AppleWorks first (tools/install.sh)" >&2; exit 1; }
mkdir -p dl/awpicts
CDX="https://web.archive.org/cdx/search/cdx?url=awpicts.apple.com/docs/US/&matchType=prefix&output=json&filter=statuscode:200&fl=timestamp,original"
curl -sf --http1.1 --retry 3 "$CDX" > dl/awpicts/cdx.json
# the latest capture of each document
$PY -I - dl/awpicts/cdx.json > dl/awpicts/list.txt <<'EOF'
import json, sys, re
rows = json.load(open(sys.argv[1]))[1:]
latest = {}
for ts, url in rows:
    path = re.sub(r'^https?://awpicts\.apple\.com(:80)?', '', url).split('?')[0]
    if not path.lower().endswith('.cwk') or '..' in path:
        continue
    if path not in latest or ts > latest[path]:
        latest[path] = ts
for path, ts in sorted(latest.items()):
    print(ts, path)
EOF
rm -rf "$OUT"; mkdir -p "$OUT"
while read ts path <&3; do
	f="$OUT$path"
	mkdir -p "$(dirname "$f")"
	src="dl/awpicts/raw/$ts$path"
	if [ ! -s "$src" ]; then
		mkdir -p "$(dirname "$src")"
		# gently: the archive turns away quick successions of requests
		sleep 2
		curl -sf --http1.1 --retry 6 --retry-all-errors --retry-delay 10 -o "$src" </dev/null "https://web.archive.org/web/${ts}id_/http://awpicts.apple.com$path" \
			|| { echo "skipped $path"; rm -f "$src"; continue; }
	fi
	cp "$src" "$f"
	touch -t "$(echo $ts | cut -c1-12).$(echo $ts | cut -c13-14)" "$f"
	echo "$ts $path"
done 3< dl/awpicts/list.txt
# the Web tab's items: <name>6-1.cwk.gz, a MacBinary capture gzipped (MacBinary keeps the
# document's name and its stationery type, so the item opens as an untitled copy as it did);
# these captures are MacBinary, later ones are bare documents
for item in newsletter:20001109112400 templates:20010302181657; do
	n=${item%%:*}; ts=${item##*:}
	src="dl/awpicts/raw/mb$ts/$n.cwk"
	if [ ! -s "$src" ]; then
		mkdir -p "$(dirname "$src")"
		curl -sf --http1.1 --retry 6 --retry-all-errors --retry-delay 10 -o "$src" </dev/null \
			"https://web.archive.org/web/${ts}id_/http://awpicts.apple.com:80/docs/US/$n.cwk" || { echo "skipped the Web tab's $n"; rm -f "$src"; continue; }
	fi
	gzip -9 -n -c "$src" > "$OUT/docs/US/${n}6-1.cwk.gz"
	touch -t "$(echo $ts | cut -c1-12).$(echo $ts | cut -c13-14)" "$OUT/docs/US/${n}6-1.cwk.gz"
done
echo "$(find "$OUT" -type f | wc -l | tr -d ' ') files in $OUT"
