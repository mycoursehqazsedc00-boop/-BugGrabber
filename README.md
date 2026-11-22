# !BugGrabber (Vanilla 1.12.1 / Turtle WoW)

Lightweight Lua error catcher and stack-trace formatter for World of Warcraft 1.12.1 (strict Lua 5.0), designed as a clean, drop-in upgrade over upstream **BugGrabber v2.1.1** with full **BugSack** compatibility.

## Client DLL Requirements

- **Required DLLs:** None. Runs purely on stock WoW 1.12.1 / Turtle WoW Lua 5.0 with zero external DLL dependencies.

## Features

- **Silent Error Capture:** Hooks `ScriptErrors_Message.SetText` and suppresses the default Blizzard error popup (`ScriptErrors.Show`) while preserving `oldset`, `oldshow`, and `olderrorhandler`.
- **Protected Call Logging:** Captures `ADDON_ACTION_BLOCKED` and `ADDON_ACTION_FORBIDDEN` events with addon and function context.
- **Session & Deduplication:** Groups identical errors within the same session using an occurrence counter (`counter`) and timestamp (`time`).
- **SavedVariables Safety:** Enforces the WoW 1.12.1 SavedVariables string-length limit (<= 980 bytes) and configurable history cap (`BugGrabberDB.limit`, 10–100 errors).
- **BugSack Integration:** Buffers early startup errors in `BugGrabber.bugsackErrors` until `BugSack` initializes, and exposes `GetDB`, `GetSave`, `ToggleSave`, `GetLimit`, and `SetLimit` plus `BugGrabber_BugGrabbed` / `BugGrabber_BugGrabbedAgain` AceEvent-2.0 events.
- **Built-in Slash Command:** Always available via `/buggrabber` even without `BugSack`:
  - `/buggrabber <index>` — Print full details for error `<index>`.
  - `/buggrabber list` — List up to the 10 most recent errors with occurrence counts.
  - `/buggrabber status` — Show current session, stored error count, limit, save mode, and `BugSack` detection.
  - `/buggrabber clear` — Clear recorded errors from memory and `BugGrabberDB`.

## What Was Fixed & Improved vs Upstream (v2.1.1)

- **Fixed `<unknown>` Stack Line Loss:** Corrected `msg = line` (which overwrote unrecognized stack lines with an empty string `""`) to `msg = trace` so `(tail call)`, inlined frames, and custom error lines are preserved.
- **Fixed `SaveError` Loop-Suppression Bug:** Passed `looping` explicitly from `GrabError` into `SaveError(message, looping)` instead of reading an undefined global `looping`.
- **Added Re-Entrancy & `nil` Guards:** Added a `grabbing` re-entrancy lock with `pcall` around `SaveError`, `tostring(err or "")`, and 1-argument `GrabError(msg)` fallback so errors inside error handling cannot cause infinite recursion or concatenation crashes.
- **Fixed Dropped Final Trace Line:** Appended `"\n"` before `string_gmatch` iteration so the last line of a stack trace without a trailing newline is never skipped.
- **Fixed `PrintLoadError` Operator Precedence:** Replaced `not type(err) == "table"` / `not type(err.message) == "string"` with `type(...) ~= ...`.
- **Added Forward-Slash Path Support:** Updated stack-trace path patterns (`[^\\/]+[\\/]`) to format both `\` and `/` file paths cleanly.
- **Fixed `AddonLoaded` Order & Limit Enforcement:** Switched `loadErrors` merge from `pairs` to `ipairs` to preserve chronological order and enforced `BugGrabberDB.limit` after merging.
- **Hardened Event & Frame Hooks:** Added `nil`-safe formatting for `ADDON_ACTION_BLOCKED` / `ADDON_ACTION_FORBIDDEN`, trimmed `SetLimit` against the floored `BugGrabberDB.limit`, and guarded `ScriptErrors_Message` / `ScriptErrors` existence.
- **Reduced String Allocations:** Replaced per-line string concatenation in `GrabError` with a reused `traceParts` buffer and `table.concat`.
- **Clean Truncation Marker:** Truncates oversized errors (> 980 bytes) at 970 characters with `\n...  ---` so truncated entries remain clearly marked.

## Credits

- **Original Authors:** Fritti, Rabbit
- **X-Credits:** Rowne, Ramble, kergoth, ckknight
