# Immerse Audio Renderer — Tier 1 Test Harness

Context document for any future Claude session picking up this work. Read this first.

## What this is

A **WAAPI-driven test harness** for the Immerse Audio Renderer Wwise mixer plug-in. Drives every settable property on the plug-in's Effect instance and verifies the change by parsing the runtime debug stream (OutputDebugString) the plug-in emits.

**Tier 1 (this branch — `claude/test-immerse-tier1-waapi`):** WAAPI-only. No UE source modification, no build step required. Works against any UE C++ project with Wwise integration + an auto-played event in the level. Portable.

**Tier 2 (preserved on `claude/test-immerse-audio-plugin-su44W`):** Earlier work that patched the UE project's source to install an actor (`AImmerseStressTestActor`) for performance / stress testing (frame timing, event churn, WAV capture). Kept as the deeper-testing option; not in active development.

## Pipeline (Tier 1)

```
StartGui.ps1 (form)
  -> writes TestScenarios.json from user's selections + cycle count
  -> launches AutoRunAndPush.ps1 inline (so Read-Host for pauseAfter works)

AutoRunAndPush.ps1
  1. DebugStreamListener.ps1 starts (in-process DBWIN_BUFFER reader, no admin)
  2. Wwise auto-launched with TencentRCTest.wproj (or reuses if running)
  3. WAAPI 'ak.wwise.core.getInfo' polled until ready (handles ak.wwise.locked)
  4. Immerse Effect ID resolved by name 'Immerse_Audio_Renderer_(Custom)'
  5. @UserID setProperty fires
  6. UE4Editor.exe launched with '-game -RenderOffscreen -unattended -nopause'
     (level auto-plays an event for continuous audio; no actor required)
  7. ak.wwise.core.remote.getAvailableConsoles polled, ak.wwise.core.remote.connect
  8. Listener tailed for personalized-user-load confirmation
  9. Run-Scenarios.ps1 invoked inline (handles pauseAfter Read-Host)
 10. UE killed; Wwise optionally closed (IMMERSE_CLOSE_WWISE=1)
 11. Generate-HtmlReport.ps1 builds <RunDir>/report.html
 12. Push to GitHub branch (skipped in local-only mode)
 13. GUI opens report.html in default browser
```

## File map (`Tools/`)

| File | Role |
|---|---|
| `StartGui.ps1` | WinForms config; parses ImmerseAudioRenderer.xml; CheckedListBox of parameters; cycle count; close-Wwise checkbox; scenario generator; calls launcher; opens report |
| `StartGui.bat` | Double-click wrapper |
| `AutoRunAndPush.ps1` | Main launcher (~430 lines). All orchestration above. Honors IMMERSE_UPROJECT/IMMERSE_WPROJ/IMMERSE_WWISE_EXE/IMMERSE_USER_ID/IMMERSE_CLOSE_WWISE/IMMERSE_LOCAL_ONLY |
| `Run-Scenarios.ps1` | Generic scenario runner. Per scenario: snapshot listener-log offset, setProperty, poll for expectLog regex within timeoutMs (assertion mode) OR captureSeconds (discovery mode). Supports pauseAfter for interactive verification. Cycles loop. |
| `DebugStreamListener.ps1` | PowerShell + embedded C#. Creates DBWIN_BUFFER + DBWIN_DATA_READY/BUFFER_READY events, drains OutputDebugString to a log file. Replaces Sysinternals DbgView (which needed admin and popped a modal). |
| `Generate-HtmlReport.ps1` | Reads scenario_results.json + summary, writes a self-contained styled HTML report with status badges and expandable detail sections |
| `Bootstrap.ps1` | Entry point for fresh-machine setup (fetches all scripts via api.github.com/repos/.../contents/...?ref=<branch> to bypass raw.gh caching). Optional: not needed when iterating from a local clone. |
| `TestScenarios.json` | GUI-generated each run. Overwritten by StartGui. |
| `ImmerseAudioRenderer.xml` | Bundled copy of the plug-in property metadata. GUI prefers the user's Wwise install copy when present; falls back to this. |

## Confirmed log signatures (assertion mode)

| Property | Regex (`<value>` substituted at scenario-gen time) | Notes |
|---|---|---|
| `EnableImmerse` | `Immerse_EnableImmerse\s+inMode:\s*<value>\b` | value 0 → inMode:0 (off); value 1 (true) → inMode:1 if ConvType=1, inMode:2 if ConvType=0. Harness forces ConvType=0 before EHM transitions for determinism. |
| `ConvolutionType` | `Immerse_EnableImmerse\s+inMode:\s*<value>\b` | XML enum 0=Universal, 1=Personalized. Same regex but mapping is 0→inMode:2, 1→inMode:1. Harness encodes accordingly. |
| `HeadphoneEq` | `Immerse_EnableHPEQ\s+inHeadset:\s*<value>\b` | Fires `Immerse_EnableHPEQ` on direct setter |
| `FieldOfView` | `Immerse_SetSpeakerPlacement\s+inSpeakerPlacement:\s*<value>\b` | XML enum {1=Default, 2=Narrow, 3=Wide} |
| `Tuning` | `Immerse_SetTuning.+?inHrirTuning:\s*<value>\b` | Only first 4 values (Extraction_01/Warfare_01/Campaign_01/VoiceChat_01) — the other 16 enum entries aren't exposed in the plug-in UI under a given BusContent |

