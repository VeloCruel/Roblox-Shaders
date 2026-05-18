# Cinematic Shader — Automated Setup

Three pieces work together. Run them once each and you're done; the rest is
automatic.

## The pieces

| File | What it does | When you use it |
|---|---|---|
| `CinematicShader.client.lua` | Runtime visuals + auto-FPS adaptive quality | Drop in `StarterPlayer → StarterPlayerScripts`, or paste into a runner. Works in any place you join. |
| `StudioCinematicPlugin.lua` | Bakes cinematic visuals permanently into places you author | Install as Local Plugin in Studio. Click the toolbar button on your own places. |
| `ApplyRobloxSettings.ps1` | Sets Roblox's saved graphics quality to **10 / Manual / 240 FPS cap** | Run once. Roblox must be closed when you run it. |

## What's automated for you

The runtime shader now handles everything that used to require manual setup:

- **In-game Roblox quality check.** On join, the script reads `UserGameSettings.SavedQualityLevel`. If you're on Automatic or quality < 8, a small on-screen toast suggests setting it to Manual / 10 (one click in Roblox's Settings menu, then close the menu).
- **Adaptive quality scaling.** FPS is sampled continuously. If sustained FPS drops below a threshold, the shader auto-downgrades (Ultra → High → Medium → Low). It won't auto-upgrade — if you intentionally set Low for battery / laptop heat, it stays.
  - Ultra at 55+ FPS
  - High at 38–55
  - Medium at 22–38
  - Low under 22
- **Fresnel-inspired reflections.** Wet overlays read their reflectance from camera angle: looking straight down a wet road = subtle, looking down the road at a low angle = full mirror. Updates 12 Hz, only within 350 studs of camera.
- **View-direction sun rays.** Look toward the sun → full god rays. Look away → fades to 0.
- **Auto-focus DoF.** When Cinematic Mode is on, depth-of-field focus point follows a raycast from your camera. Whatever you're looking at stays sharp; far things blur.
- **Weather mood.** Bloom, atmosphere glare, and exposure shift with `Lighting.ClockTime` across 7 mood bands (Dawn / Morning / Midday / Golden / Sunset / Dusk / Night).
- **Day/Night adaptive FX ticker.** Smoothly re-tweens FX every 2 s as the time of day changes — works in places with dynamic sun cycles.

## What the PowerShell script does

`ApplyRobloxSettings.ps1` is a **safe, one-time** helper. It opens the file
Roblox itself writes when you change the in-game graphics slider, and sets the
values to max so you don't have to click through menus every install.

It:
- Backs up your current `GlobalBasicSettings_*.xml` with a timestamp
- Sets `GraphicsQualityLevel` = 10
- Sets `SavedQualityLevel` = QualityLevel10
- Sets `SavedFrameRateLevel` = FrameRate240
- Saves and exits

It does **not**:
- Touch the Roblox executable
- Inject anything into a running process
- Modify game content files
- Run anything alongside Roblox

Hyperion checks the integrity of the running Roblox client, not user-editable
settings files. This is the same file Roblox itself writes — modifying it
manually is no different from clicking the slider in the menu.

## Quick start

1. **Close Roblox** (so the script can write settings without being overwritten on Roblox's exit).
2. Open PowerShell in the `Shaders` folder.
3. Run: `powershell -ExecutionPolicy Bypass -File .\ApplyRobloxSettings.ps1`
4. (Optional) Install `StudioCinematicPlugin.lua` in Studio if you have your own places to enhance.
5. Paste `CinematicShader.client.lua` into a runner / `StarterPlayerScripts` / your client framework — whatever you use.
6. Launch Roblox. The shader will:
   - Print `[UltraShader] Initialized — preset: Enhanced, quality: Ultra`.
   - Show a toast hint if your in-game quality is still below 10.
   - Sample your FPS for 6 s, then start auto-adapting quality if it can't sustain Ultra.

## What you still control via the UI

Press `]` to toggle the Rayfield panel (or the fallback panel if Rayfield can't load):

- **Visuals tab:** Enable, Master Intensity, Quality dropdown (overrides Adaptive), Color Preset dropdown
- **Reflections tab:** Reflection Intensity, Wetness, Re-scan Workspace
- **Effects tab:** Bloom, Vignette, Lens Flare, Weather Mood, Cinematic Mode (FOV + DoF), Auto-Focus DoF, Adaptive Quality, Fresnel Reflections
- **Time tab:** Auto / Day / Night override

## When auto-detection isn't enough

If FPS is great but you want to drop quality manually for a laptop, just open
the panel and pick from the Quality dropdown — that disables the
auto-downgrade for the rest of the session. To re-enable, toggle
**Adaptive Quality** back on in the Effects tab.

## Troubleshooting

- **"Roblox is currently running" from the PS script** — close Roblox fully (check the system tray), then re-run.
- **No `GlobalBasicSettings` file** — launch Roblox once first so it writes the file, close it, then re-run the script.
- **Visuals look unchanged** — your `Lighting.Technology` may be locked to Voxel/Compatibility by the place itself; the script tries to set Future but server scripts can override. Most maps allow it.
- **Frame drops** — Adaptive Quality should catch it within ~5 s. If not, manually pick `Medium` from the Quality dropdown.
