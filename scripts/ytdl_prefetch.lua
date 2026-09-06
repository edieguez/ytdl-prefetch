-- ytdl-prefetch: resolves both adjacent playlist items' yt-dlp JSON in
-- the background while the current item is playing, so jumping to either
-- one - forward or backward, at any point during playback, not just near
-- the end - shrinks from a full yt-dlp resolution (page fetch + signature
-- decipher + format pick) down to just reading a cached file.
--
-- This script's only job is populating that cache ahead of time -
-- bin/ytdl-cache-wrapper (set as mpv's ytdl_path, see
-- script-opts/ytdl_hook.conf in the mpv config) is what actually serves
-- the cached result back to ytdl_hook.lua at the real transition moment.
-- See README.md for the full mechanism and why this needs a wrapper
-- binary rather than a pure-Lua approach (ytdl_hook.lua's own
-- audio+video EDL construction stays completely untouched either way -
-- this never needs to replicate it).

local options = require "mp.options"
local utils = require "mp.utils"
local msg = require "mp.msg"

local opts = {
    enabled = true,
    -- How many seconds before the end of a long file its neighbors get
    -- re-prefetched, as a one-shot timer (see the file-loaded handler
    -- below) - the main trigger is immediate, on file-loaded; this is
    -- just a refresh for long videos. Comfortably more than a yt-dlp
    -- resolution normally takes.
    lead_time = 20,
    -- Must match bin/ytdl-cache-wrapper's own TTL_MINUTES env var (a
    -- script-opts value can't reach into that separate shell process -
    -- see README.md). Neighbors are prefetched immediately on file-load,
    -- not just shortly before they're needed, so this has to comfortably
    -- outlast how long a video might play before the user actually skips
    -- - real YouTube stream URLs stay valid for about 6 hours, so this
    -- has a lot of room without any real risk of serving an expired one.
    ttl_minutes = 60,
    cache_dir = "~/.cache/mpv/ytdl-prefetch",
}
options.read_options(opts, "ytdl_prefetch")

local cache_dir = mp.command_native({"expand-path", opts.cache_dir})
mp.command_native({name = "subprocess", args = {"mkdir", "-p", cache_dir}, playback_only = false})

local function is_url(s)
    return type(s) == "string" and s:match("^%a[%a%d+%-%.]*://") ~= nil
end