## Discovery-mode (no per-value log signature known)

- **`BusContent`** — pushes through at runtime (audio differs subtly), but the only correlatable log line is `DecryptMultiSofaData()` with a project-specific `dataOffset` (binary offset into the encrypted SOFA file: Extraction=1039, Warfare=440678, Campaign=880317, VoiceChat=1319956 in our project). Brittle across plug-in versions, so left as discovery. Worth asking the dev team for a dedicated log line.

## Property XML quirks

- `ConvolutionType` only declares `{0: Universal, 1: Personalized}` in its enum. Setting value `2` returns HTTP 500 (`'The value does not conform to the property's restriction.'`). If the plug-in supports more modes internally, they're not WAAPI-reachable today.
- `HeadphoneEq` enum is sparse device codes: `0 (NONE), 102 (Universal Closed Back), 104 (Universal Open Back), 26 (Cloud Alpha), 16 (Arctis Nova Pro Wireless), 38 (G535), 23 (Black Shark V2 Pro Wireless), 21 (A50), 80 (MMX 300), 66 (HS80 RGB Wireless)`. Value `1` is NOT in the enum (don't assume contiguous).
- `Tuning` XML has 20 entries but the plug-in UI exposes only 4 at a time (filtered by current BusContent). XML doesn't carry the BC → Tuning mapping. Harness trims to first 4 entries by index — those happen to be the canonical "primary tuning per BusContent" (names match BC values 1:1).
- `FieldOfView` enum starts at 1 (not 0): `{1: Default, 2: Narrow, 3: Wide}`.
- `HeadTrackingEnabled` and `HeadTrackingCameraId` are NOT in the plug-in UI; harness filters them via `$hiddenProperties` array in `StartGui.ps1`.
- `UserID` is in the plug-in UI but the harness has a dedicated form field for it; also filtered from the parameter selector to avoid duplication. UserID-change tests are intentionally not in the auto-generated cycle (operator decided to verify manually first).

## Personalized-dependent properties

`HeadphoneEq`, `Tuning`, `FieldOfView`, `BusContent` require `EnableImmerse=true` AND `ConvolutionType=1 (Personalized)` AND the user's Immerse account must have a personalized profile already loaded (license + HRTF data on the local store). Without it, setProperty returns HTTP 500.

The scenario generator detects when any personalized-dependent property is selected and emits a prereq block (EHM on, ConvType=1) once before the dependent tests.

## Key technical gotchas (most worth knowing)

1. **No-op setProperty doesn't fire any log line.** Wwise doesn't push if the value matches the current state. All assertions are preceded by a `captureSeconds=1` setup scenario that forces the opposite value first.

2. **PowerShell single-quoted strings don't interpret backslashes.** `'\{value\}'` is 9 literal chars; the regex `\{value\}` matches the 7-char `{value}`. Those don't intersect — substitution silently fails. Use `<value>` as the placeholder (no regex metachars). Bit me earlier; baked into `Run-Scenarios.ps1` now.

3. **`ProcessStartInfo.ArgumentList`** is .NET Core 2.1+ only. Not available on Windows PowerShell 5.1's .NET Framework. Use `& git @GitArgs 2>$tempErr` splatting form (see `Invoke-Git` in `AutoRunAndPush.ps1`).

4. **GitHub `raw.githubusercontent.com` caches aggressively** — even with cache-buster query params and `Cache-Control: no-cache` headers, it can serve stale content for ~10+ minutes after a push. Bootstrap.ps1 uses the Contents API (`api.github.com/repos/.../contents/.../?ref=<branch>`) which has different caching. Don't go back to raw.

5. **`git clone --single-branch <other>`** restricts the remote refspec. Subsequent `git fetch origin <newbranch>` won't update `refs/remotes/origin/<newbranch>` and `checkout -B <newbranch> origin/<newbranch>` fails with "unknown revision." Fix: `git remote set-branches origin '*'` + explicit refspec on fetch (`+refs/heads/<branch>:refs/remotes/origin/<branch>`). See `Init-ResultsRepo`.

6. **WAAPI `ak.wwise.locked`**: any open modal in Wwise (including ones on a disconnected monitor) blocks all WAAPI calls. The `AutoRunAndPush` waits 60s for the lock to clear and warns each iteration. If you can't see a modal but it persists, use Win32 EnumWindows to find off-screen child windows of the Wwise process.

7. **`auto remote-connect` filter**: don't filter on UE project name (e.g. `testTP`) — it makes the launcher non-portable. Filter on `platform == 'Windows' && host in {127.0.0.1, localhost, $env:COMPUTERNAME}`.

8. **Wwise property push is live to a connected runtime**, but the value mapping isn't always 1:1 with the WAAPI enum. ConvolutionType is the cleanest example: WAAPI value 0 (Universal) produces `inMode:2`, WAAPI value 1 (Personalized) produces `inMode:1`. The harness's assertion regex encodes the mapping explicitly.

9. **The level needs an auto-played Wwise event** for there to be any audio for the Immerse FX to process. In our test project the level has a Blueprint with an AkComponent set to auto-play. Without an audio source flowing through the bus, `Immerse_EnableHPEQ` and friends still fire log lines (parameter callbacks fire on property change regardless of audio), but you won't be able to audibly verify changes.

## Dev team shopping list (for the Embody team)

In rough priority order. Each is a small XML/log change on their side that materially improves the harness.

1. **`<UserInterface Hidden="true"/>` marker on properties not shown in the plug-in UI** (HeadTrackingEnabled, HeadTrackingCameraId today). Lets the GUI's property-list reflect the plug-in UI automatically. Our XML parser already honors `Hidden="true"`, `Hide="true"`, and `Visible="false"` attributes.

2. **BusContent → Tuning mapping in XML.** Each Tuning value should declare which BusContent it applies to (e.g. `<Value DisplayName="Extraction_01" RequiresBusContent="0">0</Value>`). Removes our "first 4 only" heuristic.

3. **Dedicated log line for BusContent changes** (e.g. `___IMMERSEENGINE___ Immerse_SetBusContent inBusContent:<N>`). Today BC pushes work but only re-emit the full BMAP data, which can't be used for per-value assertions.

4. **`ConvolutionType = 2` (Universal mode) availability via WAAPI.** Currently rejected at the Wwise schema layer because the XML enum only declares 0 and 1. If universal mode is supposed to be settable via authoring, add it.

## Environment variables

| Var | Effect |
|---|---|
| `IMMERSE_USER_ID` | Immerse account ID (string, e.g. `kevin_tencenttest1_emb`). Set on `@UserID`. |
| `IMMERSE_UPROJECT` | Path to a `.uproject` file (or its containing folder). Overrides ScriptDir parent. |
| `IMMERSE_WPROJ` | Path to a `.wproj` file. |
| `IMMERSE_WWISE_EXE` | Path to `Wwise.exe`. |
| `IMMERSE_CLOSE_WWISE` | `'1'` to close Wwise at run end. |
| `IMMERSE_LOCAL_ONLY` | `'1'` to skip GitHub clone + push regardless of `.github_token` presence. (Auto-set if `.github_token` missing.) |
| `IMMERSE_REMOTE_HOLD` | `'1'` to park the Tier-2 actor (if present in the UE project) — prevents its plan from auto-running. Internal to AutoRunAndPush; auto-set. |

## Local dev workflow (Pepe / anyone without push access)

1. Clone the repo: `git clone https://github.com/kevinboettger/kevinboettger.git C:\repos\kevinboettger`
2. `git checkout claude/test-immerse-tier1-waapi`
3. No `.github_token` needed → harness runs in local-only mode automatically.
4. Set env vars for paths (or use GUI Browse buttons):
   ```powershell
   $env:IMMERSE_UPROJECT  = '<path>\testTP.uproject'
   $env:IMMERSE_WPROJ     = '<path>\TencentRCTest.wproj'
   $env:IMMERSE_WWISE_EXE = 'C:\Program Files (x86)\Audiokinetic\Wwise2019.2.15.7667\Authoring\x64\Release\bin\Wwise.exe'
   $env:IMMERSE_USER_ID   = 'kevin_tencenttest1_emb'
   ```
5. Run: `& 'C:\repos\kevinboettger\Tools\StartGui.ps1'` (or double-click `StartGui.bat`)
6. Iterate: edit `Tools/*.ps1`, re-run. Changes take effect immediately (no Bootstrap fetch).
7. Results land at `Tools\_results_repo\immerse_runs\<RunId>\` (gitignored).
8. HTML report auto-opens at end.

To switch to push mode later: generate a Classic PAT with `repo` scope (must be a collaborator), save to `Tools\.github_token` (one line, no trailing newline). Harness auto-detects.

## Open next-phase items

- **BusContent assertion**: pending dev-team feedback OR accepting `DecryptMultiSofaData` offset matching with project-specific data.
- **Multi-user runs**: loop the harness with a list of `IMMERSE_USER_ID` values. UserID-change verification still pending.
- **Multi-instance runs**: parallel UE processes targeting different bus/FX instance combinations.
- **GUI refinements**: per-value selection (test specific HPEQ profiles, not all 9), result trend graphs across runs, etc.
- **Tier 2 revival**: when stress / performance testing is needed (frame timing, churn, WAV capture).

## Branch reference

- `main` / `master` — not relevant to this work
- `claude/test-immerse-audio-plugin-su44W` — Tier 2 baseline (actor + source patches), preserved
- `claude/test-immerse-tier1-waapi` — **active branch**

## Session continuity hint for the next Claude

If you're a new Claude session opened in this repo, first command worth running to orient yourself:

```bash
git log --oneline -30
```

The commit subjects narrate the project's evolution. The most-recent commits document the latest decisions and trade-offs.
