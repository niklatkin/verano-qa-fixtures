# zl-chunk-check

Checks whether the CDN serves any of the site's JS files cut short. Written for the v4.10.0 Zen Leaf re-release (truncated `/_next/static/chunks/*.js` through Cloudflare's Chicago edge on 2026-10-21).

## Run

```bash
curl -sO https://raw.githubusercontent.com/niklatkin/verano-qa-fixtures/main/zl-chunk-check.sh

# one pass, both brands
bash zl-chunk-check.sh

# after the push: every 3 minutes for 30 minutes, Zen Leaf only, full log
bash zl-chunk-check.sh --hosts zenleafdispensaries.com --repeat 10 --every 180 --log zl-run.tsv
```

Needs `bash` and `curl`; `node` adds a JS syntax check. Read-only GET requests.

## Output

One summary line per host and pass, with the build (`sha`, `builtAt` from `/api/build-info`) and the count of bad files. Each bad file prints its size against the size in its ETag, `cf-ray` (the suffix is the Cloudflare edge, e.g. `-ORD` = Chicago), `cf-cache-status`, `age` and `x-envoy-upstream-service-time`.

With `--log`, every file of every pass goes to a TSV, so the upstream times are there even when nothing is short.

## What to look for

- `BAD` on any file: send the line (with the ray) to WP Engine and in #dev-sync.
- `upstream_ms` in the thousands on a `MISS`, even if the file is complete: the same slow origin fetch that got cut at ~25 s through ORD.
- The bad copy gets cached, so a file can stay short for every visitor on that edge until it is purged.
