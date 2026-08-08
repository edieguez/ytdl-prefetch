# ytdl-prefetch

Shrinks the gap between one video ending and the next starting, for
playlists whose items are resolved via `ytdl_hook` (YouTube and anything
else yt-dlp handles).

## Why

`ytdl_hook.lua` (mpv's built-in yt-dlp integration) only resolves a
playlist entry's real stream URL once mpv actually tries to play it -
i.e. only after the previous item has already ended. That resolution
(fetch the page, decipher YouTube's signature, pick a format) routinely
takes a few seconds. mpv's own `--prefetch-playlist` option explicitly
doesn't help here - its manual says outright it "does not work with URLs
resolved by the youtube-dl wrapper, and it won't."

## How it works

- **`scripts/ytdl_prefetch.lua`** resolves *both* playlist neighbors of
  whatever's currently playing - `playlist-pos - 1` and `playlist-pos +
  1` - in the background (`mp.command_native_async`, never blocks
  playback), and writes the results to cache files. Three triggers, all
  calling the same neighbor-prefetch check:
  - **Immediately** when a file starts (`file-loaded`) - not "wait until
    the current item is nearly over": jumping to the next or previous
    item can happen at any point during playback, not just near the end.
  - **Whenever the playlist grows** (`playlist-count` increasing) - an
    item added while something's already playing (`mpv-add`,
    `ctrl+v`/paste-url, etc. - the normal way items end up in the queue)
    would otherwise never get prefetched at all, since `file-loaded`
    already fired before it existed.
  - **Near the end of a long video** (`time-remaining` under a threshold,
    default 20s) as a refresh, in case an earlier prefetch has gone stale
    by then.
- **`bin/ytdl-cache-wrapper`** stands in for the real `yt-dlp` binary via
  `ytdl_hook`'s own `ytdl_path` option. When `ytdl_hook` actually tries to
  load an item for real, it invokes this wrapper instead of `yt-dlp`
  directly; if a fresh matching cache entry exists, it's served instantly
  instead of running a real (multi-second) `yt-dlp` subprocess. Anything
  not prefetched - a cache miss, an expired entry, a non-adjacent jump,
  a non-`ytdl_hook` file - falls straight through to a real `yt-dlp` call,
  identical to `ytdl_hook`'s behavior without this plugin at all. The
  wrapper itself has no concept of "next" or "previous" - it just serves
  whatever's cached under a given request's hash, so it needed no changes
  to support prefetching backward as well as forward.

Deliberately **does not** touch, fork, or reimplement any of
`ytdl_hook.lua`'s own format-selection/EDL-construction logic (which this
setup relies on for separate best-quality audio+video streams via
`all_formats`/`force_all_formats`) - that logic runs completely unchanged
whether its input JSON came from a real subprocess or a cached one, since
the wrapper only ever substitutes at the `yt-dlp` invocation boundary.

Both sides agree on where a given request's cached result lives via a
`cksum` of the *full* argument list `ytdl_hook` would pass to `yt-dlp`
(not just the URL) - if `ytdl-format`/`ytdl-raw-options` ever differ from
what was prefetched, that hashes differently, so a mismatched entry is
never served.

## Installation

1. Copy or symlink `scripts/ytdl_prefetch.lua` into mpv's `scripts/`
   directory.
2. (Optional) Copy `script-opts/ytdl_prefetch.conf.template` to
   `script-opts/ytdl_prefetch.conf` to override the defaults.
3. Add to `mpv.conf` (or an included config file), pointing `ytdl_path` at
   `bin/ytdl-cache-wrapper`:
   ```
   # script-opts/ytdl_hook.conf
   try_ytdl_first=yes
   ytdl_path=/absolute/path/to/plugins/ytdl-prefetch/bin/ytdl-cache-wrapper
   ```
4. Requires `yt-dlp` on `PATH` (or set `YTDL_PREFETCH_REAL_YTDL` in the
   environment mpv itself runs in, to point at it explicitly).

## Configuration

`script-opts/ytdl_prefetch.conf` controls the Lua side (`lead_time`,
`ttl_minutes`, `cache_dir`, `enabled`). `bin/ytdl-cache-wrapper`'s own
matching settings are environment variables instead (`YTDL_PREFETCH_TTL_MINUTES`,
`YTDL_PREFETCH_CACHE_DIR`, `YTDL_PREFETCH_REAL_YTDL`), since it's a
separate shell process that script-opts can't reach into - **if you
change `ttl_minutes` or `cache_dir` from their defaults, keep both sides
in sync** (either set the matching env var wherever mpv's own process
environment is defined, or just edit the wrapper script's own defaults
directly). Out of the box, with no customization on either side, the
defaults already match and nothing needs coordinating.

## Limitations

- Only prefetches the immediate neighbors (`playlist-pos - 1` and
  `playlist-pos + 1`) - jumping to an arbitrary, non-adjacent item (e.g.
  picking something from the interactive playlist) or `--shuffle` order
  isn't predicted, so it falls back to normal (uncached) resolution.
  Prefetching the entire playlist isn't practical. This is never a
  correctness issue, only a missed optimization.
- A prefetch that never ends up used (e.g. the user keeps watching
  forward past several items instead of jumping) is wasted work - the
  fetch still completes and gets cached, just never gets read before its
  TTL expires. Harmless, just a background `yt-dlp` call that didn't end
  up mattering.