-- Mirrors bin/ytdl-cache-wrapper's own key computation exactly: a cksum
-- of the full NUL-delimited argument list (POSIX-specified, present on
-- both the BSD tools this ships on and GNU/Linux - avoids the
-- shasum/md5/sha256sum availability/flag differences across platforms).
-- Both sides need to agree byte-for-byte on where a given request's
-- result lives.
--
-- Written to a temp file and fed to `cksum <file>` rather than piped via
-- the subprocess command's stdin_data: mpv's own docs warn stdin_data
-- "cannot pass arbitrary binary data" since it's handled as a string, and
-- confirmed empirically that a NUL-containing string there is rejected
-- outright ("incompatible type") - the wrapper's own `printf '%s\0' "$@"
-- | cksum` has no such issue (a real OS pipe, not this API), so this just
-- needs to produce identical bytes for cksum to read; cksum's output
-- differs cosmetically by filename when reading from a file instead of
-- stdin, but the checksum and byte-count fields parsed below are the
-- same either way.
local function cache_key(args)
    local tmp = os.tmpname()
    local f = io.open(tmp, "wb")
    if not f then return nil end
    for _, a in ipairs(args) do
        f:write(a, "\0")
    end
    f:close()

    local res = mp.command_native({
        name = "subprocess",
        args = {"cksum", tmp},
        capture_stdout = true,
        playback_only = false,
    })
    os.remove(tmp)

    if not res or res.status ~= 0 or not res.stdout then return nil end
    local checksum, size = res.stdout:match("(%d+)%s+(%d+)")
    if not checksum then return nil end
    return checksum .. "-" .. size
end

-- Mirrors ytdl_hook.lua's own run_ytdl_hook() command construction -
-- confirmed against mpv's actual current source and, empirically,
-- against a real invocation (logged argv matched exactly) - so the
-- cached JSON is indistinguishable from what a live yt-dlp call would
-- have produced. If mpv's ytdl_hook.lua ever changes this command shape
-- in a future version, prefetched entries just stop matching (different
-- hash) and silently fall back to normal, uncached resolution - not a
-- hard dependency, just a lost optimization.
local function build_ytdl_args(url)
    local args = {"--no-warnings", "-J", "--flat-playlist", "--sub-format", "ass/srt/best"}

    local format = mp.get_property("ytdl-format", "")
    if format ~= "" and format ~= "ytdl" then
        table.insert(args, "--format")
        table.insert(args, format)
    end

    local raw_options = mp.get_property_native("ytdl-raw-options", {})
    for key, value in pairs(raw_options) do
        table.insert(args, "--" .. key)
        if value ~= "" then
            table.insert(args, value)
        end
    end

    table.insert(args, "--sub-langs")
    table.insert(args, "all")
    table.insert(args, "--write-srt")
    table.insert(args, "--no-playlist")
    table.insert(args, "--")
    table.insert(args, url)
    return args
end

-- Guards against re-prefetching a URL that's already fresh-cached or
-- whose fetch is still running. Set at the very top of prefetch(), before
-- any blocking work (not just before the async yt-dlp call) - confirmed
-- empirically that mpv's synchronous subprocess call (used by
-- cache_key() below) yields back to the event loop while waiting rather
-- than fully blocking script execution, so a second trigger firing
-- mid-cache_key-call is genuinely reentrant: this was originally found
-- with a since-removed continuous time-remaining observer, where without
-- claiming in_flight immediately, dozens of redundant cksum subprocesses
-- got spawned every second for the same URL before the first one had
-- even finished - kept as a general guard since the same reentrancy is
-- possible from any trigger, not just that one.
local in_flight = {}

local function is_fresh(cache_file)
    local info = utils.file_info(cache_file)
    if not info then return false end
    return (os.time() - info.mtime) < (opts.ttl_minutes * 60)
end

local function prefetch(url)
    if not opts.enabled or not is_url(url) or in_flight[url] then
        return
    end
    in_flight[url] = true

    local args = build_ytdl_args(url)
    local key = cache_key(args)
    if not key then
        in_flight[url] = nil
        return
    end

    local cache_file = cache_dir .. "/" .. key .. ".json"
    if is_fresh(cache_file) then
        in_flight[url] = nil
        return
    end

    msg.debug("prefetching " .. url)

    local subprocess_args = {"yt-dlp"}
    for _, a in ipairs(args) do
        table.insert(subprocess_args, a)
    end

    mp.command_native_async({
        name = "subprocess",
        args = subprocess_args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function(success, res)
        if not success or not res or res.status ~= 0 or not res.stdout or res.stdout == "" then
            -- Clear in_flight so a later observer tick can retry (e.g. a
            -- transient network hiccup) - left set on success below,
            -- since re-fetching a URL that's already cached this session
            -- would otherwise mean one full cache_key computation (a real
            -- subprocess call) per observer tick for the rest of the
            -- lead-time window, confirmed wasteful in testing.
            in_flight[url] = nil
            msg.debug("prefetch failed for " .. url)
            return
        end

        -- Temp file + rename, both inside cache_dir (not the system temp
        -- dir - os.rename/rename(2) needs the same filesystem to be
        -- atomic, and can outright fail across devices) - so
        -- bin/ytdl-cache-wrapper can never read a partially-written
        -- entry. No extra uniqueness needed beyond the key itself: only
        -- one prefetch per URL runs at a time (in_flight guard above),
        -- and different URLs already hash to different keys.
        local tmp_file = cache_file .. ".tmp"
        local f = io.open(tmp_file, "wb")
        if not f then
            msg.debug("could not write prefetch cache for " .. url)
            return
        end
        f:write(res.stdout)
        f:close()
        os.rename(tmp_file, cache_file)
        msg.debug("prefetched " .. url)
    end)
end

-- Prefetches both playlist neighbors of the current position - the user
-- can jump forward or backward at any point during playback, not just
-- near the end, so both directions need covering, not just "next".
-- Either offset that's out of playlist bounds (mp.get_property returning
-- nil for it) is silently skipped.
local function prefetch_neighbors()
    local pos = mp.get_property_number("playlist-pos", -1)
    if pos < 0 then
        return
    end

    local prev_url = mp.get_property("playlist/" .. (pos - 1) .. "/filename")
    if prev_url then
        prefetch(prev_url)
    end

    local next_url = mp.get_property("playlist/" .. (pos + 1) .. "/filename")
    if next_url then
        prefetch(next_url)
    end
end

-- Fires immediately on every file change, covering an early N/P press
-- before the current item is anywhere near over - the main gap this was
-- missing initially (only prefetched "next", only once nearly done).
-- Resets in_flight first: once the current file actually changes,
-- whatever was tracked for the previous file's neighbors no longer needs
-- remembering (a stale entry here would only ever cause a harmless extra
-- cache_key recomputation, never wrong behavior, but there's no reason to
-- let this grow unbounded over hours of playback either) - done before
-- prefetch_neighbors() so this file's own prefetches aren't immediately
-- wiped out by the reset.
--
-- Also schedules a single one-shot refresh near the end of a long video
-- (see refresh_timer below), replacing what used to be a continuous
-- time-remaining property observer. That observer fired many times a
-- second for the entire tail of every video (confirmed: ~50 invocations
-- over a ~7-8 second window in earlier testing) - each call individually
-- cheap (in_flight short-circuits it once nothing needs refreshing), but
-- concentrating that much repeated polling in exactly the one part of
-- playback with the least buffering slack to absorb any scheduling
-- interference turned out to be the prime suspect for reported audio
-- crackling near the end of every video. A single timer, firing once,
-- removes that repeated-polling pattern entirely while keeping the same
-- refresh outcome.
local refresh_timer = nil

mp.register_event("file-loaded", function()
    in_flight = {}
    prefetch_neighbors()

    if refresh_timer then
        refresh_timer:kill()
        refresh_timer = nil
    end
    local duration = mp.get_property_number("duration", 0)
    if duration > opts.lead_time then
        refresh_timer = mp.add_timeout(duration - opts.lead_time, prefetch_neighbors)
    end
end)

-- Also re-triggers on any playlist mutation - covers an item added while
-- something's already playing (mpv-add, ctrl+v/paste-url, etc., the
-- normal way items actually end up in the queue), which would otherwise
-- never get prefetched since file-loaded already fired before it existed.
--
-- Deliberately observes mpv's built-in "playlist" property natively
-- rather than "playlist-count" (which only reacts to growth) or
-- "playlist-pos" (which a reorder doesn't always change - e.g. swapping
-- the two items *around* the current one leaves its own index the same)
-- - since "playlist" already changes on every mutation regardless of what
-- caused it.
--
-- Suspended for the duration of playlist-manager's "moving" mode (via the
-- ytdl-prefetch-suspend/-resume messages below) rather than left running
-- through it. That mode is keyboard-driven and non-atomic: a single
-- logical N-step move issues N independent playlist-move commands, each
-- mutating this property on its own, so left unsuspended this fired once
-- per keystroke for whatever pair happened to be transiently adjacent at
-- that instant - previously (incorrectly) documented here as "harmless"
-- on the theory that in_flight/is_fresh below absorb it, but those guard
-- repeated calls for the *same* URL, not the genuinely distinct URL pairs
-- a multi-step reorder cycles through, so real yt-dlp subprocesses were
-- being spawned for arrangements that stopped being adjacent moments
-- later. Only this raw observer is gated: file-loaded above and the
-- explicit "ytdl-prefetch-now" message below both reflect a real, settled
-- transition or an explicit request, and must never be suppressed.
local prefetch_suspended = false

mp.register_script_message("ytdl-prefetch-suspend", function()
    prefetch_suspended = true
end)

mp.register_script_message("ytdl-prefetch-resume", function()
    prefetch_suspended = false
end)

mp.observe_property("playlist", "native", function()
    if prefetch_suspended then return end
    prefetch_neighbors()
end)

mp.register_script_message("ytdl-prefetch-now", prefetch_neighbors)
