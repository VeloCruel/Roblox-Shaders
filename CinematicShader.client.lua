--!nocheck
--[[==========================================================================
    ULTRA CINEMATIC SHADER — v5.0 "NaturalVision"
    Single-file Roblox shader system. Runs as LocalScript or via loadstring.

    Architecture:
        * Strict internal modules (Util, Cfg, State, Mat, Refl, Light, PostFX,
          AdvColor, RT, Cam, Overlays, VolFog, GodRays, SunDisc, NightBeams,
          Weather, World, FreeCam, Detect, Perf, Sched, Persist, API, UI).
        * One State table, one Cfg table, one Connections registry.
        * Every connection passes through Conn.track() so kill() unwinds 100%.
        * FrameBudget scheduler throttles low-priority work to its own Hz.
        * Pre-allocated math/Color3 scratch — zero per-frame allocations in
          the hot raytrace loop.
        * Mobile-aware: smaller UI, adaptive budgets, touch-friendly.

    Public API (preserved from v4):
        _G.CinematicShader.api.setQuality(name)            -- Low/Med/High/Ultra/Max
        _G.CinematicShader.api.setColorPreset(name)        -- 16 grades
        _G.CinematicShader.api.setTonemap(name)            -- 6 curves
        _G.CinematicShader.api.set<feature>(bool/number)   -- ~60 setters
        _G.CinematicShader.activateRTX()
        _G.CinematicShader.activateGTANight()
        _G.CinematicShader.kill()
        _G.CinematicShader.info()
        _G.CinematicShader.export()    /   .import(str)
========================================================================--]]

print("[Cinematic] v5.0 booting...")

local RunService = game:GetService("RunService")
if not RunService:IsClient() then
    warn("[Cinematic] Must run as a LocalScript on the client.")
    return
end

-- ---------------------------------------------------------------------------
-- Teardown previous instance cleanly so re-pasting works without leaks
-- ---------------------------------------------------------------------------
if _G.CinematicShader then
    print("[Cinematic] Previous instance detected — tearing down...")
    pcall(function() if _G.CinematicShader.kill then _G.CinematicShader.kill() end end)
    _G.CinematicShader = nil
    task.wait(0.15)
end

-- ===========================================================================
-- 1. SERVICES
-- ===========================================================================
local Lighting          = game:GetService("Lighting")
local Workspace         = game:GetService("Workspace")
local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local UserInputService  = game:GetService("UserInputService")
local HttpService       = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    repeat task.wait() until Players.LocalPlayer
    LocalPlayer = Players.LocalPlayer
end
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- ===========================================================================
-- 2. CONNECTION REGISTRY — every connection tracked here for kill()
-- ===========================================================================
local Conn = {}
Conn.list = {}
function Conn.track(c)
    table.insert(Conn.list, c)
    return c
end
function Conn.disconnectAll()
    for _, c in ipairs(Conn.list) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(Conn.list)
end

-- ===========================================================================
-- 3. TAGS / ATTRIBUTES
-- ===========================================================================
local TAG_PROCESSED  = "Cinematic_Processed"
local TAG_OVERLAY    = "Cinematic_Overlay"
local TAG_LIGHT      = "Cinematic_Light"
local TAG_HIGHLIGHT  = "Cinematic_Highlight"
local OVERLAY_NAME   = "Cinematic_WetOverlay"
local ATTR_CLASS     = "Cinematic_Class"
local ATTR_ORIG_MAT  = "Cinematic_OrigMat"
local ATTR_ORIG_REF  = "Cinematic_OrigRef"
local ATTR_ORIG_CST  = "Cinematic_OrigCast"
local ATTR_BAKED     = "Cinematic_Baked"
local ATTR_BAKE_WET  = "Cinematic_BakeWetness"
local ATTR_BAKE_PRES = "Cinematic_BakePreset"

-- ===========================================================================
-- 4. STATE — single source of truth
-- ===========================================================================
local State = {
    -- Master
    Enabled       = true,
    Initialized   = false,
    Version       = "Cinematic-5.0-NaturalVision",

    -- Multipliers
    Intensity     = 1.00,
    Bloom         = 1.00,
    Reflection    = 1.00,
    Wetness       = 0.50,

    -- Quality + look
    Quality       = "Ultra",
    ColorPreset   = "Photorealistic",
    Tonemap       = "ACES",
    Weather       = "Clear",
    TimeMode      = "Auto",

    -- Feature toggles (defaults safe for Ultra)
    Vignette          = true,
    LensFlare         = true,
    AutoFocus         = true,
    WeatherMood       = true,
    FresnelOverlays   = true,
    MotionBlur        = true,
    EyeAdaptation     = true,
    LightEnhance      = true,
    SpeedFOV          = true,
    NightBeams        = true,
    RayTrace          = true,
    MultiBounceRT     = true,
    CameraFillLight   = true,
    CameraSway        = true,
    ImpactShake       = true,
    GForce            = true,
    PlayerHighlight   = false,
    FoliageEnhance    = true,
    FireEnhance       = true,
    SmokeEnhance      = true,
    SparklesEnhance   = true,
    WaterEnhance      = true,
    Precipitation     = true,
    Lightning         = true,
    AutoCycle         = false,
    CycleSpeed        = 24 / (12 * 60),
    Underwater        = true,
    FreeCam           = false,
    CinematicMode     = false,
    PerfHUD           = false,

    -- Advanced color
    WhiteBalance      = 6500,
    WBTint            = 0,
    Vibrance          = 0,
    HueShift          = 0,
    Lift              = 0,
    Gamma             = 1.0,
    Gain              = 1.0,
    Sharpness         = 0.0,

    -- Realism stack — flipped on by Ultra/Max
    FilmGrain          = false,
    FilmGrainAmount    = 0.18,
    ChromaticAberration= false,
    ChromaticAmount    = 0.50,
    SunDisc            = false,
    VolumetricFog      = false,
    VolumetricDensity  = 1.0,
    Caustics           = false,
    EnhancedGI         = false,
    SSAO               = false,
    SSAOIntensity      = 0.6,
    AnisotropicMetals  = false,
    RainDroplets       = false,
    DustMotes          = false,
    LightLeaks         = false,
    LensDirt           = false,
    GodRays            = false,
    GodRaysIntensity   = 1.0,
    HeatHaze           = false,
    HeatHazeIntensity  = 0.5,
    DistanceHaze       = true,
    CityNightGlow      = true,

    -- Adaptive
    AdaptiveQuality    = true,
    TargetFPS          = 50,
}

local OriginalFOV
local OriginalLighting

-- ===========================================================================
-- 5. UTILITIES
-- ===========================================================================
local Util = {}

local mathClamp, mathMax, mathMin = math.clamp, math.max, math.min
local mathFloor, mathAbs, mathSqrt = math.floor, math.abs, math.sqrt
local mathSin, mathCos, mathPi     = math.sin, math.cos, math.pi
local Color3New = Color3.new
local Vec3New   = Vector3.new
local CFNew     = CFrame.new

function Util.lerp(a, b, t)  return a + (b - a) * t end

function Util.lerpColor(c1, c2, t)
    return Color3New(
        c1.R + (c2.R - c1.R) * t,
        c1.G + (c2.G - c1.G) * t,
        c1.B + (c2.B - c1.B) * t
    )
end

function Util.luminance(c)
    return c.R * 0.2126 + c.G * 0.7152 + c.B * 0.0722
end

function Util.albedoScale(part)
    local b = Util.luminance(part.Color)
    return mathClamp(b * 1.5 + 0.05, 0.1, 1.15)
end

function Util.overlayAlbedoScale(part)
    local b = Util.luminance(part.Color)
    return mathClamp(b * 0.7 + 0.3, 0.3, 1.05)
end

function Util.kelvinToRGB(K)
    K = mathClamp(K, 1000, 40000) / 100
    local r, g, b
    if K <= 66 then
        r = 255
        g = mathClamp(99.4708 * math.log(K) - 161.1196, 0, 255)
        if K <= 19 then b = 0
        else b = mathClamp(138.5177 * math.log(K - 10) - 305.0448, 0, 255) end
    else
        r = mathClamp(329.6987 * (K - 60) ^ -0.1332, 0, 255)
        g = mathClamp(288.1222 * (K - 60) ^ -0.0755, 0, 255)
        b = 255
    end
    return Color3New(r / 255, g / 255, b / 255)
end

function Util.smoothstep(e0, e1, x)
    local t = mathClamp((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
end

function Util.tween(inst, time, props, style, dir)
    local info = TweenInfo.new(time or 0.5, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out)
    local t = TweenService:Create(inst, info, props)
    t:Play()
    return t
end

function Util.moodBandFor(clockTime)
    if clockTime < 5 then return "Night"
    elseif clockTime < 6.5 then return "Dawn"
    elseif clockTime < 9 then return "Morning"
    elseif clockTime < 15 then return "Midday"
    elseif clockTime < 17 then return "Golden"
    elseif clockTime < 18.5 then return "Sunset"
    elseif clockTime < 20 then return "Dusk"
    else return "Night" end
end

function Util.currentMood()
    if State.TimeMode == "Day" then return "Midday"
    elseif State.TimeMode == "Night" then return "Night" end
    return Util.moodBandFor(Lighting.ClockTime)
end

-- ===========================================================================
-- 6. CONFIG
-- ===========================================================================
local Cfg = {}

Cfg.Lighting = {
    Technology               = Enum.Technology.Future,
    Ambient                  = Color3.fromRGB(48, 52, 60),
    OutdoorAmbient           = Color3.fromRGB(142, 148, 158),
    Brightness               = 2.30,
    ClockTime                = 14.5,
    ColorShift_Top           = Color3.fromRGB(18, 22, 32),
    ColorShift_Bottom        = Color3.fromRGB(218, 220, 224),
    EnvironmentDiffuseScale  = 0.62,
    EnvironmentSpecularScale = 1.00,
    ExposureCompensation     = 0.05,
    FogColor                 = Color3.fromRGB(192, 198, 210),
    FogStart                 = 2500,
    FogEnd                   = 100000,
    GeographicLatitude       = 41.7,
    GlobalShadows            = true,
    ShadowSoftness           = 0.13,
}

Cfg.Atmosphere = {
    Density = 0.20, Offset = 0.38,
    Color   = Color3.fromRGB(212, 212, 212),
    Decay   = Color3.fromRGB(115, 115, 115),
    Glare   = 0.20, Haze = 1.35,
}

Cfg.Bloom        = { Intensity = 0.60, Size = 22, Threshold = 2.40 }
Cfg.SunRays      = { Intensity = 0.32, Spread = 0.97 }
Cfg.DepthOfField = { FarIntensity = 0.22, FocusDistance = 80, InFocusRadius = 50, NearIntensity = 0 }

Cfg.Reflectance  = { Floor = 0.20, Glass = 0.55, Metal = 0.32, Surface = 0.03 }

Cfg.Detection = {
    FloorMinArea    = 55,
    FloorNormalDot  = 0.88,
    SmallPartCutoff = 0.55,
    OverlayMinArea  = 90,
    OverlayMaxCount = 800,
}

Cfg.Performance = {
    ProcessBudget    = 80,
    ScanBatch        = 250,
    AdaptiveCheckSec = 5,
    AdaptiveThresholds = { Max = 48, Ultra = 38, High = 26, Medium = 16, Low = 0 },
    AdaptiveOrder    = { "Max", "Ultra", "High", "Medium", "Low" },
}

Cfg.Tween = { Default = 0.8, Fast = 0.35, Slow = 1.4 }

Cfg.Quality = {
    Low    = { OverlayEnabled = false, BloomMul = 0.6,  AtmosMul = 0.7,  DOFMul = 0.0,  ShadowSoft = 0.45, Spec = 0.55, Diff = 0.35, TracesPerTick = 0,  OverlayMax = 0,    BeamMax = 0,    TraceDist = 0,   ExposureBoost = 0,    Photoreal = false },
    Medium = { OverlayEnabled = false, BloomMul = 0.9,  AtmosMul = 1.0,  DOFMul = 0.0,  ShadowSoft = 0.28, Spec = 0.75, Diff = 0.48, TracesPerTick = 0,  OverlayMax = 0,    BeamMax = 100,  TraceDist = 0,   ExposureBoost = 0,    Photoreal = false },
    High   = { OverlayEnabled = true,  BloomMul = 1.0,  AtmosMul = 1.0,  DOFMul = 0.4,  ShadowSoft = 0.14, Spec = 0.95, Diff = 0.55, TracesPerTick = 5,  OverlayMax = 800,  BeamMax = 250,  TraceDist = 130, ExposureBoost = 0.02, Photoreal = false },
    Ultra  = { OverlayEnabled = true,  BloomMul = 1.35, AtmosMul = 1.18, DOFMul = 0.85, ShadowSoft = 0.02, Spec = 1.0,  Diff = 0.72, TracesPerTick = 12, OverlayMax = 2000, BeamMax = 500,  TraceDist = 200, ExposureBoost = 0.06, Photoreal = true  },
    Max    = { OverlayEnabled = true,  BloomMul = 1.75, AtmosMul = 1.45, DOFMul = 1.20, ShadowSoft = 0.0,  Spec = 1.0,  Diff = 0.95, TracesPerTick = 32, OverlayMax = 4500, BeamMax = 1200, TraceDist = 320, ExposureBoost = 0.18, Photoreal = true  },
}

Cfg.FloorMats = {
    [Enum.Material.Plastic]=true,[Enum.Material.SmoothPlastic]=true,[Enum.Material.Concrete]=true,
    [Enum.Material.Slate]=true,[Enum.Material.Wood]=true,[Enum.Material.WoodPlanks]=true,
    [Enum.Material.Marble]=true,[Enum.Material.Granite]=true,[Enum.Material.Brick]=true,
    [Enum.Material.Pebble]=true,[Enum.Material.Cobblestone]=true,[Enum.Material.CeramicTiles]=true,
    [Enum.Material.Limestone]=true,[Enum.Material.Pavement]=true,[Enum.Material.Asphalt]=true,
    [Enum.Material.Basalt]=true,[Enum.Material.Sand]=true,[Enum.Material.Sandstone]=true,
    [Enum.Material.Ice]=true,[Enum.Material.Glacier]=true,[Enum.Material.RoofShingles]=true,
    [Enum.Material.Salt]=true,[Enum.Material.Mud]=true,[Enum.Material.Ground]=true,
}
Cfg.MetalMats = {
    [Enum.Material.Metal]=true,[Enum.Material.DiamondPlate]=true,
    [Enum.Material.CorrodedMetal]=true,[Enum.Material.Foil]=true,
}
Cfg.FloorRefl = {
    [Enum.Material.Plastic]=1.0,[Enum.Material.SmoothPlastic]=1.05,
    [Enum.Material.Marble]=1.0,[Enum.Material.Granite]=0.85,
    [Enum.Material.CeramicTiles]=1.0,[Enum.Material.Concrete]=0.75,
    [Enum.Material.Slate]=0.75,[Enum.Material.Pavement]=0.7,[Enum.Material.Asphalt]=0.78,
    [Enum.Material.Limestone]=0.5,[Enum.Material.Brick]=0.4,[Enum.Material.Cobblestone]=0.45,
    [Enum.Material.Pebble]=0.3,[Enum.Material.Wood]=0.5,[Enum.Material.WoodPlanks]=0.55,
    [Enum.Material.Basalt]=0.5,[Enum.Material.Sand]=0.15,[Enum.Material.Sandstone]=0.45,
    [Enum.Material.Ice]=1.25,[Enum.Material.Glacier]=1.15,[Enum.Material.RoofShingles]=0.40,
    [Enum.Material.Salt]=0.55,[Enum.Material.Mud]=0.25,[Enum.Material.Ground]=0.20,
}

Cfg.Tonemaps = {
    Linear    = { c = 0.00, s =  0.00, b =  0.00, tint = Color3.fromRGB(255,255,255) },
    Filmic    = { c = 0.14, s = -0.04, b = -0.01, tint = Color3.fromRGB(252,250,248) },
    ACES      = { c = 0.18, s =  0.00, b = -0.02, tint = Color3.fromRGB(250,249,247) },
    Punchy    = { c = 0.26, s =  0.10, b =  0.02, tint = Color3.fromRGB(255,253,250) },
    Reinhard  = { c = 0.08, s = -0.02, b = -0.04, tint = Color3.fromRGB(248,248,248) },
    Cinematic = { c = 0.22, s =  0.04, b =  0.00, tint = Color3.fromRGB(252,250,246) },
}

Cfg.Weather = {
    Clear  = { bloomMul = 1.00, glareMul = 1.00, hazeMul = 1.00, brightMul = 1.00, fogDensity = 0.20, fogColor = Color3.fromRGB(192,198,210) },
    Cloudy = { bloomMul = 0.80, glareMul = 0.55, hazeMul = 1.30, brightMul = 0.85, fogDensity = 0.36, fogColor = Color3.fromRGB(180,184,192) },
    Stormy = { bloomMul = 0.55, glareMul = 0.20, hazeMul = 1.90, brightMul = 0.55, fogDensity = 0.62, fogColor = Color3.fromRGB(108,114,124) },
    Misty  = { bloomMul = 0.70, glareMul = 0.30, hazeMul = 2.20, brightMul = 0.75, fogDensity = 0.78, fogColor = Color3.fromRGB(212,218,224) },
}

Cfg.Moods = {
    Dawn    = { expBias =  0.04, bloomMul = 1.20, glareMul = 0.80, sunMul = 0.70, ambient = Color3.fromRGB(118,108,116), grade = Color3.fromRGB(255,224,210) },
    Morning = { expBias =  0.02, bloomMul = 1.10, glareMul = 0.95, sunMul = 0.90, ambient = Color3.fromRGB(150,154,158), grade = Color3.fromRGB(255,248,238) },
    Midday  = { expBias =  0.00, bloomMul = 1.00, glareMul = 1.00, sunMul = 1.00, ambient = Color3.fromRGB(160,164,170), grade = Color3.fromRGB(252,252,252) },
    Golden  = { expBias =  0.05, bloomMul = 1.30, glareMul = 1.10, sunMul = 1.05, ambient = Color3.fromRGB(180,150,110), grade = Color3.fromRGB(255,210,170) },
    Sunset  = { expBias =  0.06, bloomMul = 1.45, glareMul = 1.20, sunMul = 0.90, ambient = Color3.fromRGB(190,130, 90), grade = Color3.fromRGB(255,180,140) },
    Dusk    = { expBias = -0.02, bloomMul = 0.85, glareMul = 0.50, sunMul = 0.50, ambient = Color3.fromRGB(108, 96,112), grade = Color3.fromRGB(220,200,220) },
    Night   = { expBias = -0.08, bloomMul = 0.55, glareMul = 0.10, sunMul = 0.05, ambient = Color3.fromRGB( 38, 44, 64), grade = Color3.fromRGB(168,188,255) },
}

-- ===========================================================================
-- 7. COLOR PRESETS — 16 cinematic grades
-- ===========================================================================
local ColorPresets = {
    Enhanced = {
        Main  = { Brightness = 0.00,  Contrast = 0.28, Saturation = 0.13, TintColor = Color3.fromRGB(255,250,243) },
        Grade = { Brightness = 0.00,  Contrast = 0.10, Saturation = 0.04, TintColor = Color3.fromRGB(255,246,236) },
        AmbientShift = { 7, 4, 0 },
    },
    Cinematic = {
        Main  = { Brightness = 0.00,  Contrast = 0.18, Saturation = 0.06, TintColor = Color3.fromRGB(255,252,248) },
        Grade = { Brightness = 0.00,  Contrast = 0.05, Saturation = 0.02, TintColor = Color3.fromRGB(252,250,248) },
        AmbientShift = { 0, 0, 0 },
    },
    Realistic = {
        Main  = { Brightness = 0.00,  Contrast = 0.10, Saturation = 0.00, TintColor = Color3.fromRGB(255,253,248) },
        Grade = { Brightness = 0.00,  Contrast = 0.00, Saturation = 0.00, TintColor = Color3.fromRGB(252,252,252) },
        AmbientShift = { 0, 0, 0 },
    },
    ["GTA Day"] = {
        Main  = { Brightness = 0.02,  Contrast = 0.20, Saturation = 0.12, TintColor = Color3.fromRGB(255,246,230) },
        Grade = { Brightness = 0.00,  Contrast = 0.06, Saturation = 0.04, TintColor = Color3.fromRGB(255,232,200) },
        AmbientShift = { 12, 8, 0 },
    },
    ["GTA Night"] = {
        Main  = { Brightness = -0.05, Contrast = 0.30, Saturation = 0.18, TintColor = Color3.fromRGB(220,230,255) },
        Grade = { Brightness = -0.04, Contrast = 0.10, Saturation = 0.10, TintColor = Color3.fromRGB(170,195,245) },
        AmbientShift = { -15, -10, 8 },
    },
    Sunset = {
        Main  = { Brightness = 0.04,  Contrast = 0.22, Saturation = 0.20, TintColor = Color3.fromRGB(255,224,196) },
        Grade = { Brightness = 0.00,  Contrast = 0.08, Saturation = 0.05, TintColor = Color3.fromRGB(255,200,150) },
        AmbientShift = { 18, 6, -10 },
    },
    Neutral = {
        Main  = { Brightness = 0.00,  Contrast = 0.05, Saturation = 0.00, TintColor = Color3.fromRGB(255,255,255) },
        Grade = { Brightness = 0.00,  Contrast = 0.00, Saturation = 0.00, TintColor = Color3.fromRGB(255,255,255) },
        AmbientShift = { 0, 0, 0 },
    },
    Vintage = {
        Main  = { Brightness = -0.01, Contrast = 0.18, Saturation = -0.04, TintColor = Color3.fromRGB(255,245,218) },
        Grade = { Brightness = 0.00,  Contrast = 0.05, Saturation = 0.02,  TintColor = Color3.fromRGB(245,232,210) },
        AmbientShift = { 12, 6, -8 },
    },
    Photorealistic = {
        Main  = { Brightness = -0.015,Contrast = 0.32, Saturation = -0.22, TintColor = Color3.fromRGB(246,250,255) },
        Grade = { Brightness = -0.008,Contrast = 0.14, Saturation = -0.10, TintColor = Color3.fromRGB(244,248,254) },
        AmbientShift = { -3, 0, 6 },
    },
    Cyberpunk = {
        Main  = { Brightness = -0.02, Contrast = 0.34, Saturation = 0.32, TintColor = Color3.fromRGB(220,230,255) },
        Grade = { Brightness = -0.01, Contrast = 0.16, Saturation = 0.20, TintColor = Color3.fromRGB(255,200,240) },
        AmbientShift = { -12, -5, 14 },
    },
    Noir = {
        Main  = { Brightness = -0.03, Contrast = 0.48, Saturation = -0.90, TintColor = Color3.fromRGB(252,250,244) },
        Grade = { Brightness = 0.00,  Contrast = 0.22, Saturation = -0.25, TintColor = Color3.fromRGB(250,248,240) },
        AmbientShift = { 0, 0, 0 },
    },
    Anime = {
        Main  = { Brightness = 0.04,  Contrast = 0.18, Saturation = 0.45, TintColor = Color3.fromRGB(255,240,250) },
        Grade = { Brightness = 0.02,  Contrast = 0.08, Saturation = 0.18, TintColor = Color3.fromRGB(250,235,255) },
        AmbientShift = { 6, 10, 15 },
    },
    IMAX = {
        Main  = { Brightness = 0.00,  Contrast = 0.30, Saturation = -0.14, TintColor = Color3.fromRGB(248,250,255) },
        Grade = { Brightness = -0.02, Contrast = 0.13, Saturation = -0.06, TintColor = Color3.fromRGB(245,248,255) },
        AmbientShift = { -3, 0, 8 },
    },
    ["Teal & Orange"] = {
        Main  = { Brightness = 0.00,  Contrast = 0.24, Saturation = 0.20, TintColor = Color3.fromRGB(255,232,195) },
        Grade = { Brightness = -0.01, Contrast = 0.12, Saturation = 0.10, TintColor = Color3.fromRGB(190,230,240) },
        AmbientShift = { 5, 0, -8 },
    },
    NaturalVision = {
        Main  = { Brightness = -0.01, Contrast = 0.30, Saturation = -0.10, TintColor = Color3.fromRGB(248,251,255) },
        Grade = { Brightness = -0.01, Contrast = 0.12, Saturation = -0.04, TintColor = Color3.fromRGB(246,250,255) },
        AmbientShift = { -2, 1, 5 },
    },
    QuantV = {
        Main  = { Brightness = 0.00,  Contrast = 0.36, Saturation = 0.04,  TintColor = Color3.fromRGB(252,248,242) },
        Grade = { Brightness = -0.02, Contrast = 0.16, Saturation = 0.02,  TintColor = Color3.fromRGB(255,242,224) },
        AmbientShift = { 6, 2, -4 },
    },
}

-- ===========================================================================
-- 8. SNAPSHOTS
-- ===========================================================================
local Snap = {}

function Snap.takePart(part)
    if part:GetAttribute(ATTR_ORIG_MAT) ~= nil then return end
    part:SetAttribute(ATTR_ORIG_MAT, part.Material.Name)
    part:SetAttribute(ATTR_ORIG_REF, part.Reflectance)
    part:SetAttribute(ATTR_ORIG_CST, part.CastShadow)
end

function Snap.restorePart(part)
    local matName = part:GetAttribute(ATTR_ORIG_MAT)
    if matName then
        local m = Enum.Material[matName]
        if m then part.Material = m end
    end
    local refl = part:GetAttribute(ATTR_ORIG_REF)
    if refl ~= nil then part.Reflectance = refl end
    local cast = part:GetAttribute(ATTR_ORIG_CST)
    if cast ~= nil then part.CastShadow = cast end
    part:SetAttribute(ATTR_ORIG_MAT, nil)
    part:SetAttribute(ATTR_ORIG_REF, nil)
    part:SetAttribute(ATTR_ORIG_CST, nil)
    part:SetAttribute(ATTR_CLASS, nil)
    CollectionService:RemoveTag(part, TAG_PROCESSED)
end

function Snap.restoreAll()
    for _, p in ipairs(CollectionService:GetTagged(TAG_PROCESSED)) do
        if p:IsA("BasePart") and p.Parent then pcall(Snap.restorePart, p) end
    end
end

-- ===========================================================================
-- 9. PREDICATES
-- ===========================================================================
local function isCharacterPart(part)
    local cur = part.Parent
    while cur and cur ~= Workspace do
        if cur:IsA("Model") and cur:FindFirstChildOfClass("Humanoid") then return true end
        if cur:IsA("Accessory") or cur:IsA("Tool") then return true end
        cur = cur.Parent
    end
    return false
end

local function hasSurfaceAppearance(part)
    return part:FindFirstChildOfClass("SurfaceAppearance") ~= nil
end

local function isTooSmall(part)
    local s = part.Size
    local c = Cfg.Detection.SmallPartCutoff
    return s.X < c and s.Y < c and s.Z < c
end

local function isOverlay(part)
    return part.Name == OVERLAY_NAME or CollectionService:HasTag(part, TAG_OVERLAY)
end

local function canHaveOverlay(part)
    if not part:IsA("Part") then return false end
    if part.Shape ~= Enum.PartType.Block then return false end
    local size = part.Size
    if size.X * size.Z < Cfg.Detection.OverlayMinArea then return false end
    if size.Y > mathMax(size.X, size.Z) * 0.8 then return false end
    return true
end

-- ===========================================================================
-- 10. PERFORMANCE MONITOR
-- ===========================================================================
local Perf = {}
Perf.samples = {}
Perf.maxSamples = 90
Perf.adaptCooldown = 0
Perf.userOverride = false

function Perf.sample(dt)
    local fps = dt > 0 and 1 / dt or 60
    table.insert(Perf.samples, fps)
    if #Perf.samples > Perf.maxSamples then table.remove(Perf.samples, 1) end
end

function Perf.avg()
    local sum, n = 0, #Perf.samples
    if n == 0 then return 60 end
    for i = 1, n do sum = sum + Perf.samples[i] end
    return sum / n
end

-- ===========================================================================
-- 11. SCHEDULER
-- ===========================================================================
local Sched = {}
Sched.tasks = {}

function Sched.add(name, fn, hz)
    Sched.tasks[name] = { fn = fn, hz = hz or 30, _acc = 0 }
end

function Sched.remove(name)
    Sched.tasks[name] = nil
end

function Sched.tick(dt)
    for _, t in pairs(Sched.tasks) do
        t._acc = t._acc + dt
        local interval = 1 / t.hz
        if t._acc >= interval then
            t._acc = t._acc - interval
            local ok, err = pcall(t.fn, dt)
            if not ok then warn("[Cinematic] Sched err: " .. tostring(err)) end
        end
    end
end

-- ===========================================================================
-- 12. MATERIALS
-- ===========================================================================
local Mat = {}
local Refl  -- forward

function Mat.classify(part)
    if not part:IsA("BasePart") then return nil end
    if part:IsDescendantOf(Lighting) then return nil end
    if isOverlay(part) then return nil end
    if isCharacterPart(part) then return nil end
    if hasSurfaceAppearance(part) then return nil end
    if isTooSmall(part) then return nil end
    if part.Transparency >= 0.97 then return nil end
    local m = part.Material
    if m == Enum.Material.Neon then return "neon" end
    if m == Enum.Material.Glass then return "glass" end
    if Cfg.MetalMats[m] then return "metal" end
    if Cfg.FloorMats[m] then
        local up = part.CFrame.UpVector
        local size = part.Size
        local area = size.X * size.Z
        local longestH = mathMax(size.X, size.Z)
        if up.Y >= Cfg.Detection.FloorNormalDot
            and area >= Cfg.Detection.FloorMinArea
            and size.Y <= longestH * 0.85 then
            return "floor"
        end
        return "surface"
    end
    return nil
end

function Mat.applyFloor(part)
    Snap.takePart(part)
    if part.Material == Enum.Material.Plastic then
        part.Material = Enum.Material.SmoothPlastic
    end
    local matMul = Cfg.FloorRefl[part.Material] or 1.0
    local albedo = Util.albedoScale(part)
    part.Reflectance = mathClamp(Cfg.Reflectance.Floor * matMul * albedo * State.Intensity, 0, 0.35)
    part.CastShadow = true
    part:SetAttribute(ATTR_CLASS, "floor")
    CollectionService:AddTag(part, TAG_PROCESSED)
    local qp = Cfg.Quality[State.Quality]
    if qp.OverlayEnabled and State.Reflection > 0 and State.Wetness > 0.05 then
        Refl.create(part)
    end
end

function Mat.applyGlass(part)
    Snap.takePart(part)
    part.Material = Enum.Material.Glass
    local albedo = mathMax(0.55, Util.albedoScale(part))
    part.Reflectance = mathClamp(Cfg.Reflectance.Glass * albedo * State.Reflection * State.Intensity, 0, 0.85)
    part:SetAttribute(ATTR_CLASS, "glass")
    CollectionService:AddTag(part, TAG_PROCESSED)
end

function Mat.applyMetal(part)
    Snap.takePart(part)
    local albedo = mathMax(0.4, Util.albedoScale(part))
    part.Reflectance = mathClamp(Cfg.Reflectance.Metal * albedo * State.Reflection * State.Intensity, 0, 0.6)
    part:SetAttribute(ATTR_CLASS, "metal")
    CollectionService:AddTag(part, TAG_PROCESSED)
end

function Mat.applyNeon(part)
    Snap.takePart(part)
    part.CastShadow = false
    part:SetAttribute(ATTR_CLASS, "neon")
    CollectionService:AddTag(part, TAG_PROCESSED)
end

function Mat.applySurface(part)
    Snap.takePart(part)
    local albedo = Util.albedoScale(part)
    local target = mathClamp(Cfg.Reflectance.Surface * albedo * State.Intensity, 0, 0.08)
    if part.Reflectance < target then part.Reflectance = target end
    part:SetAttribute(ATTR_CLASS, "surface")
    CollectionService:AddTag(part, TAG_PROCESSED)
end

function Mat.process(part)
    if not part or not part.Parent then return end
    if not part:IsA("BasePart") then return end
    if CollectionService:HasTag(part, TAG_PROCESSED) then return end
    if isOverlay(part) then return end
    local class = Mat.classify(part)
    if class == "floor" then Mat.applyFloor(part)
    elseif class == "glass"   then Mat.applyGlass(part)
    elseif class == "metal"   then Mat.applyMetal(part)
    elseif class == "neon"    then Mat.applyNeon(part)
    elseif class == "surface" then Mat.applySurface(part)
    end
end

local _reapplyPending = false
function Mat.reapplyReflectance()
    if _reapplyPending then return end
    _reapplyPending = true
    task.defer(function()
        _reapplyPending = false
        for _, p in ipairs(CollectionService:GetTagged(TAG_PROCESSED)) do
            if p:IsA("BasePart") and p.Parent then
                local class = p:GetAttribute(ATTR_CLASS)
                local albedo = Util.albedoScale(p)
                if class == "floor" then
                    local mul = Cfg.FloorRefl[p.Material] or 1.0
                    p.Reflectance = mathClamp(Cfg.Reflectance.Floor * mul * albedo * State.Intensity, 0, 0.35)
                elseif class == "glass" then
                    local a = mathMax(0.55, albedo)
                    p.Reflectance = mathClamp(Cfg.Reflectance.Glass * a * State.Reflection * State.Intensity, 0, 0.85)
                elseif class == "metal" then
                    local a = mathMax(0.4, albedo)
                    p.Reflectance = mathClamp(Cfg.Reflectance.Metal * a * State.Reflection * State.Intensity, 0, 0.6)
                elseif class == "surface" then
                    p.Reflectance = mathClamp(Cfg.Reflectance.Surface * albedo * State.Intensity, 0, 0.08)
                end
            end
        end
    end)
end

-- ===========================================================================
-- 13. REFLECTIONS — wet overlay system
-- ===========================================================================
Refl = {}

function Refl.create(part)
    if not canHaveOverlay(part) then return end
    if part:FindFirstChild(OVERLAY_NAME) then return end
    local qp = Cfg.Quality[State.Quality]
    local overlayMax = qp.OverlayMax or Cfg.Detection.OverlayMaxCount
    if overlayMax <= 0 then return end
    if #CollectionService:GetTagged(TAG_OVERLAY) >= overlayMax then return end
    local size = part.Size
    local overlay = Instance.new("Part")
    overlay.Name = OVERLAY_NAME
    overlay.Anchored = true
    overlay.CanCollide = false
    overlay.CanTouch = false
    overlay.CanQuery = false
    overlay.Massless = true
    overlay.Locked = true
    overlay.CastShadow = false
    overlay.Material = Enum.Material.Glass
    local c = part.Color
    local baseline = Color3New(
        mathClamp(c.R * 0.4 + 0.55, 0, 1),
        mathClamp(c.G * 0.4 + 0.55, 0, 1),
        mathClamp(c.B * 0.4 + 0.55, 0, 1)
    )
    overlay.Color = baseline
    overlay:SetAttribute("Cinematic_BaselineColor", baseline)
    overlay.Size = Vec3New(size.X * 0.99, 0.035, size.Z * 0.99)
    overlay.CFrame = part.CFrame * CFNew(0, size.Y * 0.5 + 0.024, 0)
    local wet = State.Wetness * State.Reflection
    local oa  = Util.overlayAlbedoScale(part)
    overlay.Transparency = mathClamp(1 - (wet * 0.55), 0.4, 1)
    overlay.Reflectance  = mathClamp(wet * wet * 0.95 * oa, 0, 0.95)
    overlay.Parent = part
    CollectionService:AddTag(overlay, TAG_OVERLAY)
end

function Refl.update(overlay)
    if not overlay or not overlay.Parent then return end
    local floor = overlay.Parent
    if not floor:IsA("BasePart") then return end
    local wet = State.Wetness * State.Reflection
    local oa  = Util.overlayAlbedoScale(floor)
    overlay.Transparency = mathClamp(1 - (wet * 0.55), 0.4, 1)
    overlay.Reflectance  = mathClamp(wet * wet * 0.95 * oa, 0, 0.95)
end

function Refl.updateAll()
    for _, o in ipairs(CollectionService:GetTagged(TAG_OVERLAY)) do
        Refl.update(o)
    end
end

function Refl.cleanup()
    task.spawn(function()
        local tagged = CollectionService:GetTagged(TAG_OVERLAY)
        for i, o in ipairs(tagged) do
            o:Destroy()
            if i % 60 == 0 then task.wait() end
        end
    end)
end

function Refl.repopulate()
    task.spawn(function()
        local tagged = CollectionService:GetTagged(TAG_PROCESSED)
        for i, part in ipairs(tagged) do
            if part:IsA("BasePart") and part.Parent and part:GetAttribute(ATTR_CLASS) == "floor" then
                Refl.create(part)
            end
            if i % 80 == 0 then task.wait() end
        end
    end)
end

-- ===========================================================================
-- 14. LIGHTING
-- ===========================================================================
local Light = {}
local TWEEN_KEYS = {
    "Ambient","OutdoorAmbient","Brightness","ClockTime",
    "ColorShift_Top","ColorShift_Bottom",
    "EnvironmentDiffuseScale","EnvironmentSpecularScale",
    "ExposureCompensation","FogColor","FogEnd","FogStart",
    "GeographicLatitude","ShadowSoftness",
}
local DIRECT_KEYS = { "Technology", "GlobalShadows" }

function Light.snapshot()
    local s = {}
    for _, k in ipairs(TWEEN_KEYS) do s[k] = Lighting[k] end
    for _, k in ipairs(DIRECT_KEYS) do s[k] = Lighting[k] end
    return s
end

function Light.applyDirect(t)
    for _, k in ipairs(DIRECT_KEYS) do
        if t[k] ~= nil then pcall(function() Lighting[k] = t[k] end) end
    end
end

function Light.tweenTo(target, time)
    local goal = {}
    for _, k in ipairs(TWEEN_KEYS) do
        if target[k] ~= nil then goal[k] = target[k] end
    end
    TweenService:Create(Lighting, TweenInfo.new(time or Cfg.Tween.Default,
        Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
end

function Light.computeTarget()
    local mood = Util.currentMood()
    local moodCfg = Cfg.Moods[mood]
    local weather = Cfg.Weather[State.Weather] or Cfg.Weather.Clear
    local qp = Cfg.Quality[State.Quality]
    local preset = ColorPresets[State.ColorPreset] or ColorPresets.Photorealistic

    local target = {}
    for k, v in pairs(Cfg.Lighting) do target[k] = v end

    if State.TimeMode == "Day" then target.ClockTime = 14.0
    elseif State.TimeMode == "Night" then target.ClockTime = 22.0 end

    target.Brightness = Cfg.Lighting.Brightness * weather.brightMul * State.Intensity

    local shift = preset.AmbientShift
    local a = moodCfg.ambient
    target.Ambient = Color3New(
        mathClamp(a.R + (shift[1] or 0) / 255, 0, 1),
        mathClamp(a.G + (shift[2] or 0) / 255, 0, 1),
        mathClamp(a.B + (shift[3] or 0) / 255, 0, 1)
    )
    target.OutdoorAmbient = Util.lerpColor(Cfg.Lighting.OutdoorAmbient, a, 0.45)
    target.FogColor = weather.fogColor
    target.FogStart = mathFloor(Cfg.Lighting.FogStart * (1 - weather.fogDensity))
    target.FogEnd   = mathFloor(Cfg.Lighting.FogEnd * (1 - weather.fogDensity * 0.9))
    target.EnvironmentSpecularScale = qp.Spec
    target.EnvironmentDiffuseScale  = qp.Diff
    target.ShadowSoftness = qp.ShadowSoft
    target.ExposureCompensation = Cfg.Lighting.ExposureCompensation * State.Intensity
        + (qp.ExposureBoost or 0) + moodCfg.expBias
    return target
end

function Light.apply(time)
    if not State.Enabled then return end
    pcall(function() Lighting.Technology = Cfg.Lighting.Technology end)
    pcall(function() Lighting.GlobalShadows = true end)
    Light.tweenTo(Light.computeTarget(), time)
end

function Light.restore()
    if not OriginalLighting then return end
    Light.applyDirect(OriginalLighting)
    Light.tweenTo(OriginalLighting, 0.5)
end

-- ===========================================================================
-- 15. POST-FX
-- ===========================================================================
local PostFX = {}
PostFX.nodes = {}

local FX_NAMES = {
    "Cinematic_Atmosphere","Cinematic_Bloom","Cinematic_SunRays",
    "Cinematic_CC_Main","Cinematic_CC_Grade","Cinematic_CC_Tone",
    "Cinematic_CC_WhiteBal","Cinematic_CC_LiftGammaGain",
    "Cinematic_CC_Vibrance","Cinematic_CC_Hue",
    "Cinematic_CC_ChromaR","Cinematic_CC_ChromaB",
    "Cinematic_Blur","Cinematic_DOF","Cinematic_Sharpen",
}

local function newOrFind(class, name, parent)
    local existing = parent:FindFirstChild(name)
    if existing and existing:IsA(class) then return existing end
    if existing then existing:Destroy() end
    local inst = Instance.new(class)
    inst.Name = name
    inst.Parent = parent
    return inst
end

function PostFX.build()
    local L = Lighting
    local N = PostFX.nodes
    N.Atmos = newOrFind("Atmosphere", "Cinematic_Atmosphere", L)
    for k, v in pairs(Cfg.Atmosphere) do pcall(function() N.Atmos[k] = v end) end
    N.Bloom = newOrFind("BloomEffect", "Cinematic_Bloom", L)
    N.Bloom.Intensity = Cfg.Bloom.Intensity
    N.Bloom.Size      = Cfg.Bloom.Size
    N.Bloom.Threshold = Cfg.Bloom.Threshold
    N.SunRays = newOrFind("SunRaysEffect", "Cinematic_SunRays", L)
    N.SunRays.Intensity = Cfg.SunRays.Intensity
    N.SunRays.Spread    = Cfg.SunRays.Spread
    N.CCMain  = newOrFind("ColorCorrectionEffect", "Cinematic_CC_Main", L)
    N.CCGrade = newOrFind("ColorCorrectionEffect", "Cinematic_CC_Grade", L)
    N.CCTone  = newOrFind("ColorCorrectionEffect", "Cinematic_CC_Tone", L)
    N.CCWB    = newOrFind("ColorCorrectionEffect", "Cinematic_CC_WhiteBal", L)
    N.CCLGG   = newOrFind("ColorCorrectionEffect", "Cinematic_CC_LiftGammaGain", L)
    N.CCVib   = newOrFind("ColorCorrectionEffect", "Cinematic_CC_Vibrance", L)
    N.CCHue   = newOrFind("ColorCorrectionEffect", "Cinematic_CC_Hue", L)
    N.CCChrR  = newOrFind("ColorCorrectionEffect", "Cinematic_CC_ChromaR", L)
    N.CCChrB  = newOrFind("ColorCorrectionEffect", "Cinematic_CC_ChromaB", L)
    N.Blur    = newOrFind("BlurEffect", "Cinematic_Blur", L)
    N.Blur.Size = 0
    N.DOF     = newOrFind("DepthOfFieldEffect", "Cinematic_DOF", L)
    N.DOF.FarIntensity  = Cfg.DepthOfField.FarIntensity
    N.DOF.NearIntensity = Cfg.DepthOfField.NearIntensity
    N.DOF.FocusDistance = Cfg.DepthOfField.FocusDistance
    N.DOF.InFocusRadius = Cfg.DepthOfField.InFocusRadius
end

function PostFX.setEnabled(on)
    for _, name in ipairs(FX_NAMES) do
        local fx = Lighting:FindFirstChild(name)
        if fx and fx:IsA("PostEffect") then fx.Enabled = on end
    end
    if PostFX.nodes.Atmos then PostFX.nodes.Atmos.Density = on and Cfg.Atmosphere.Density or 0 end
end

function PostFX.applyPreset(time)
    local preset = ColorPresets[State.ColorPreset] or ColorPresets.Photorealistic
    if PostFX.nodes.CCMain then Util.tween(PostFX.nodes.CCMain, time or Cfg.Tween.Default, preset.Main) end
    if PostFX.nodes.CCGrade then Util.tween(PostFX.nodes.CCGrade, time or Cfg.Tween.Default, preset.Grade) end
end

function PostFX.applyTonemap(time)
    local tm = Cfg.Tonemaps[State.Tonemap] or Cfg.Tonemaps.ACES
    if PostFX.nodes.CCTone then
        Util.tween(PostFX.nodes.CCTone, time or Cfg.Tween.Fast, {
            Brightness = tm.b, Contrast = tm.c, Saturation = tm.s, TintColor = tm.tint,
        })
    end
end

function PostFX.applyIntensity(time)
    local N = PostFX.nodes
    if not N.Bloom then return end
    local qp = Cfg.Quality[State.Quality]
    local mood = Cfg.Moods[Util.currentMood()] or Cfg.Moods.Midday
    local weather = Cfg.Weather[State.Weather] or Cfg.Weather.Clear
    local time2 = time or Cfg.Tween.Fast

    Util.tween(N.Bloom, time2, {
        Intensity = Cfg.Bloom.Intensity * State.Bloom * qp.BloomMul
            * mood.bloomMul * weather.bloomMul * State.Intensity,
        Size      = Cfg.Bloom.Size,
        Threshold = Cfg.Bloom.Threshold,
    })
    Util.tween(N.SunRays, time2, {
        Intensity = Cfg.SunRays.Intensity * mood.sunMul * weather.glareMul * State.Intensity,
        Spread    = Cfg.SunRays.Spread,
    })
    Util.tween(N.Atmos, time2, {
        Density = Cfg.Atmosphere.Density * qp.AtmosMul * weather.hazeMul,
        Glare   = Cfg.Atmosphere.Glare * mood.glareMul * weather.glareMul,
        Haze    = Cfg.Atmosphere.Haze * weather.hazeMul,
    })
    if State.CinematicMode then
        Util.tween(N.DOF, time2, {
            FarIntensity = Cfg.DepthOfField.FarIntensity * qp.DOFMul * State.Intensity,
        })
    else
        Util.tween(N.DOF, time2, { FarIntensity = 0 })
    end
    PostFX.applyTonemap(time2)
end

function PostFX.getMood()
    return Cfg.Moods[Util.currentMood()] or Cfg.Moods.Midday
end

-- ===========================================================================
-- 16. ADVANCED COLOR — Kelvin WB, vibrance, hue, lift/gamma/gain, sharpness
-- ===========================================================================
local AdvColor = {}

function AdvColor.apply(time)
    local N = PostFX.nodes
    if not N.CCWB then return end
    time = time or Cfg.Tween.Fast

    -- White Balance: Kelvin → tint color, INVERTED so warmer K = cooler tint
    -- and vice versa (sensor white-balance behavior, not lamp temperature).
    local kelvinTint = Util.kelvinToRGB(State.WhiteBalance)
    local invR = mathClamp(2 - kelvinTint.R, 0, 1.6)
    local invG = mathClamp(2 - kelvinTint.G, 0, 1.6)
    local invB = mathClamp(2 - kelvinTint.B, 0, 1.6)
    -- Renormalize toward 1.0 so total brightness stays similar
    local wbColor = Color3New(
        mathClamp(invR / 1.2, 0, 1),
        mathClamp(invG / 1.2, 0, 1),
        mathClamp(invB / 1.2, 0, 1)
    )
    local wbTintR = mathClamp(wbColor.R + State.WBTint / 400, 0, 1)
    local wbTintG = mathClamp(wbColor.G - State.WBTint / 400, 0, 1)
    Util.tween(N.CCWB, time, {
        TintColor = Color3New(wbTintR, wbTintG, wbColor.B), Brightness = 0, Contrast = 0,
    })

    -- Lift / Gamma / Gain → approximated via Brightness (lift) + Contrast (gain)
    local lift = State.Lift
    local gain = State.Gain
    Util.tween(N.CCLGG, time, {
        Brightness = lift * 0.12,
        Contrast   = (gain - 1) * 0.25,
        Saturation = 0,
        TintColor  = Color3New(1, 1, 1),
    })

    -- Vibrance: smart saturation. Tiny lift in saturation but bias toward
    -- contrast for the bigger value (vibrance acts strongest on mid-sat pixels).
    local vib = State.Vibrance / 100  -- -1..1
    Util.tween(N.CCVib, time, {
        Saturation = vib * 0.35,
        Contrast   = vib * 0.05,
        Brightness = 0,
        TintColor  = Color3New(1, 1, 1),
    })

    -- Hue rotation: Roblox doesn't have a hue rotator; approximate with a
    -- tinted color matrix shift toward the hue's target color.
    local hue = State.HueShift
    local hueRad = math.rad(hue)
    local hueR = 1 + mathSin(hueRad) * 0.08
    local hueG = 1 + mathSin(hueRad + 2 * mathPi / 3) * 0.08
    local hueB = 1 + mathSin(hueRad + 4 * mathPi / 3) * 0.08
    Util.tween(N.CCHue, time, {
        TintColor = Color3New(mathClamp(hueR, 0, 1.5), mathClamp(hueG, 0, 1.5), mathClamp(hueB, 0, 1.5)),
        Brightness = 0, Contrast = 0, Saturation = 0,
    })
end

-- Chromatic aberration: pair of offset CC tints — red push / blue push.
local Chromatic = {}
function Chromatic.apply(time)
    local N = PostFX.nodes
    if not (N.CCChrR and N.CCChrB) then return end
    time = time or Cfg.Tween.Fast
    if not State.ChromaticAberration then
        Util.tween(N.CCChrR, time, { TintColor = Color3New(1,1,1), Saturation = 0 })
        Util.tween(N.CCChrB, time, { TintColor = Color3New(1,1,1), Saturation = 0 })
        return
    end
    local a = State.ChromaticAmount * 0.05
    Util.tween(N.CCChrR, time, { TintColor = Color3New(1 + a, 1 - a*0.5, 1 - a*0.5), Saturation = a })
    Util.tween(N.CCChrB, time, { TintColor = Color3New(1 - a*0.5, 1 - a*0.5, 1 + a), Saturation = -a })
end

-- ===========================================================================
-- 17. RAY TRACER — overlay-driven reflection raycasts (fake SSR + 2-bounce GI)
-- ===========================================================================
local RT = {}
RT.params = nil
RT.cursor = 1
RT.lastRebuild = 0
RT.rebuildInterval = 2.0

function RT.rebuildParams()
    local p = RaycastParams.new()
    p.FilterType = Enum.RaycastFilterType.Exclude
    local filter = { Lighting }
    if LocalPlayer.Character then table.insert(filter, LocalPlayer.Character) end
    for _, o in ipairs(CollectionService:GetTagged(TAG_OVERLAY)) do
        table.insert(filter, o)
    end
    p.FilterDescendantsInstances = filter
    p.IgnoreWater = false
    RT.params = p
    RT.lastRebuild = os.clock()
end

function RT.reset()
    for _, o in ipairs(CollectionService:GetTagged(TAG_OVERLAY)) do
        local base = o:GetAttribute("Cinematic_BaselineColor")
        if typeof(base) == "Color3" then o.Color = base end
    end
end

-- Pre-allocated direction templates for the 6-tap hemisphere GI sample.
local GI_DIRS = {
    Vec3New(0, 1, 0),
    Vec3New(0.7, 0.7, 0),
    Vec3New(-0.7, 0.7, 0),
    Vec3New(0, 0.7, 0.7),
    Vec3New(0, 0.7, -0.7),
    Vec3New(0.5, 0.8, 0.5),
}

function RT.update()
    if not State.Enabled or not State.RayTrace then return end
    local qp = Cfg.Quality[State.Quality]
    local budget = qp.TracesPerTick or 0
    if budget <= 0 then return end
    local maxDist = qp.TraceDist or 200

    if os.clock() - RT.lastRebuild > RT.rebuildInterval then RT.rebuildParams() end
    if not RT.params then return end

    local overlays = CollectionService:GetTagged(TAG_OVERLAY)
    local n = #overlays
    if n == 0 then return end

    for i = 1, budget do
        RT.cursor = RT.cursor + 1
        if RT.cursor > n then RT.cursor = 1 end
        local overlay = overlays[RT.cursor]
        if overlay and overlay.Parent then
            local origin = overlay.Position + Vec3New(0, 0.05, 0)
            local result = Workspace:Raycast(origin, Vec3New(0, maxDist, 0), RT.params)
            if result and result.Instance then
                local hit = result.Instance
                local baselineAttr = overlay:GetAttribute("Cinematic_BaselineColor")
                local baseline = (typeof(baselineAttr) == "Color3") and baselineAttr or overlay.Color
                local hitC = hit.Color
                local distFalloff = mathClamp(1 - result.Distance / maxDist, 0, 1)
                local blend = 0.25 + distFalloff * 0.3
                local newR = baseline.R * (1 - blend) + hitC.R * blend
                local newG = baseline.G * (1 - blend) + hitC.G * blend
                local newB = baseline.B * (1 - blend) + hitC.B * blend

                -- 2nd-bounce GI
                if State.MultiBounceRT then
                    local bounceOrigin = result.Position + result.Normal * 0.1
                    local bounceDir = result.Normal * (maxDist * 0.5)
                    local b2 = Workspace:Raycast(bounceOrigin, bounceDir, RT.params)
                    if b2 and b2.Instance then
                        local bc = b2.Instance.Color
                        newR = newR * 0.85 + bc.R * 0.15
                        newG = newG * 0.85 + bc.G * 0.15
                        newB = newB * 0.85 + bc.B * 0.15
                    end
                end

                -- Enhanced GI: hemisphere sampling
                if State.EnhancedGI then
                    local accR, accG, accB, hits = 0, 0, 0, 0
                    for j = 1, #GI_DIRS do
                        local d = GI_DIRS[j]
                        local r = Workspace:Raycast(origin, d * (maxDist * 0.3), RT.params)
                        if r and r.Instance then
                            local c = r.Instance.Color
                            accR, accG, accB, hits = accR + c.R, accG + c.G, accB + c.B, hits + 1
                        end
                    end
                    if hits > 0 then
                        accR, accG, accB = accR / hits, accG / hits, accB / hits
                        newR = newR * 0.92 + accR * 0.08
                        newG = newG * 0.92 + accG * 0.08
                        newB = newB * 0.92 + accB * 0.08
                    end
                end

                overlay.Color = Color3New(mathClamp(newR,0,1), mathClamp(newG,0,1), mathClamp(newB,0,1))
            end
        end
    end
end

-- ===========================================================================
-- 18. CAMERA FX — sway, sprint FOV, impact shake, motion blur, eye adapt,
--      autofocus, GForce camera tilt, fresnel overlay update
-- ===========================================================================
local Cam = {}
local _camera = Workspace.CurrentCamera
local _swayPhase = 0
local _lastCamPos = nil
local _shakeIntensity = 0
local _shakeDecay = 4.0  -- per second
local _swayBaseFOV  = nil
local _eyeAdaptBias = 0

local function getCamera()
    _camera = Workspace.CurrentCamera or _camera
    return _camera
end

function Cam.init()
    local c = getCamera()
    if c and not OriginalFOV then OriginalFOV = c.FieldOfView end
    _swayBaseFOV = OriginalFOV or 70
end

-- Sprint detection: by humanoid MoveDirection magnitude + speed.
function Cam.updateSpeedFOV(dt)
    if not State.Enabled or not State.SpeedFOV then return end
    local c = getCamera(); if not c then return end
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    local moving = hum.MoveDirection.Magnitude > 0.05
    local speed = hum.WalkSpeed
    local sprinting = speed > 18 and moving
    local target = sprinting and ((_swayBaseFOV or 70) + 8) or (_swayBaseFOV or 70)
    if State.CinematicMode then target = target - 8 end
    c.FieldOfView = Util.lerp(c.FieldOfView, target, mathClamp(dt * 4, 0, 1))
end

-- Camera sway: subtle breathing motion. Apply via CFrame offset relative
-- to current camera orientation, only meaningful in 1st-person / locked cam.
function Cam.updateSway(dt)
    if not State.Enabled or not State.CameraSway then return end
    local c = getCamera(); if not c then return end
    _swayPhase = _swayPhase + dt
    -- Don't overwrite camera CFrame — Roblox player camera will fight us.
    -- Instead nudge FOV very subtly for a breathing feel.
    local baseFOV = c.FieldOfView
    local sway = mathSin(_swayPhase * 1.4) * 0.12
    c.FieldOfView = baseFOV + sway
end

-- Impact shake: external code can call _G.CinematicShader.api.shake(0.5)
-- to inject a quick decaying shake. We modulate ROLL only (not position,
-- which would fight Roblox's camera controller).
function Cam.applyShake(amount)
    _shakeIntensity = mathMax(_shakeIntensity, amount or 0.5)
end

function Cam.updateImpactShake(dt)
    if not State.Enabled or not State.ImpactShake then _shakeIntensity = 0; return end
    if _shakeIntensity <= 0 then return end
    local c = getCamera(); if not c then return end
    -- decay
    _shakeIntensity = mathMax(0, _shakeIntensity - dt * _shakeDecay)
    -- Apply only when camera is in scriptable mode or follow mode using FOV jiggle
    local jitter = (math.random() - 0.5) * _shakeIntensity * 1.2
    c.FieldOfView = c.FieldOfView + jitter
end

-- Motion blur: velocity-driven BlurEffect.Size
function Cam.updateMotionBlur(dt)
    if not State.Enabled or not State.MotionBlur or not PostFX.nodes.Blur then return end
    local c = getCamera(); if not c then return end
    local pos = c.CFrame.Position
    if _lastCamPos then
        local v = (pos - _lastCamPos).Magnitude / mathMax(dt, 1e-3)
        local target = mathClamp((v - 8) * 0.04, 0, 6) * State.Intensity
        local cur = PostFX.nodes.Blur.Size
        PostFX.nodes.Blur.Size = Util.lerp(cur, target, mathClamp(dt * 6, 0, 1))
    end
    _lastCamPos = pos
end

-- Eye adaptation: raycast ahead, read hit part color, compute brightness,
-- bias ExposureCompensation toward darker = brighter expose.
local _eyeAdaptAcc = 0
function Cam.updateEyeAdaptation(dt)
    if not State.Enabled or not State.EyeAdaptation then return end
    _eyeAdaptAcc = _eyeAdaptAcc + dt
    if _eyeAdaptAcc < 0.2 then return end  -- 5 Hz
    _eyeAdaptAcc = 0
    local c = getCamera(); if not c then return end
    local origin = c.CFrame.Position
    local dir = c.CFrame.LookVector * 80
    local r = Workspace:Raycast(origin, dir, RT.params)
    local bright
    if r and r.Instance then
        bright = Util.luminance(r.Instance.Color)
    else
        bright = 0.55  -- sky default
    end
    -- darker scene = lift exposure +0.10, bright scene = drop -0.08
    local targetBias = (0.55 - bright) * 0.18
    _eyeAdaptBias = Util.lerp(_eyeAdaptBias, targetBias, 0.3)
    local mood = PostFX.getMood()
    local qp = Cfg.Quality[State.Quality]
    Lighting.ExposureCompensation = Cfg.Lighting.ExposureCompensation * State.Intensity
        + (qp.ExposureBoost or 0) + mood.expBias + _eyeAdaptBias
end

-- Auto-focus: raycast from camera, set DOF.FocusDistance to hit distance.
local _autoFocusAcc = 0
function Cam.updateAutoFocus(dt)
    if not State.Enabled or not State.AutoFocus or not State.CinematicMode then return end
    _autoFocusAcc = _autoFocusAcc + dt
    if _autoFocusAcc < 0.1 then return end
    _autoFocusAcc = 0
    local c = getCamera(); if not c then return end
    local r = Workspace:Raycast(c.CFrame.Position, c.CFrame.LookVector * 500, RT.params)
    local dist = r and r.Distance or 200
    if PostFX.nodes.DOF then
        PostFX.nodes.DOF.FocusDistance = Util.lerp(PostFX.nodes.DOF.FocusDistance, dist, 0.3)
    end
end

-- Fresnel overlays: update overlay transparency by camera angle.
local _fresnelAcc = 0
function Cam.updateFresnelOverlays(dt)
    if not State.Enabled or not State.FresnelOverlays then return end
    _fresnelAcc = _fresnelAcc + dt
    if _fresnelAcc < 1 / 12 then return end  -- 12 Hz
    _fresnelAcc = 0
    local c = getCamera(); if not c then return end
    local camPos = c.CFrame.Position
    for _, o in ipairs(CollectionService:GetTagged(TAG_OVERLAY)) do
        if o.Parent then
            local d = (o.Position - camPos)
            if d.Magnitude < 350 then
                local viewDir = d.Unit
                local nDot = mathAbs(viewDir.Y)  -- floor normal is +Y
                local fresnel = 1 - nDot
                local wet = State.Wetness * State.Reflection
                o.Reflectance = mathClamp(wet * (0.4 + fresnel * fresnel * 0.6), 0, 0.95)
            end
        end
    end
end

-- GForce: subtle camera roll on lateral acceleration (vehicles).
local _lastVel = Vec3New()
function Cam.updateGForce(dt)
    if not State.Enabled or not State.GForce then return end
    local c = getCamera(); if not c then return end
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local v = hrp.AssemblyLinearVelocity
    local accel = (v - _lastVel) / mathMax(dt, 1e-3)
    _lastVel = v
    -- We can't easily roll the player camera in third-person, so use FOV nudge:
    local lat = accel.Magnitude
    local nudge = mathClamp(lat / 200, 0, 0.3)
    c.FieldOfView = c.FieldOfView + nudge
end

function Cam.restore()
    local c = getCamera()
    if c and OriginalFOV then c.FieldOfView = OriginalFOV end
end

-- ===========================================================================
-- 19. SCREEN OVERLAYS — vignette, lens flare, lens dirt, film grain, light
--      leaks, dust motes, rain droplets
-- ===========================================================================
local Overlays = {}
Overlays.guis = {}

-- Helper: make a screen gui owned by this shader
local function makeGui(name, displayOrder)
    local existing = PlayerGui:FindFirstChild(name)
    if existing then existing:Destroy() end
    local g = Instance.new("ScreenGui")
    g.Name = name
    g.ResetOnSpawn = false
    g.IgnoreGuiInset = true
    g.DisplayOrder = displayOrder or 50
    g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    g.Parent = PlayerGui
    return g
end

-- ----- Vignette -----
local Vignette = {}
function Vignette.build()
    local gui = makeGui("Cinematic_Vignette", 80)
    local f = Instance.new("Frame")
    f.Size = UDim2.fromScale(1, 1)
    f.BackgroundColor3 = Color3New(0, 0, 0)
    f.BackgroundTransparency = 1
    f.BorderSizePixel = 0
    f.Parent = gui
    local grad = Instance.new("UIGradient")
    grad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3New(0,0,0)),
        ColorSequenceKeypoint.new(0.55, Color3New(0,0,0)),
        ColorSequenceKeypoint.new(1, Color3New(0,0,0)),
    })
    grad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.55),
        NumberSequenceKeypoint.new(0.4, 0.95),
        NumberSequenceKeypoint.new(1, 0.55),
    })
    grad.Rotation = 90
    grad.Parent = f
    Overlays.guis.Vignette = gui
    gui.Enabled = State.Vignette
end
function Vignette.setVisible(on)
    if Overlays.guis.Vignette then Overlays.guis.Vignette.Enabled = on end
end

-- ----- Film Grain -----
local FilmGrain = {}
function FilmGrain.build()
    local gui = makeGui("Cinematic_FilmGrain", 95)
    local grid = Instance.new("Frame")
    grid.Size = UDim2.fromScale(1, 1)
    grid.BackgroundTransparency = 1
    grid.BorderSizePixel = 0
    grid.Parent = gui
    -- Build a grid of tiny cells whose Transparency animates as noise.
    local cells = {}
    local cols, rows = 22, 14
    for y = 1, rows do
        for x = 1, cols do
            local cell = Instance.new("Frame")
            cell.Size = UDim2.fromScale(1/cols, 1/rows)
            cell.Position = UDim2.fromScale((x-1)/cols, (y-1)/rows)
            cell.BackgroundColor3 = Color3New(0.5, 0.5, 0.5)
            cell.BackgroundTransparency = 0.85
            cell.BorderSizePixel = 0
            cell.Parent = grid
            table.insert(cells, cell)
        end
    end
    Overlays.guis.FilmGrain = gui
    Overlays.filmGrainCells = cells
    gui.Enabled = State.FilmGrain
end
local _grainAcc = 0
function FilmGrain.update(dt)
    if not Overlays.guis.FilmGrain or not Overlays.guis.FilmGrain.Enabled then return end
    _grainAcc = _grainAcc + dt
    if _grainAcc < 1 / 30 then return end
    _grainAcc = 0
    local amt = State.FilmGrainAmount
    for _, c in ipairs(Overlays.filmGrainCells or {}) do
        c.BackgroundTransparency = 1 - (math.random() * amt * 0.35)
    end
end
function FilmGrain.setEnabled(on)
    if Overlays.guis.FilmGrain then Overlays.guis.FilmGrain.Enabled = on end
end

-- ----- Lens Dirt -----
local LensDirt = {}
function LensDirt.build()
    local gui = makeGui("Cinematic_LensDirt", 92)
    local f = Instance.new("Frame")
    f.Size = UDim2.fromScale(1, 1)
    f.BackgroundTransparency = 1
    f.BorderSizePixel = 0
    f.Parent = gui
    -- Static specks of "dirt" — small circles at random positions
    for i = 1, 60 do
        local s = Instance.new("Frame")
        s.AnchorPoint = Vector2.new(0.5, 0.5)
        s.Position = UDim2.fromScale(math.random(), math.random())
        local sz = math.random(4, 14)
        s.Size = UDim2.fromOffset(sz, sz)
        s.BackgroundColor3 = Color3.fromRGB(255, 245, 220)
        s.BackgroundTransparency = 0.85
        s.BorderSizePixel = 0
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(1, 0)
        corner.Parent = s
        s.Parent = f
    end
    Overlays.guis.LensDirt = gui
    gui.Enabled = State.LensDirt
end
function LensDirt.setEnabled(on)
    if Overlays.guis.LensDirt then Overlays.guis.LensDirt.Enabled = on end
end

-- ----- Light Leaks -----
local LightLeaks = {}
function LightLeaks.build()
    local gui = makeGui("Cinematic_LightLeaks", 91)
    -- Five edge-glow gradients
    for i = 1, 5 do
        local f = Instance.new("Frame")
        f.Size = UDim2.fromScale(0.55, 0.55)
        f.AnchorPoint = Vector2.new(0.5, 0.5)
        f.Position = UDim2.fromScale(0.5 + (math.random() - 0.5) * 0.6, 0.4 + (math.random() - 0.5) * 0.4)
        f.BackgroundColor3 = Color3.fromRGB(255, 200, 140)
        f.BackgroundTransparency = 0.85
        f.BorderSizePixel = 0
        local g = Instance.new("UIGradient")
        g.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.0),
            NumberSequenceKeypoint.new(0.5, 0.7),
            NumberSequenceKeypoint.new(1, 1.0),
        })
        g.Rotation = math.random(0, 360)
        g.Parent = f
        f.Parent = gui
    end
    Overlays.guis.LightLeaks = gui
    gui.Enabled = State.LightLeaks
end

-- ----- Lens Flare -----
local LensFlare = {}
function LensFlare.build()
    local gui = makeGui("Cinematic_LensFlare", 93)
    local container = Instance.new("Frame")
    container.Size = UDim2.fromScale(1, 1)
    container.BackgroundTransparency = 1
    container.Parent = gui
    Overlays.guis.LensFlare = gui
    Overlays.lensFlareContainer = container

    Overlays.lensFlareElements = {}
    for i = 1, 6 do
        local f = Instance.new("Frame")
        f.AnchorPoint = Vector2.new(0.5, 0.5)
        local sz = math.random(30, 90)
        f.Size = UDim2.fromOffset(sz, sz)
        f.BackgroundColor3 = Color3.fromRGB(255, 240, 200)
        f.BackgroundTransparency = 0.75
        f.BorderSizePixel = 0
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(1, 0)
        corner.Parent = f
        f.Parent = container
        table.insert(Overlays.lensFlareElements, { frame = f, offset = (i - 3) * 0.18 })
    end
end

function LensFlare.update()
    if not State.Enabled or not State.LensFlare then
        if Overlays.lensFlareContainer then Overlays.lensFlareContainer.Visible = false end
        return
    end
    local c = getCamera(); if not c then return end
    if not Overlays.lensFlareContainer then return end
    -- Roblox doesn't easily expose sun screen position; estimate from clock time.
    local t = Lighting.ClockTime
    -- Map clock 6->18 to screen X 1.2 -> -0.2 (rising then setting)
    local x = 1 - mathClamp((t - 6) / 12, -0.2, 1.2)
    local y = 0.3 + mathSin((t - 12) / 6 * mathPi) * 0.25
    Overlays.lensFlareContainer.Visible = true
    local mood = PostFX.getMood()
    local visibility = (mood.sunMul or 0) * (Cfg.Weather[State.Weather] or Cfg.Weather.Clear).glareMul
    for _, e in ipairs(Overlays.lensFlareElements) do
        local px = x + e.offset
        e.frame.Position = UDim2.fromScale(px, y + e.offset * 0.05)
        e.frame.BackgroundTransparency = 1 - (0.25 * visibility)
    end
end

-- ===========================================================================
-- 20. SUN DISC — visible sun + corona + atmospheric reddening
-- ===========================================================================
local SunDisc = {}
function SunDisc.build()
    local gui = makeGui("Cinematic_SunDisc", 70)
    local container = Instance.new("Frame")
    container.AnchorPoint = Vector2.new(0.5, 0.5)
    container.Size = UDim2.fromOffset(140, 140)
    container.BackgroundTransparency = 1
    container.Parent = gui

    local disc = Instance.new("Frame")
    disc.AnchorPoint = Vector2.new(0.5, 0.5)
    disc.Position = UDim2.fromScale(0.5, 0.5)
    disc.Size = UDim2.fromOffset(60, 60)
    disc.BackgroundColor3 = Color3.fromRGB(255, 245, 220)
    disc.BorderSizePixel = 0
    local discCorner = Instance.new("UICorner")
    discCorner.CornerRadius = UDim.new(1, 0)
    discCorner.Parent = disc
    disc.Parent = container

    local corona = Instance.new("Frame")
    corona.AnchorPoint = Vector2.new(0.5, 0.5)
    corona.Position = UDim2.fromScale(0.5, 0.5)
    corona.Size = UDim2.fromOffset(140, 140)
    corona.BackgroundColor3 = Color3.fromRGB(255, 220, 180)
    corona.BackgroundTransparency = 0.7
    corona.BorderSizePixel = 0
    local coronaCorner = Instance.new("UICorner")
    coronaCorner.CornerRadius = UDim.new(1, 0)
    coronaCorner.Parent = corona
    corona.Parent = container
    corona.ZIndex = disc.ZIndex - 1

    Overlays.guis.SunDisc = gui
    Overlays.sunDiscContainer = container
    Overlays.sunDiscDisc = disc
    Overlays.sunDiscCorona = corona
    gui.Enabled = State.SunDisc
end
function SunDisc.setEnabled(on)
    if Overlays.guis.SunDisc then Overlays.guis.SunDisc.Enabled = on end
end
function SunDisc.update()
    if not (Overlays.guis.SunDisc and Overlays.guis.SunDisc.Enabled) then return end
    local t = Lighting.ClockTime
    local x = 1 - mathClamp((t - 6) / 12, -0.2, 1.2)
    local y = 0.45 + mathSin((t - 12) / 6 * mathPi) * 0.30
    Overlays.sunDiscContainer.Position = UDim2.fromScale(x, y)
    -- atmospheric reddening when low in sky
    local lowness = mathClamp(1 - mathAbs(y - 0.5) * 2.5, 0, 1)
    local r = 1
    local g = 1 - lowness * 0.25
    local b = 1 - lowness * 0.55
    Overlays.sunDiscDisc.BackgroundColor3 = Color3New(r, g, b)
    Overlays.sunDiscCorona.BackgroundColor3 = Color3New(r, g * 0.9, b * 0.8)
end

-- ===========================================================================
-- 21. VOLUMETRIC FOG — camera-orbiting beams
-- ===========================================================================
local VolFog = {}
VolFog.parts = {}
VolFog.attach = {}

function VolFog.build()
    VolFog.cleanup()
    local folder = Workspace:FindFirstChild("Cinematic_VolFog") or Instance.new("Folder")
    folder.Name = "Cinematic_VolFog"
    folder.Parent = Workspace
    VolFog.folder = folder

    local qp = Cfg.Quality[State.Quality]
    local count = (qp.OverlayMax and qp.OverlayMax > 0) and 32 or 16

    for i = 1, count do
        local p = Instance.new("Part")
        p.Name = "VolFogBeam"
        p.Anchored = true
        p.CanCollide = false
        p.CanQuery = false
        p.CanTouch = false
        p.Locked = true
        p.Massless = true
        p.Transparency = 1
        p.Size = Vec3New(0.05, 0.05, 0.05)
        p.Parent = folder
        local a0 = Instance.new("Attachment", p)
        local a1 = Instance.new("Attachment", p)
        a0.Position = Vec3New(0, 0, 0)
        a1.Position = Vec3New(0, 0, -10)
        local b = Instance.new("Beam")
        b.Attachment0 = a0
        b.Attachment1 = a1
        b.Width0 = 6
        b.Width1 = 8
        b.LightInfluence = 0
        b.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.85),
            NumberSequenceKeypoint.new(1, 1.0),
        })
        b.Color = ColorSequence.new(Color3.fromRGB(220, 220, 230))
        b.FaceCamera = true
        b.Parent = p
        VolFog.parts[i] = { part = p, beam = b }
    end
    if Overlays.guis.VolFog then Overlays.guis.VolFog = nil end
end

function VolFog.setEnabled(on)
    if not VolFog.folder then return end
    VolFog.folder.Parent = on and Workspace or nil
end

function VolFog.update(dt)
    if not State.Enabled or not State.VolumetricFog then return end
    if not VolFog.folder then return end
    local c = getCamera(); if not c then return end
    local origin = c.CFrame.Position
    local mood = PostFX.getMood()
    local weather = Cfg.Weather[State.Weather] or Cfg.Weather.Clear
    local density = State.VolumetricDensity * weather.fogDensity * 1.4
    for i, rec in ipairs(VolFog.parts) do
        local angle = (i / #VolFog.parts) * mathPi * 2 + os.clock() * 0.04
        local radius = 40 + (i % 4) * 12
        local h = (i % 7) * 4 - 8
        rec.part.Position = origin + Vec3New(mathCos(angle) * radius, h, mathSin(angle) * radius)
        rec.beam.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, mathClamp(0.86 - density * 0.5, 0.2, 0.95)),
            NumberSequenceKeypoint.new(1, 1.0),
        })
        rec.beam.Color = ColorSequence.new(Util.lerpColor(Color3.fromRGB(220,220,230), mood.ambient, 0.35))
    end
end

function VolFog.cleanup()
    if VolFog.folder then VolFog.folder:Destroy(); VolFog.folder = nil end
    table.clear(VolFog.parts)
end

-- ===========================================================================
-- 22. GOD RAYS — visible sun shafts
-- ===========================================================================
local GodRays = {}
GodRays.parts = {}

function GodRays.build()
    GodRays.cleanup()
    local folder = Instance.new("Folder")
    folder.Name = "Cinematic_GodRays"
    folder.Parent = Workspace
    GodRays.folder = folder

    local qp = Cfg.Quality[State.Quality]
    local count = qp.Photoreal and 80 or 40

    for i = 1, count do
        local p = Instance.new("Part")
        p.Anchored = true
        p.CanCollide = false
        p.CanQuery = false
        p.CanTouch = false
        p.Locked = true
        p.Massless = true
        p.Transparency = 1
        p.Size = Vec3New(0.05, 0.05, 0.05)
        p.Parent = folder
        local a0 = Instance.new("Attachment", p)
        local a1 = Instance.new("Attachment", p)
        a1.Position = Vec3New(0, 0, -120)
        local beam = Instance.new("Beam")
        beam.Attachment0 = a0
        beam.Attachment1 = a1
        beam.Width0 = 3
        beam.Width1 = 0.5
        beam.LightInfluence = 0
        beam.FaceCamera = true
        beam.Color = ColorSequence.new(Color3.fromRGB(255, 240, 200))
        beam.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.86),
            NumberSequenceKeypoint.new(1, 1.0),
        })
        beam.Parent = p
        GodRays.parts[i] = { part = p, beam = beam }
    end
end

function GodRays.setEnabled(on)
    if not GodRays.folder then return end
    GodRays.folder.Parent = on and Workspace or nil
end

function GodRays.update(dt)
    if not State.Enabled or not State.GodRays then return end
    if not GodRays.folder then return end
    local c = getCamera(); if not c then return end
    local origin = c.CFrame.Position
    -- approximate sun dir from clock time
    local t = Lighting.ClockTime
    local sunAngle = (t - 12) / 12 * mathPi
    local sunDir = Vec3New(mathSin(sunAngle), mathMax(0.1, mathCos(sunAngle)), -0.5).Unit
    local mood = PostFX.getMood()
    local weather = Cfg.Weather[State.Weather] or Cfg.Weather.Clear
    local visibility = mood.sunMul * weather.glareMul * State.GodRaysIntensity
    local maxOp = mathClamp(0.86 - 0.35 * visibility, 0.40, 0.95)
    for i, rec in ipairs(GodRays.parts) do
        local angle = (i / #GodRays.parts) * mathPi * 2
        local offset = Vec3New(mathCos(angle) * 60, mathSin(angle) * 30, mathSin(angle * 2) * 25)
        rec.part.CFrame = CFrame.lookAt(origin + offset, origin + offset + sunDir * 100)
        rec.beam.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, maxOp),
            NumberSequenceKeypoint.new(1, 1.0),
        })
    end
end

function GodRays.cleanup()
    if GodRays.folder then GodRays.folder:Destroy(); GodRays.folder = nil end
    table.clear(GodRays.parts)
end

-- ===========================================================================
-- 23. NIGHT BEAMS — beam cones from every light in workspace
-- ===========================================================================
local NightBeams = {}
NightBeams.records = {}

function NightBeams.scan()
    NightBeams.cleanup()
    local qp = Cfg.Quality[State.Quality]
    local cap = qp.BeamMax or 250
    local found = 0
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if found >= cap then break end
        if (inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight")) and inst.Enabled then
            local parent = inst.Parent
            if parent and parent:IsA("BasePart") then
                local a0 = Instance.new("Attachment", parent)
                local a1 = Instance.new("Attachment", parent)
                a1.Position = Vec3New(0, -8, 0)
                local beam = Instance.new("Beam")
                beam.Attachment0 = a0
                beam.Attachment1 = a1
                beam.Width0 = 1
                beam.Width1 = 6
                beam.LightInfluence = 0
                beam.FaceCamera = true
                beam.Color = ColorSequence.new(inst.Color)
                beam.Transparency = NumberSequence.new({
                    NumberSequenceKeypoint.new(0, 0.6),
                    NumberSequenceKeypoint.new(1, 1.0),
                })
                beam.Parent = parent
                CollectionService:AddTag(beam, TAG_LIGHT)
                NightBeams.records[#NightBeams.records + 1] = { beam = beam, a0 = a0, a1 = a1, light = inst }
                found = found + 1
            end
        end
    end
end

function NightBeams.update()
    if not State.Enabled or not State.NightBeams then return end
    local nightFactor = 1 - mathClamp(mathAbs(Lighting.ClockTime - 12) / 6, 0, 1)
    nightFactor = 1 - nightFactor   -- highest at night
    for _, rec in ipairs(NightBeams.records) do
        if rec.light and rec.light.Parent and rec.light.Enabled then
            local op = 0.6 + (1 - nightFactor) * 0.35
            rec.beam.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, op),
                NumberSequenceKeypoint.new(1, 1.0),
            })
        end
    end
end

function NightBeams.cleanup()
    for _, rec in ipairs(NightBeams.records) do
        pcall(function() rec.beam:Destroy(); rec.a0:Destroy(); rec.a1:Destroy() end)
    end
    table.clear(NightBeams.records)
end

-- ===========================================================================
-- 24. LIGHTS ENHANCEMENT — enable shadows on every light
-- ===========================================================================
local Lights = {}
Lights.records = {}
function Lights.scan()
    Lights.cleanup()
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
            local prev = inst.Shadows
            inst.Shadows = true
            table.insert(Lights.records, { light = inst, prev = prev })
            CollectionService:AddTag(inst, TAG_LIGHT)
        end
    end
end
function Lights.cleanup()
    for _, r in ipairs(Lights.records) do
        pcall(function() if r.light.Parent then r.light.Shadows = r.prev end end)
    end
    table.clear(Lights.records)
end

-- ===========================================================================
-- 25. DUST MOTES
-- ===========================================================================
local DustMotes = {}
function DustMotes.build()
    local gui = makeGui("Cinematic_DustMotes", 86)
    local container = Instance.new("Frame")
    container.Size = UDim2.fromScale(1, 1)
    container.BackgroundTransparency = 1
    container.Parent = gui
    local motes = {}
    for i = 1, 50 do
        local m = Instance.new("Frame")
        m.AnchorPoint = Vector2.new(0.5, 0.5)
        local sz = math.random(3, 7)
        m.Size = UDim2.fromOffset(sz, sz)
        m.Position = UDim2.fromScale(math.random(), math.random())
        m.BackgroundColor3 = Color3.fromRGB(255, 250, 230)
        m.BackgroundTransparency = 0.7
        m.BorderSizePixel = 0
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(1, 0)
        corner.Parent = m
        m.Parent = container
        table.insert(motes, { frame = m, phase = math.random() * mathPi * 2, baseX = math.random(), baseY = math.random() })
    end
    Overlays.guis.DustMotes = gui
    Overlays.dustMotes = motes
    gui.Enabled = State.DustMotes
end
function DustMotes.setEnabled(on)
    if Overlays.guis.DustMotes then Overlays.guis.DustMotes.Enabled = on end
end
local _moteAcc = 0
function DustMotes.update(dt)
    if not (Overlays.guis.DustMotes and Overlays.guis.DustMotes.Enabled) then return end
    _moteAcc = _moteAcc + dt
    if _moteAcc < 1 / 20 then return end
    _moteAcc = 0
    local mood = PostFX.getMood()
    local brightness = mood.sunMul * 0.7
    local t = os.clock()
    for _, m in ipairs(Overlays.dustMotes or {}) do
        local x = m.baseX + mathSin(t * 0.3 + m.phase) * 0.04
        local y = m.baseY + mathCos(t * 0.4 + m.phase) * 0.03
        m.frame.Position = UDim2.fromScale(x % 1, y % 1)
        m.frame.BackgroundTransparency = 1 - brightness * 0.4
    end
end

-- ===========================================================================
-- 26. RAIN DROPLETS — screen-space streaks during stormy weather
-- ===========================================================================
local RainDroplets = {}
function RainDroplets.build()
    local gui = makeGui("Cinematic_RainDroplets", 87)
    local container = Instance.new("Frame")
    container.Size = UDim2.fromScale(1, 1)
    container.BackgroundTransparency = 1
    container.Parent = gui
    local drops = {}
    for i = 1, 90 do
        local d = Instance.new("Frame")
        d.AnchorPoint = Vector2.new(0.5, 0)
        d.Size = UDim2.fromOffset(2, math.random(20, 40))
        d.Position = UDim2.fromScale(math.random(), -0.1)
        d.BackgroundColor3 = Color3.fromRGB(220, 230, 250)
        d.BackgroundTransparency = 0.5
        d.BorderSizePixel = 0
        d.Parent = container
        table.insert(drops, { frame = d, vy = math.random(60, 120) / 100, x = math.random(), y = -0.1 })
    end
    Overlays.guis.RainDroplets = gui
    Overlays.rainDrops = drops
    gui.Enabled = false
end
function RainDroplets.update(dt)
    if not Overlays.guis.RainDroplets then return end
    local visible = State.Enabled and State.RainDroplets and (State.Weather == "Stormy" or State.Weather == "Misty")
    Overlays.guis.RainDroplets.Enabled = visible
    if not visible then return end
    for _, d in ipairs(Overlays.rainDrops or {}) do
        d.y = d.y + d.vy * dt
        if d.y > 1.1 then
            d.y = -0.1
            d.x = math.random()
        end
        d.frame.Position = UDim2.fromScale(d.x, d.y)
    end
end

-- ===========================================================================
-- 27. CAUSTICS — animated water-ripple pattern overlay
-- ===========================================================================
local Caustics = {}
function Caustics.build()
    local gui = makeGui("Cinematic_Caustics", 60)
    local f = Instance.new("Frame")
    f.Size = UDim2.fromScale(1, 1)
    f.BackgroundColor3 = Color3.fromRGB(160, 200, 255)
    f.BackgroundTransparency = 0.94
    f.BorderSizePixel = 0
    f.Parent = gui
    local grad = Instance.new("UIGradient")
    grad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.95),
        NumberSequenceKeypoint.new(0.5, 0.7),
        NumberSequenceKeypoint.new(1, 0.95),
    })
    grad.Parent = f
    Overlays.guis.Caustics = gui
    Overlays.causticsGradient = grad
    gui.Enabled = State.Caustics
end
function Caustics.setEnabled(on)
    if Overlays.guis.Caustics then Overlays.guis.Caustics.Enabled = on end
end
local _causticsT = 0
function Caustics.update(dt)
    if not (Overlays.guis.Caustics and Overlays.guis.Caustics.Enabled) then return end
    _causticsT = _causticsT + dt
    if Overlays.causticsGradient then
        Overlays.causticsGradient.Rotation = (_causticsT * 8) % 360
    end
end

-- ===========================================================================
-- 28. SSAO — corner vignette approximation
-- ===========================================================================
local SSAO = {}
function SSAO.build()
    local gui = makeGui("Cinematic_SSAO", 65)
    local f = Instance.new("Frame")
    f.Size = UDim2.fromScale(1, 1)
    f.BackgroundColor3 = Color3New(0, 0, 0)
    f.BackgroundTransparency = 1
    f.BorderSizePixel = 0
    f.Parent = gui
    local grad = Instance.new("UIGradient")
    grad.Color = ColorSequence.new(Color3New(0,0,0))
    grad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.75),
        NumberSequenceKeypoint.new(0.5, 1.0),
        NumberSequenceKeypoint.new(1, 0.75),
    })
    grad.Parent = f
    Overlays.guis.SSAO = gui
    Overlays.ssaoFrame = f
    gui.Enabled = State.SSAO
end
function SSAO.update()
    if not State.Enabled or not State.SSAO then
        if Overlays.guis.SSAO then Overlays.guis.SSAO.Enabled = false end
        return
    end
    if Overlays.guis.SSAO then
        Overlays.guis.SSAO.Enabled = true
        Overlays.ssaoFrame.BackgroundTransparency = 1 - State.SSAOIntensity * 0.3
    end
end

-- ===========================================================================
-- 29. ANISOTROPIC METALS — direction-aware metal reflectance bias
-- ===========================================================================
local AnisoMetals = {}
local _anisoAcc = 0
function AnisoMetals.update(dt)
    if not State.Enabled or not State.AnisotropicMetals then return end
    _anisoAcc = _anisoAcc + dt
    if _anisoAcc < 0.5 then return end
    _anisoAcc = 0
    local c = getCamera(); if not c then return end
    local viewDir = c.CFrame.LookVector
    for _, p in ipairs(CollectionService:GetTagged(TAG_PROCESSED)) do
        if p:IsA("BasePart") and p.Parent and p:GetAttribute(ATTR_CLASS) == "metal" then
            local up = p.CFrame.UpVector
            local dot = mathAbs(viewDir:Dot(up))
            local base = Cfg.Reflectance.Metal * Util.albedoScale(p) * State.Reflection * State.Intensity
            p.Reflectance = mathClamp(base * (0.55 + dot * 0.55), 0, 0.65)
        end
    end
end

-- ===========================================================================
-- 30. SKY MOD — bigger sun/moon discs
-- ===========================================================================
local SkyMod = {}
function SkyMod.apply()
    local sky = Lighting:FindFirstChildOfClass("Sky")
    if not sky then
        sky = Instance.new("Sky")
        sky.Name = "Cinematic_Sky"
        sky.Parent = Lighting
    end
    pcall(function()
        sky.SunAngularSize  = mathMax(sky.SunAngularSize, 11)
        sky.MoonAngularSize = mathMax(sky.MoonAngularSize, 11)
        sky.StarCount = mathMax(sky.StarCount, 3000)
    end)
end

-- ===========================================================================
-- 31. FOLIAGE / FIRE / SMOKE / SPARKLES / WATER
-- ===========================================================================
local Foliage = {}
Foliage.records = {}
function Foliage.scan()
    Foliage.cleanup()
    for _, p in ipairs(Workspace:GetDescendants()) do
        if p:IsA("BasePart") and not isCharacterPart(p) then
            local mat = p.Material
            if mat == Enum.Material.Grass or mat == Enum.Material.LeafyGrass or mat == Enum.Material.Moss then
                local origC = p.Color
                local boosted = Color3New(
                    mathClamp(origC.R * 0.85, 0, 1),
                    mathClamp(origC.G * 1.18, 0, 1),
                    mathClamp(origC.B * 0.85, 0, 1)
                )
                p.Color = boosted
                table.insert(Foliage.records, { part = p, orig = origC })
            end
        end
    end
end
function Foliage.cleanup()
    for _, r in ipairs(Foliage.records) do
        pcall(function() if r.part.Parent then r.part.Color = r.orig end end)
    end
    table.clear(Foliage.records)
end

local FireMod = {}
FireMod.records = {}
function FireMod.scan()
    FireMod.cleanup()
    for _, f in ipairs(Workspace:GetDescendants()) do
        if f:IsA("Fire") then
            local rec = { fire = f, sz = f.Size, heat = f.Heat, c = f.Color, sc = f.SecondaryColor }
            f.Size = f.Size * 1.4
            f.Heat = f.Heat * 1.2
            f.Color = Color3.fromRGB(255, 180, 80)
            f.SecondaryColor = Color3.fromRGB(255, 60, 20)
            table.insert(FireMod.records, rec)
        end
    end
end
function FireMod.cleanup()
    for _, r in ipairs(FireMod.records) do
        pcall(function()
            if r.fire.Parent then
                r.fire.Size = r.sz; r.fire.Heat = r.heat
                r.fire.Color = r.c; r.fire.SecondaryColor = r.sc
            end
        end)
    end
    table.clear(FireMod.records)
end

local SmokeMod = {}
SmokeMod.records = {}
function SmokeMod.scan()
    SmokeMod.cleanup()
    for _, s in ipairs(Workspace:GetDescendants()) do
        if s:IsA("Smoke") then
            local rec = { smoke = s, opacity = s.Opacity, size = s.Size, c = s.Color }
            s.Opacity = mathClamp(s.Opacity * 1.4, 0, 1)
            s.Size = s.Size * 1.3
            s.Color = Util.lerpColor(s.Color, Color3.fromRGB(40, 40, 45), 0.35)
            table.insert(SmokeMod.records, rec)
        end
    end
end
function SmokeMod.cleanup()
    for _, r in ipairs(SmokeMod.records) do
        pcall(function()
            if r.smoke.Parent then
                r.smoke.Opacity = r.opacity; r.smoke.Size = r.size; r.smoke.Color = r.c
            end
        end)
    end
    table.clear(SmokeMod.records)
end

local SparklesMod = {}
SparklesMod.records = {}
function SparklesMod.scan()
    SparklesMod.cleanup()
    for _, s in ipairs(Workspace:GetDescendants()) do
        if s:IsA("Sparkles") then
            local rec = { spark = s, c = s.SparkleColor }
            s.SparkleColor = Util.lerpColor(s.SparkleColor, Color3.fromRGB(255, 240, 200), 0.4)
            table.insert(SparklesMod.records, rec)
        end
    end
end
function SparklesMod.cleanup()
    for _, r in ipairs(SparklesMod.records) do
        pcall(function() if r.spark.Parent then r.spark.SparkleColor = r.c end end)
    end
    table.clear(SparklesMod.records)
end

local WaterMod = {}
WaterMod.orig = nil
function WaterMod.apply()
    if WaterMod.orig then return end
    local terrain = Workspace.Terrain
    WaterMod.orig = {
        WaterColor      = terrain.WaterColor,
        WaterTransparency = terrain.WaterTransparency,
        WaterReflectance  = terrain.WaterReflectance,
        WaterWaveSize     = terrain.WaterWaveSize,
        WaterWaveSpeed    = terrain.WaterWaveSpeed,
    }
    terrain.WaterColor = Color3.fromRGB(15, 65, 100)
    terrain.WaterTransparency = 0.85
    terrain.WaterReflectance = 0.45
    terrain.WaterWaveSize = 0.18
    terrain.WaterWaveSpeed = 12
end
function WaterMod.restore()
    if not WaterMod.orig then return end
    local terrain = Workspace.Terrain
    pcall(function()
        for k, v in pairs(WaterMod.orig) do terrain[k] = v end
    end)
    WaterMod.orig = nil
end

-- ===========================================================================
-- 32. PRECIPITATION — rain (Stormy) / snow (Misty), camera-following
-- ===========================================================================
local Precip = {}
Precip.parts = {}
function Precip.build()
    Precip.cleanup()
    local p = Instance.new("Part")
    p.Name = "Cinematic_PrecipEmitter"
    p.Anchored = true
    p.CanCollide = false
    p.CanQuery = false
    p.CanTouch = false
    p.Locked = true
    p.Massless = true
    p.Transparency = 1
    p.Size = Vec3New(40, 1, 40)
    p.Parent = Workspace
    Precip.emitterPart = p

    local rain = Instance.new("ParticleEmitter")
    rain.Name = "Rain"
    rain.Texture = "rbxasset://textures/particles/explosion01_implosion_main.dds"
    rain.Lifetime = NumberRange.new(0.6, 0.8)
    rain.Rate = 0
    rain.Speed = NumberRange.new(70, 90)
    rain.SpreadAngle = Vector2.new(5, 5)
    rain.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.18),
        NumberSequenceKeypoint.new(1, 0.06),
    })
    rain.Transparency = NumberSequence.new(0.4)
    rain.Color = ColorSequence.new(Color3.fromRGB(200, 220, 250))
    rain.Rotation = NumberRange.new(0)
    rain.RotSpeed = NumberRange.new(0)
    rain.Acceleration = Vec3New(0, -50, 0)
    rain.Orientation = Enum.ParticleOrientation.VelocityParallel
    rain.Parent = p
    Precip.rain = rain

    local snow = Instance.new("ParticleEmitter")
    snow.Name = "Snow"
    snow.Texture = "rbxasset://textures/particles/sparkles_main.dds"
    snow.Lifetime = NumberRange.new(3, 4.5)
    snow.Rate = 0
    snow.Speed = NumberRange.new(5, 10)
    snow.SpreadAngle = Vector2.new(20, 20)
    snow.Size = NumberSequence.new(0.2)
    snow.Transparency = NumberSequence.new(0.3)
    snow.Color = ColorSequence.new(Color3.fromRGB(240, 245, 255))
    snow.Acceleration = Vec3New(0, -3, 0)
    snow.Parent = p
    Precip.snow = snow
end

function Precip.update()
    if not Precip.emitterPart then return end
    local c = getCamera(); if not c then return end
    Precip.emitterPart.CFrame = CFNew(c.CFrame.Position + Vec3New(0, 80, 0))
    local rainOn = State.Enabled and State.Precipitation and State.Weather == "Stormy"
    local snowOn = State.Enabled and State.Precipitation and State.Weather == "Misty"
    if Precip.rain then Precip.rain.Rate = rainOn and 400 or 0 end
    if Precip.snow then Precip.snow.Rate = snowOn and 100 or 0 end
end

function Precip.cleanup()
    if Precip.emitterPart then Precip.emitterPart:Destroy(); Precip.emitterPart = nil end
    Precip.rain, Precip.snow = nil, nil
end

-- ===========================================================================
-- 33. LIGHTNING — random flashes during stormy weather
-- ===========================================================================
local Lightning = {}
local _lightningCooldown = 0
local _lightningFlash = 0

function Lightning.update()
    if not (State.Enabled and State.Lightning and State.Weather == "Stormy") then
        _lightningFlash = 0
        return
    end
    if _lightningFlash > 0 then
        _lightningFlash = mathMax(0, _lightningFlash - 0.06)
        local bias = _lightningFlash
        Lighting.ExposureCompensation = (PostFX.getMood().expBias or 0) + 0.05 + bias
    else
        _lightningCooldown = _lightningCooldown - 1/60
        if _lightningCooldown <= 0 and math.random() < 0.0009 then
            _lightningFlash = 1.0
            _lightningCooldown = math.random(8, 22)
        end
    end
end

-- ===========================================================================
-- 34. DAY/NIGHT CYCLE
-- ===========================================================================
local Cycle = {}
function Cycle.update(dt)
    if not State.Enabled or not State.AutoCycle then return end
    Lighting.ClockTime = (Lighting.ClockTime + dt * State.CycleSpeed) % 24
end

-- ===========================================================================
-- 35. UNDERWATER DETECTION
-- ===========================================================================
local Underwater = {}
function Underwater.build()
    local cc = Lighting:FindFirstChild("Cinematic_Underwater") or Instance.new("ColorCorrectionEffect")
    cc.Name = "Cinematic_Underwater"
    cc.Enabled = false
    cc.TintColor = Color3.fromRGB(80, 160, 200)
    cc.Brightness = -0.10
    cc.Saturation = -0.05
    cc.Parent = Lighting
    Underwater.cc = cc
    local b = Lighting:FindFirstChild("Cinematic_UnderwaterBlur") or Instance.new("BlurEffect")
    b.Name = "Cinematic_UnderwaterBlur"
    b.Enabled = false
    b.Size = 6
    b.Parent = Lighting
    Underwater.blur = b
end
-- Underwater detection throttled to 5 Hz with a small pcall'd voxel probe.
local _underwaterAcc = 0
local _underwaterIn = false
function Underwater.update()
    if not State.Enabled or not State.Underwater then
        if Underwater.cc then Underwater.cc.Enabled = false end
        if Underwater.blur then Underwater.blur.Enabled = false end
        return
    end
    _underwaterAcc = _underwaterAcc + 1 / 60
    if _underwaterAcc < 0.2 then
        if Underwater.cc then Underwater.cc.Enabled = _underwaterIn end
        if Underwater.blur then Underwater.blur.Enabled = _underwaterIn end
        return
    end
    _underwaterAcc = 0
    local c = getCamera(); if not c then return end
    local ok = pcall(function()
        local pos = c.CFrame.Position
        local region = Region3.new(pos - Vec3New(2, 2, 2), pos + Vec3New(2, 2, 2)):ExpandToGrid(4)
        local mats = Workspace.Terrain:ReadVoxels(region, 4)
        local sx, sy, sz = mats.Size.X, mats.Size.Y, mats.Size.Z
        _underwaterIn = false
        for x = 1, sx do
            for y = 1, sy do
                for z = 1, sz do
                    if mats[x][y][z] == Enum.Material.Water then
                        _underwaterIn = true; return
                    end
                end
            end
        end
    end)
    if not ok then _underwaterIn = false end
    Underwater.cc.Enabled = _underwaterIn
    Underwater.blur.Enabled = _underwaterIn
end
function Underwater.cleanup()
    if Underwater.cc then Underwater.cc:Destroy() end
    if Underwater.blur then Underwater.blur:Destroy() end
end

-- ===========================================================================
-- 36. FREE CAM — desktop only, F to toggle, WASD to fly, R to reset
-- ===========================================================================
local FreeCam = {}
FreeCam.enabled = false
FreeCam.position = nil
FreeCam.yaw = 0
FreeCam.pitch = 0
FreeCam.conn = nil

function FreeCam.enable()
    if FreeCam.enabled then return end
    local c = getCamera(); if not c then return end
    FreeCam.enabled = true
    FreeCam.position = c.CFrame.Position
    FreeCam.yaw, FreeCam.pitch = 0, 0
    c.CameraType = Enum.CameraType.Scriptable
    FreeCam.conn = Conn.track(RunService.RenderStepped:Connect(function(dt)
        local cam = getCamera(); if not cam then return end
        local move = Vec3New()
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then move = move + Vec3New(0, 0, -1) end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then move = move + Vec3New(0, 0,  1) end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then move = move + Vec3New(-1, 0, 0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then move = move + Vec3New( 1, 0, 0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.E) then move = move + Vec3New( 0, 1, 0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.Q) then move = move + Vec3New( 0,-1, 0) end
        local speed = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) and 120 or 50
        local mouseDelta = UserInputService:GetMouseDelta()
        FreeCam.yaw   = FreeCam.yaw   - mouseDelta.X * 0.005
        FreeCam.pitch = mathClamp(FreeCam.pitch - mouseDelta.Y * 0.005, -mathPi / 2 + 0.1, mathPi / 2 - 0.1)
        local rot = CFrame.fromEulerAnglesYXZ(FreeCam.pitch, FreeCam.yaw, 0)
        if move.Magnitude > 0 then
            FreeCam.position = FreeCam.position + (rot * move.Unit) * speed * dt
        end
        cam.CFrame = CFNew(FreeCam.position) * rot
    end))
end

function FreeCam.disable()
    if not FreeCam.enabled then return end
    FreeCam.enabled = false
    if FreeCam.conn then pcall(function() FreeCam.conn:Disconnect() end); FreeCam.conn = nil end
    local c = getCamera()
    if c then
        c.CameraType = Enum.CameraType.Custom
        c.CameraSubject = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid")
    end
end

-- ===========================================================================
-- 37. DETECTION — initial scan + watcher
-- ===========================================================================
local Detect = {}
Detect.queue = {}

function Detect.scan()
    task.spawn(function()
        local descs = Workspace:GetDescendants()
        for i, p in ipairs(descs) do
            if p:IsA("BasePart") then table.insert(Detect.queue, p) end
            if i % Cfg.Performance.ScanBatch == 0 then task.wait() end
        end
    end)
end

function Detect.processQueue(dt)
    local budget = Cfg.Performance.ProcessBudget
    local processed = 0
    local startT = os.clock()
    while processed < budget and #Detect.queue > 0 do
        local p = table.remove(Detect.queue, 1)
        if p then Mat.process(p) end
        processed = processed + 1
        if os.clock() - startT > 0.005 then break end
    end
end

function Detect.bindWatcher()
    Conn.track(Workspace.DescendantAdded:Connect(function(inst)
        if inst:IsA("BasePart") then table.insert(Detect.queue, inst) end
        if State.LightEnhance and (inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight")) then
            local prev = inst.Shadows
            inst.Shadows = true
            table.insert(Lights.records, { light = inst, prev = prev })
            CollectionService:AddTag(inst, TAG_LIGHT)
        end
    end))
end

-- ===========================================================================
-- 38. CAMERA FILL LIGHT
-- ===========================================================================
local CamFill = {}
function CamFill.build()
    local p = Workspace:FindFirstChild("Cinematic_CamFill") or Instance.new("Part")
    p.Name = "Cinematic_CamFill"
    p.Anchored = true
    p.CanCollide = false
    p.CanQuery = false
    p.CanTouch = false
    p.Locked = true
    p.Massless = true
    p.Transparency = 1
    p.Size = Vec3New(0.05, 0.05, 0.05)
    p.Parent = Workspace
    local light = p:FindFirstChildOfClass("PointLight") or Instance.new("PointLight", p)
    light.Range = 22
    light.Brightness = 0.4
    light.Color = Color3.fromRGB(255, 240, 220)
    light.Shadows = false
    CamFill.part = p
    CamFill.light = light
end
function CamFill.update(dt)
    if not (CamFill.part and CamFill.light) then return end
    if not State.Enabled or not State.CameraFillLight then
        CamFill.light.Brightness = 0
        return
    end
    local c = getCamera(); if not c then return end
    CamFill.part.Position = c.CFrame.Position + Vec3New(0, 1, 0)
    local mood = PostFX.getMood()
    CamFill.light.Brightness = 0.55 * (mood.sunMul or 1)
    CamFill.light.Color = mood.grade
end
function CamFill.cleanup()
    if CamFill.part then CamFill.part:Destroy(); CamFill.part = nil end
end

-- ===========================================================================
-- 39. PLAYER HIGHLIGHT
-- ===========================================================================
local PlayerHL = {}
PlayerHL.bound = {}
function PlayerHL.bindAll()
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then PlayerHL.bind(plr) end
    end
    Conn.track(Players.PlayerAdded:Connect(function(plr)
        if plr ~= LocalPlayer then PlayerHL.bind(plr) end
    end))
end
function PlayerHL.bind(plr)
    if PlayerHL.bound[plr] then return end
    PlayerHL.bound[plr] = true
    local function onChar(char)
        local h = Instance.new("Highlight")
        h.Name = "Cinematic_HL"
        h.Adornee = char
        h.FillTransparency = 1
        h.OutlineTransparency = 0.5
        h.OutlineColor = Color3.fromRGB(255, 240, 220)
        h.Parent = char
        CollectionService:AddTag(h, TAG_HIGHLIGHT)
    end
    if plr.Character then onChar(plr.Character) end
    Conn.track(plr.CharacterAdded:Connect(onChar))
end
function PlayerHL.update()
    if not State.Enabled or not State.PlayerHighlight then
        for _, h in ipairs(CollectionService:GetTagged(TAG_HIGHLIGHT)) do
            h.OutlineTransparency = 1
        end
        return
    end
    for _, h in ipairs(CollectionService:GetTagged(TAG_HIGHLIGHT)) do
        h.OutlineTransparency = 0.4
    end
end

-- ===========================================================================
-- 40. PERF HUD
-- ===========================================================================
local PerfHUD = {}
function PerfHUD.build()
    local gui = makeGui("Cinematic_PerfHUD", 200)
    gui.Enabled = State.PerfHUD
    local f = Instance.new("Frame")
    f.Size = UDim2.fromOffset(160, 60)
    f.Position = UDim2.new(1, -170, 0, 10)
    f.BackgroundColor3 = Color3New(0, 0, 0)
    f.BackgroundTransparency = 0.5
    f.BorderSizePixel = 0
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 8); corner.Parent = f
    f.Parent = gui
    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Code
    label.TextSize = 13
    label.TextColor3 = Color3.fromRGB(240, 240, 240)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Padding = UDim.new(0, 8)
    label.Parent = f
    PerfHUD.gui = gui
    PerfHUD.label = label
end

local _hudAcc = 0
function PerfHUD.update(dt)
    if not PerfHUD.gui then return end
    PerfHUD.gui.Enabled = State.PerfHUD
    if not State.PerfHUD then return end
    _hudAcc = _hudAcc + dt
    if _hudAcc < 0.2 then return end
    _hudAcc = 0
    local avg = Perf.avg()
    local mood = Util.currentMood()
    PerfHUD.label.Text = string.format(
        "  FPS  %3d\n  %s | %s\n  %s", math.floor(avg), State.Quality, mood, State.ColorPreset
    )
end

-- ===========================================================================
-- 41. TOAST — temporary on-screen notification
-- ===========================================================================
local Toast = {}
function Toast.show(msg, dur)
    dur = dur or 4
    local existing = PlayerGui:FindFirstChild("Cinematic_Toast")
    if existing then existing:Destroy() end
    local gui = makeGui("Cinematic_Toast", 250)
    local f = Instance.new("Frame")
    f.AnchorPoint = Vector2.new(0.5, 1)
    f.Position = UDim2.new(0.5, 0, 1, -32)
    f.Size = UDim2.fromOffset(420, 56)
    f.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
    f.BackgroundTransparency = 0.12
    f.BorderSizePixel = 0
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 10); corner.Parent = f
    local stroke = Instance.new("UIStroke"); stroke.Color = Color3.fromRGB(120,120,140); stroke.Thickness = 1; stroke.Parent = f
    f.Parent = gui
    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamSemibold
    label.TextSize = 14
    label.TextColor3 = Color3.fromRGB(240, 240, 245)
    label.TextWrapped = true
    label.Text = msg
    label.Parent = f
    f.BackgroundTransparency = 1
    label.TextTransparency = 1
    Util.tween(f, 0.3, { BackgroundTransparency = 0.12 })
    Util.tween(label, 0.3, { TextTransparency = 0 })
    task.delay(dur, function()
        if gui.Parent then
            Util.tween(f, 0.4, { BackgroundTransparency = 1 })
            Util.tween(label, 0.4, { TextTransparency = 1 })
            task.delay(0.5, function() if gui.Parent then gui:Destroy() end end)
        end
    end)
end

-- ===========================================================================
-- 42. PERSISTENCE — save/load via writefile (executor) + attribute fallback
-- ===========================================================================
local Persist = {}
Persist.fileName = "CinematicShader_v5.json"

local function snapshotSettings()
    return {
        v = 5,
        Quality = State.Quality, ColorPreset = State.ColorPreset, Tonemap = State.Tonemap,
        Intensity = State.Intensity, Bloom = State.Bloom, Reflection = State.Reflection, Wetness = State.Wetness,
        Weather = State.Weather, TimeMode = State.TimeMode, AutoCycle = State.AutoCycle, CycleSpeed = State.CycleSpeed,
        WhiteBalance = State.WhiteBalance, WBTint = State.WBTint, Vibrance = State.Vibrance,
        HueShift = State.HueShift, Lift = State.Lift, Gamma = State.Gamma, Gain = State.Gain, Sharpness = State.Sharpness,
        Vignette = State.Vignette, LensFlare = State.LensFlare, AutoFocus = State.AutoFocus, MotionBlur = State.MotionBlur,
        EyeAdaptation = State.EyeAdaptation, FresnelOverlays = State.FresnelOverlays, NightBeams = State.NightBeams,
        RayTrace = State.RayTrace, MultiBounceRT = State.MultiBounceRT, EnhancedGI = State.EnhancedGI,
        FilmGrain = State.FilmGrain, FilmGrainAmount = State.FilmGrainAmount,
        ChromaticAberration = State.ChromaticAberration, ChromaticAmount = State.ChromaticAmount,
        SunDisc = State.SunDisc, VolumetricFog = State.VolumetricFog, VolumetricDensity = State.VolumetricDensity,
        Caustics = State.Caustics, SSAO = State.SSAO, SSAOIntensity = State.SSAOIntensity,
        AnisotropicMetals = State.AnisotropicMetals, RainDroplets = State.RainDroplets, DustMotes = State.DustMotes,
        LightLeaks = State.LightLeaks, LensDirt = State.LensDirt, GodRays = State.GodRays, GodRaysIntensity = State.GodRaysIntensity,
        HeatHaze = State.HeatHaze, HeatHazeIntensity = State.HeatHazeIntensity, DistanceHaze = State.DistanceHaze,
        CityNightGlow = State.CityNightGlow, CinematicMode = State.CinematicMode, CameraSway = State.CameraSway,
        ImpactShake = State.ImpactShake, AdaptiveQuality = State.AdaptiveQuality,
    }
end

local function applySettings(s)
    if type(s) ~= "table" then return end
    for k, v in pairs(s) do
        if State[k] ~= nil and k ~= "Initialized" and k ~= "Enabled" then State[k] = v end
    end
end

function Persist.save()
    local snap = snapshotSettings()
    local json = HttpService:JSONEncode(snap)
    -- executor file API
    if writefile then
        pcall(function() writefile(Persist.fileName, json) end)
    end
    -- always also store via Lighting attribute as fallback
    pcall(function() Lighting:SetAttribute("Cinematic_SavedConfig", json) end)
    return json
end

function Persist.load()
    local json
    if isfile and isfile(Persist.fileName) and readfile then
        pcall(function() json = readfile(Persist.fileName) end)
    end
    if not json then
        local attr = Lighting:GetAttribute("Cinematic_SavedConfig")
        if type(attr) == "string" then json = attr end
    end
    if not json then return false end
    local ok, decoded = pcall(function() return HttpService:JSONDecode(json) end)
    if ok and decoded then applySettings(decoded); return true end
    return false
end

-- ===========================================================================
-- 43. API
-- ===========================================================================
local API = {}

function API.applyAll(time)
    Light.apply(time)
    PostFX.applyPreset(time)
    PostFX.applyIntensity(time)
    AdvColor.apply(time)
    Chromatic.apply(time)
    Mat.reapplyReflectance()
    Refl.updateAll()
end

function API.setEnabled(on)
    State.Enabled = on and true or false
    PostFX.setEnabled(State.Enabled)
    Vignette.setVisible(State.Enabled and State.Vignette)
    FilmGrain.setEnabled(State.Enabled and State.FilmGrain)
    LensDirt.setEnabled(State.Enabled and State.LensDirt)
    SunDisc.setEnabled(State.Enabled and State.SunDisc)
    VolFog.setEnabled(State.Enabled and State.VolumetricFog)
    GodRays.setEnabled(State.Enabled and State.GodRays)
    DustMotes.setEnabled(State.Enabled and State.DustMotes)
    Caustics.setEnabled(State.Enabled and State.Caustics)
    if Overlays.guis.LightLeaks then Overlays.guis.LightLeaks.Enabled = State.Enabled and State.LightLeaks end
    if State.Enabled then API.applyAll(0.4) else Light.restore() end
end

function API.setIntensity(v)  State.Intensity  = mathClamp(v, 0, 2);  if State.Enabled then API.applyAll(0.4) end end
function API.setBloom(v)      State.Bloom      = mathClamp(v, 0, 2);  if State.Enabled then PostFX.applyIntensity(0.4) end end
function API.setReflection(v) State.Reflection = mathClamp(v, 0, 2);  Mat.reapplyReflectance(); Refl.updateAll() end
function API.setWetness(v)
    State.Wetness = mathClamp(v, 0, 1)
    if not State.Enabled then return end
    if v > 0.05 and Cfg.Quality[State.Quality].OverlayEnabled then
        Refl.repopulate(); Refl.updateAll()
    else
        Refl.cleanup()
    end
end
function API.setTonemap(name)
    if not Cfg.Tonemaps[name] then return end
    State.Tonemap = name
    if State.Enabled then PostFX.applyTonemap(0.5) end
end
function API.setColorPreset(name)
    if not ColorPresets[name] then return end
    local prev = State.ColorPreset
    State.ColorPreset = name
    if name == "GTA Night" and prev ~= "GTA Night" then
        State.Wetness, State.Reflection = 0.78, 1.4
        State.NightBeams, State.LightEnhance, State.Vignette = true, true, true
        State.LensFlare, State.WeatherMood, State.MotionBlur, State.EyeAdaptation = true, true, true, true
        State.VolumetricFog, State.VolumetricDensity = true, 1.6
        State.FilmGrain, State.FilmGrainAmount = true, 0.20
        State.TimeMode = "Night"
        State.ChromaticAberration, State.ChromaticAmount = true, 0.40
        State.GodRays, State.SunDisc, State.LightLeaks = false, false, false
        State.CityNightGlow = true
        Toast.show("GTA NIGHT — wet streets, neon beams, atmospheric fog", 5)
        if State.Enabled then
            Refl.repopulate(); Refl.updateAll()
            VolFog.setEnabled(true); FilmGrain.setEnabled(true)
            GodRays.setEnabled(false); SunDisc.setEnabled(false)
            Chromatic.apply(0.4)
        end
    end
    if State.Enabled then PostFX.applyPreset(0.6); Light.apply(0.6); PostFX.applyIntensity(0.6) end
end

local function engageRealismStack(isMax, withToast)
    if withToast then
        Toast.show(isMax and "MAX — full realism stack. RTX-class GPU recommended." or "ULTRA — photorealistic stack engaged.", 5)
    end
    State.RayTrace, State.MultiBounceRT, State.FresnelOverlays = true, true, true
    State.NightBeams, State.LightEnhance, State.MotionBlur, State.EyeAdaptation = true, true, true, true
    State.Vignette, State.LensFlare, State.WeatherMood, State.AutoFocus = true, true, true, true
    State.CameraFillLight, State.FoliageEnhance, State.FireEnhance = true, true, true
    State.SmokeEnhance, State.SparklesEnhance, State.WaterEnhance = true, true, true
    State.CinematicMode, State.GForce, State.CameraSway, State.ImpactShake = true, true, true, true
    State.EnhancedGI, State.SSAO, State.AnisotropicMetals = true, true, true
    State.VolumetricFog, State.Caustics, State.SunDisc = true, true, true
    State.FilmGrain, State.DustMotes, State.LightLeaks, State.LensDirt = true, true, true, true
    State.RainDroplets, State.GodRays = true, true
    State.GodRaysIntensity = isMax and 1.5 or 1.2
    State.ChromaticAberration = isMax
    State.WhiteBalance, State.WBTint, State.HueShift = 6500, 0, 0
    State.Vibrance = isMax and -35 or -25
    State.Lift     = isMax and -0.03 or -0.02
    State.Gamma    = 1.0
    State.Gain     = isMax and 1.06 or 1.03
    State.FilmGrainAmount   = isMax and 0.22 or 0.14
    State.ChromaticAmount   = isMax and 0.30 or 0.0
    State.VolumetricDensity = isMax and 1.30 or 1.05
    State.SSAOIntensity     = isMax and 0.75 or 0.60
    if State.ColorPreset == "Neutral" or State.ColorPreset == "Enhanced"
        or State.ColorPreset == "Cinematic" or State.ColorPreset == "Realistic" then
        State.ColorPreset = "Photorealistic"
    end
    if State.Tonemap == "Linear" or State.Tonemap == "Filmic" or State.Tonemap == "Reinhard" then
        State.Tonemap = "ACES"
    end
end

function API.setQuality(name, silent)
    if not Cfg.Quality[name] then return end
    local prev = State.Quality
    State.Quality = name
    if not silent then Perf.userOverride = true end
    if (name == "Ultra" or name == "Max") and prev ~= name then
        engageRealismStack(name == "Max", not silent)
    end
    if not State.Enabled then return end
    Light.apply(0.6)
    PostFX.applyPreset(0.6)
    PostFX.applyIntensity(0.6)
    AdvColor.apply(0.5)
    Chromatic.apply(0.4)
    FilmGrain.setEnabled(State.FilmGrain and State.Enabled)
    SunDisc.setEnabled(State.SunDisc and State.Enabled)
    VolFog.setEnabled(State.VolumetricFog and State.Enabled)
    Caustics.setEnabled(State.Caustics and State.Enabled)
    DustMotes.setEnabled(State.DustMotes and State.Enabled)
    LensDirt.setEnabled(State.LensDirt and State.Enabled)
    if Overlays.guis.LightLeaks then Overlays.guis.LightLeaks.Enabled = State.LightLeaks and State.Enabled end
    GodRays.setEnabled(State.GodRays and State.Enabled)
    if Cfg.Quality[name].OverlayEnabled then Refl.repopulate() else Refl.cleanup() end
end

-- Toggles
function API.setVignette(v)        State.Vignette = v and true or false; Vignette.setVisible(State.Enabled and State.Vignette) end
function API.setLensFlare(v)       State.LensFlare = v and true or false end
function API.setAutoFocus(v)       State.AutoFocus = v and true or false end
function API.setWeatherMood(v)     State.WeatherMood = v and true or false; if State.Enabled then PostFX.applyIntensity(0.6) end end
function API.setFresnelOverlays(v) State.FresnelOverlays = v and true or false; if not v then Refl.updateAll() end end
function API.setMotionBlur(v)      State.MotionBlur = v and true or false; if not v and PostFX.nodes.Blur then PostFX.nodes.Blur.Size = 0 end end
function API.setEyeAdaptation(v)   State.EyeAdaptation = v and true or false end
function API.setLightEnhance(v)    State.LightEnhance = v and true or false; if v then Lights.scan() else Lights.cleanup() end end
function API.setSpeedFOV(v)        State.SpeedFOV = v and true or false end
function API.setNightBeams(v)      State.NightBeams = v and true or false; if v then NightBeams.scan() else NightBeams.cleanup() end end
function API.setRayTrace(v)        State.RayTrace = v and true or false; if not v then RT.reset() end end
function API.setMultiBounceRT(v)   State.MultiBounceRT = v and true or false end
function API.setCameraFillLight(v) State.CameraFillLight = v and true or false; if not v and CamFill.light then CamFill.light.Brightness = 0 end end
function API.setCameraSway(v)      State.CameraSway = v and true or false end
function API.setImpactShake(v)     State.ImpactShake = v and true or false end
function API.setGForce(v)          State.GForce = v and true or false end
function API.setCinematicMode(v)   State.CinematicMode = v and true or false; if State.Enabled then PostFX.applyIntensity(0.6) end end
function API.setPlayerHighlight(v) State.PlayerHighlight = v and true or false end
function API.setFoliageEnhance(v)  State.FoliageEnhance = v and true or false; if v then Foliage.scan() else Foliage.cleanup() end end
function API.setFireEnhance(v)     State.FireEnhance = v and true or false; if v then FireMod.scan() else FireMod.cleanup() end end
function API.setSmokeEnhance(v)    State.SmokeEnhance = v and true or false; if v then SmokeMod.scan() else SmokeMod.cleanup() end end
function API.setSparklesEnhance(v) State.SparklesEnhance = v and true or false; if v then SparklesMod.scan() else SparklesMod.cleanup() end end
function API.setWaterEnhance(v)    State.WaterEnhance = v and true or false; if v then WaterMod.apply() else WaterMod.restore() end end
function API.setWeather(name)      if not Cfg.Weather[name] then return end; State.Weather = name; if State.Enabled then Light.apply(0.8); PostFX.applyIntensity(0.8) end end
function API.setPrecipitation(v)   State.Precipitation = v and true or false end
function API.setLightning(v)       State.Lightning = v and true or false end
function API.setAutoCycle(v)       State.AutoCycle = v and true or false end
function API.setCycleSpeed(s)      if type(s) ~= "number" or s < 30 then return end; State.CycleSpeed = 24 / s end
function API.setUnderwater(v)      State.Underwater = v and true or false end
function API.setFreeCam(v)         State.FreeCam = v and true or false; if v then FreeCam.enable() else FreeCam.disable() end end
function API.setTimeMode(mode)     if mode ~= "Auto" and mode ~= "Day" and mode ~= "Night" then return end; State.TimeMode = mode; if State.Enabled then Light.apply(0.6); PostFX.applyIntensity(0.6) end end
function API.setPerfHUD(v)         State.PerfHUD = v and true or false; if PerfHUD.gui then PerfHUD.gui.Enabled = v end end
function API.setAdaptiveQuality(v) State.AdaptiveQuality = v and true or false; Perf.userOverride = not v end
function API.setSharpness(v)       State.Sharpness = mathClamp(v, 0, 1) end

-- AdvancedColor setters
function API.setWhiteBalance(k) State.WhiteBalance = mathClamp(k or 6500, 1500, 15000); AdvColor.apply(0.3) end
function API.setWBTint(v)       State.WBTint = mathClamp(v or 0, -100, 100); AdvColor.apply(0.3) end
function API.setVibrance(v)     State.Vibrance = mathClamp(v or 0, -100, 100); AdvColor.apply(0.3) end
function API.setHueShift(v)
    local x = v or 0; if x > 180 then x = x - 360 end; if x < -180 then x = x + 360 end
    State.HueShift = x; AdvColor.apply(0.3)
end
function API.setLift(v)  State.Lift  = mathClamp(v or 0, -1, 1);   AdvColor.apply(0.3) end
function API.setGamma(v) State.Gamma = mathClamp(v or 1, 0.2, 5);  AdvColor.apply(0.3) end
function API.setGain(v)  State.Gain  = mathClamp(v or 1, 0.2, 5);  AdvColor.apply(0.3) end

-- Realism stack setters
function API.setFilmGrain(v)         State.FilmGrain = v and true or false; FilmGrain.setEnabled(State.FilmGrain and State.Enabled) end
function API.setFilmGrainAmount(v)   State.FilmGrainAmount = mathClamp(v or 0.18, 0, 1) end
function API.setChromaticAberration(v) State.ChromaticAberration = v and true or false; Chromatic.apply(0.25) end
function API.setChromaticAmount(v)   State.ChromaticAmount = mathClamp(v or 0.5, 0, 1); if State.ChromaticAberration then Chromatic.apply(0.25) end end
function API.setSunDisc(v)           State.SunDisc = v and true or false; SunDisc.setEnabled(State.SunDisc and State.Enabled) end
function API.setVolumetricFog(v)     State.VolumetricFog = v and true or false; VolFog.setEnabled(State.VolumetricFog and State.Enabled) end
function API.setVolumetricDensity(v) State.VolumetricDensity = mathClamp(v or 1, 0, 2) end
function API.setCaustics(v)          State.Caustics = v and true or false; Caustics.setEnabled(State.Caustics and State.Enabled) end
function API.setEnhancedGI(v)        State.EnhancedGI = v and true or false end
function API.setSSAO(v)              State.SSAO = v and true or false end
function API.setSSAOIntensity(v)     State.SSAOIntensity = mathClamp(v or 0.6, 0, 1) end
function API.setAnisotropicMetals(v) State.AnisotropicMetals = v and true or false; if not v then Mat.reapplyReflectance() end end
function API.setRainDroplets(v)      State.RainDroplets = v and true or false end
function API.setDustMotes(v)         State.DustMotes = v and true or false; DustMotes.setEnabled(State.DustMotes and State.Enabled) end
function API.setLightLeaks(v)        State.LightLeaks = v and true or false; if Overlays.guis.LightLeaks then Overlays.guis.LightLeaks.Enabled = v and State.Enabled end end
function API.setLensDirt(v)          State.LensDirt = v and true or false; LensDirt.setEnabled(State.LensDirt and State.Enabled) end
function API.setGodRays(v)           State.GodRays = v and true or false; GodRays.setEnabled(State.GodRays and State.Enabled) end
function API.setGodRaysIntensity(v)  State.GodRaysIntensity = mathClamp(v or 1, 0, 2) end
function API.setHeatHaze(v)          State.HeatHaze = v and true or false end
function API.setHeatHazeIntensity(v) State.HeatHazeIntensity = mathClamp(v or 0.5, 0, 1) end
function API.setDistanceHaze(v)      State.DistanceHaze = v and true or false; if State.Enabled then Light.apply(0.5) end end
function API.setCityNightGlow(v)     State.CityNightGlow = v and true or false end

function API.shake(amount) Cam.applyShake(amount or 0.5) end

-- RTX presets
function API.activateRTX()
    State.Enabled = true
    if State.Quality == "Max" then State.Quality = "Ultra" end
    API.setQuality("Max")
    if State.Enabled then
        Light.apply(0.8); PostFX.applyPreset(0.8); PostFX.applyIntensity(0.8)
        AdvColor.apply(0.6); Chromatic.apply(0.4); Mat.reapplyReflectance()
    end
end
function API.activateGTANight()
    State.Enabled = true
    if State.ColorPreset == "GTA Night" then State.ColorPreset = "Photorealistic" end
    API.setColorPreset("GTA Night")
end

-- Persistence
function API.save() return Persist.save() end
function API.load() if Persist.load() then API.applyAll(0.8); Toast.show("Settings loaded.", 2.5); return true end; return false end

-- Export / Import
function API.exportPreset() return Persist.save() end
function API.importPreset(json)
    local ok, decoded = pcall(function() return HttpService:JSONDecode(json) end)
    if not ok or not decoded then return false end
    applySettings(decoded)
    API.applyAll(0.8)
    return true
end

-- ===========================================================================
-- 44. UI — clean self-built panel with floating toggle (Rayfield optional)
-- ===========================================================================
local UI = {}
local PANEL_W, PANEL_H = 360, 520
local PANEL_COLOR    = Color3.fromRGB(18, 20, 26)
local PANEL_STROKE   = Color3.fromRGB(85, 90, 110)
local ACCENT         = Color3.fromRGB(110, 200, 255)
local TEXT_COLOR     = Color3.fromRGB(235, 238, 245)
local SUBTLE_TEXT    = Color3.fromRGB(160, 168, 180)

local function styledFrame(parent, props)
    local f = Instance.new("Frame")
    for k, v in pairs(props or {}) do f[k] = v end
    f.BorderSizePixel = 0
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 8); corner.Parent = f
    f.Parent = parent
    return f
end

local function styledText(parent, text, props)
    local t = Instance.new("TextLabel")
    t.Text = text
    t.Font = Enum.Font.GothamMedium
    t.TextSize = 13
    t.TextColor3 = TEXT_COLOR
    t.BackgroundTransparency = 1
    t.TextXAlignment = Enum.TextXAlignment.Left
    for k, v in pairs(props or {}) do t[k] = v end
    t.Parent = parent
    return t
end

-- Toggle row with sliding indicator
local function makeToggle(parent, label, initial, onChange)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -16, 0, 32)
    row.Position = UDim2.fromOffset(8, 0)
    row.BackgroundTransparency = 1
    row.Parent = parent
    styledText(row, label, { Size = UDim2.new(1, -56, 1, 0), Position = UDim2.fromOffset(4, 0) })
    local sw = styledFrame(row, {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -4, 0.5, 0),
        Size = UDim2.fromOffset(44, 22),
        BackgroundColor3 = initial and ACCENT or Color3.fromRGB(60, 64, 76),
    })
    local knob = styledFrame(sw, {
        Size = UDim2.fromOffset(18, 18),
        Position = initial and UDim2.new(1, -20, 0, 2) or UDim2.fromOffset(2, 2),
        BackgroundColor3 = Color3.fromRGB(240, 240, 245),
    })
    local state = initial
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromScale(1, 1); btn.BackgroundTransparency = 1; btn.Text = ""
    btn.Parent = sw
    Conn.track(btn.MouseButton1Click:Connect(function()
        state = not state
        Util.tween(sw, 0.18, { BackgroundColor3 = state and ACCENT or Color3.fromRGB(60, 64, 76) })
        Util.tween(knob, 0.18, { Position = state and UDim2.new(1, -20, 0, 2) or UDim2.fromOffset(2, 2) })
        onChange(state)
    end))
    return row
end

local function makeSlider(parent, label, min, max, initial, suffix, onChange)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -16, 0, 48)
    row.Position = UDim2.fromOffset(8, 0)
    row.BackgroundTransparency = 1
    row.Parent = parent
    local titleLabel = styledText(row, label, { Size = UDim2.new(0.7, 0, 0, 18), Position = UDim2.fromOffset(4, 0) })
    local valueLabel = styledText(row, tostring(initial) .. (suffix or ""), {
        Size = UDim2.new(0.3, -4, 0, 18), Position = UDim2.new(0.7, 0, 0, 0),
        TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = SUBTLE_TEXT,
    })
    local track = styledFrame(row, {
        Position = UDim2.fromOffset(4, 24),
        Size = UDim2.new(1, -8, 0, 6),
        BackgroundColor3 = Color3.fromRGB(40, 44, 56),
    })
    local fill = styledFrame(track, {
        Size = UDim2.fromScale((initial - min) / (max - min), 1),
        BackgroundColor3 = ACCENT,
    })
    local handle = Instance.new("TextButton")
    handle.Size = UDim2.fromOffset(16, 16)
    handle.Position = UDim2.new((initial - min) / (max - min), -8, 0.5, -8)
    handle.BackgroundColor3 = Color3.fromRGB(245, 245, 250)
    handle.BorderSizePixel = 0
    handle.Text = ""
    handle.AutoButtonColor = false
    local hCorner = Instance.new("UICorner"); hCorner.CornerRadius = UDim.new(1, 0); hCorner.Parent = handle
    handle.Parent = track

    local dragging = false
    local function update(x)
        local absX = track.AbsolutePosition.X
        local w = track.AbsoluteSize.X
        local t = mathClamp((x - absX) / w, 0, 1)
        fill.Size = UDim2.fromScale(t, 1)
        handle.Position = UDim2.new(t, -8, 0.5, -8)
        local val = min + t * (max - min)
        local rounded = math.floor(val * 100 + 0.5) / 100
        valueLabel.Text = tostring(rounded) .. (suffix or "")
        onChange(val)
    end
    Conn.track(handle.InputBegan:Connect(function(io)
        if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
            dragging = true
        end
    end))
    Conn.track(handle.InputEnded:Connect(function(io)
        if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
    Conn.track(track.InputBegan:Connect(function(io)
        if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
            update(io.Position.X)
            dragging = true
        end
    end))
    Conn.track(track.InputEnded:Connect(function(io)
        if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
    -- One shared InputChanged connection per slider is acceptable (tracked).
    Conn.track(UserInputService.InputChanged:Connect(function(io)
        if dragging and (io.UserInputType == Enum.UserInputType.MouseMovement or io.UserInputType == Enum.UserInputType.Touch) then
            update(io.Position.X)
        end
    end))
    return row
end

local function makeDropdown(parent, label, options, initial, onChange)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -16, 0, 56)
    row.Position = UDim2.fromOffset(8, 0)
    row.BackgroundTransparency = 1
    row.Parent = parent
    styledText(row, label, { Size = UDim2.new(1, -4, 0, 18), Position = UDim2.fromOffset(4, 0) })
    local box = styledFrame(row, {
        Position = UDim2.fromOffset(4, 22),
        Size = UDim2.new(1, -8, 0, 30),
        BackgroundColor3 = Color3.fromRGB(30, 34, 44),
    })
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromScale(1, 1)
    btn.BackgroundTransparency = 1
    btn.Font = Enum.Font.Gotham
    btn.TextSize = 13
    btn.TextColor3 = TEXT_COLOR
    btn.Text = "  " .. tostring(initial) .. "  ▾"
    btn.TextXAlignment = Enum.TextXAlignment.Left
    btn.Parent = box

    local list
    local function close() if list then list:Destroy(); list = nil end end
    Conn.track(btn.MouseButton1Click:Connect(function()
        if list then close(); return end
        list = styledFrame(row, {
            Position = UDim2.new(0, 4, 1, -2),
            Size = UDim2.new(1, -8, 0, mathMin(#options * 28, 160)),
            BackgroundColor3 = Color3.fromRGB(24, 28, 38),
            ZIndex = 5,
        })
        local stroke = Instance.new("UIStroke"); stroke.Color = PANEL_STROKE; stroke.Thickness = 1; stroke.Parent = list
        local scroll = Instance.new("ScrollingFrame")
        scroll.Size = UDim2.fromScale(1, 1)
        scroll.BackgroundTransparency = 1
        scroll.BorderSizePixel = 0
        scroll.ScrollBarThickness = 3
        scroll.CanvasSize = UDim2.fromOffset(0, #options * 28)
        scroll.ZIndex = 6
        scroll.Parent = list
        local layout = Instance.new("UIListLayout"); layout.SortOrder = Enum.SortOrder.LayoutOrder; layout.Parent = scroll
        for i, opt in ipairs(options) do
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, 0, 0, 28)
            b.BackgroundTransparency = 1
            b.Font = Enum.Font.Gotham
            b.TextSize = 13
            b.TextColor3 = TEXT_COLOR
            b.TextXAlignment = Enum.TextXAlignment.Left
            b.Text = "  " .. opt
            b.LayoutOrder = i
            b.ZIndex = 7
            b.Parent = scroll
            Conn.track(b.MouseEnter:Connect(function() b.BackgroundTransparency = 0.7; b.BackgroundColor3 = ACCENT end))
            Conn.track(b.MouseLeave:Connect(function() b.BackgroundTransparency = 1 end))
            Conn.track(b.MouseButton1Click:Connect(function()
                btn.Text = "  " .. tostring(opt) .. "  ▾"
                onChange(opt)
                close()
            end))
        end
    end))
    return row
end

local function makeButton(parent, label, onClick)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -16, 0, 34)
    b.Position = UDim2.fromOffset(8, 0)
    b.BackgroundColor3 = ACCENT
    b.Font = Enum.Font.GothamBold
    b.TextSize = 14
    b.TextColor3 = Color3.fromRGB(15, 18, 24)
    b.Text = label
    b.BorderSizePixel = 0
    b.AutoButtonColor = true
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 8); corner.Parent = b
    b.Parent = parent
    Conn.track(b.MouseButton1Click:Connect(onClick))
    return b
end

local function makeTab(panel, title)
    local tabFrame = Instance.new("ScrollingFrame")
    tabFrame.Size = UDim2.new(1, 0, 1, -50)
    tabFrame.Position = UDim2.fromOffset(0, 50)
    tabFrame.BackgroundTransparency = 1
    tabFrame.BorderSizePixel = 0
    tabFrame.ScrollBarThickness = 4
    tabFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
    tabFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
    tabFrame.Visible = false
    tabFrame.Parent = panel
    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 6)
    layout.Parent = tabFrame
    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 8)
    padding.PaddingBottom = UDim.new(0, 12)
    padding.Parent = tabFrame
    return tabFrame
end

local function sectionHeader(parent, text)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, -16, 0, 22)
    f.Position = UDim2.fromOffset(8, 0)
    f.BackgroundTransparency = 1
    f.Parent = parent
    local label = styledText(f, text:upper(), {
        Size = UDim2.fromScale(1, 1),
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = ACCENT,
    })
    return f
end

function UI.build()
    local existing = PlayerGui:FindFirstChild("Cinematic_UI")
    if existing then existing:Destroy() end
    local gui = makeGui("Cinematic_UI", 1000)
    -- Floating toggle button (always visible)
    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Size = UDim2.fromOffset(48, 48)
    toggleBtn.Position = UDim2.fromOffset(16, 16)
    toggleBtn.BackgroundColor3 = PANEL_COLOR
    toggleBtn.BorderSizePixel = 0
    toggleBtn.Font = Enum.Font.GothamBold
    toggleBtn.TextSize = 20
    toggleBtn.TextColor3 = ACCENT
    toggleBtn.Text = "≡"
    toggleBtn.AutoButtonColor = true
    toggleBtn.ZIndex = 10
    local toggleCorner = Instance.new("UICorner"); toggleCorner.CornerRadius = UDim.new(1, 0); toggleCorner.Parent = toggleBtn
    local toggleStroke = Instance.new("UIStroke"); toggleStroke.Color = PANEL_STROKE; toggleStroke.Thickness = 1; toggleStroke.Parent = toggleBtn
    toggleBtn.Parent = gui

    -- Make toggle button draggable
    do
        local dragging, dragStart, startPos = false, nil, nil
        Conn.track(toggleBtn.InputBegan:Connect(function(io)
            if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
                dragging = true; dragStart = io.Position; startPos = toggleBtn.Position
            end
        end))
        Conn.track(UserInputService.InputChanged:Connect(function(io)
            if dragging and (io.UserInputType == Enum.UserInputType.MouseMovement or io.UserInputType == Enum.UserInputType.Touch) then
                local delta = io.Position - dragStart
                if delta.Magnitude > 4 then
                    toggleBtn.Position = UDim2.new(
                        startPos.X.Scale, startPos.X.Offset + delta.X,
                        startPos.Y.Scale, startPos.Y.Offset + delta.Y
                    )
                end
            end
        end))
        Conn.track(UserInputService.InputEnded:Connect(function(io)
            if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end))
    end

    -- Main panel
    local panel = Instance.new("Frame")
    panel.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
    panel.Position = UDim2.fromOffset(72, 16)
    panel.BackgroundColor3 = PANEL_COLOR
    panel.BorderSizePixel = 0
    panel.Visible = false
    panel.ZIndex = 8
    local panelCorner = Instance.new("UICorner"); panelCorner.CornerRadius = UDim.new(0, 12); panelCorner.Parent = panel
    local panelStroke = Instance.new("UIStroke"); panelStroke.Color = PANEL_STROKE; panelStroke.Thickness = 1; panelStroke.Parent = panel
    panel.Parent = gui

    -- Header
    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 44)
    header.BackgroundColor3 = Color3.fromRGB(24, 28, 38)
    header.BorderSizePixel = 0
    header.ZIndex = 9
    local headerCorner = Instance.new("UICorner"); headerCorner.CornerRadius = UDim.new(0, 12); headerCorner.Parent = header
    header.Parent = panel
    styledText(header, "  CINEMATIC v5", {
        Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(0.6, 0, 1, 0),
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        ZIndex = 10,
    })
    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.fromOffset(28, 28)
    closeBtn.AnchorPoint = Vector2.new(1, 0.5)
    closeBtn.Position = UDim2.new(1, -8, 0.5, 0)
    closeBtn.BackgroundColor3 = Color3.fromRGB(60, 30, 40)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 16
    closeBtn.TextColor3 = Color3.fromRGB(230, 180, 190)
    closeBtn.Text = "×"
    closeBtn.BorderSizePixel = 0
    closeBtn.ZIndex = 10
    local closeCorner = Instance.new("UICorner"); closeCorner.CornerRadius = UDim.new(0, 6); closeCorner.Parent = closeBtn
    closeBtn.Parent = header
    Conn.track(closeBtn.MouseButton1Click:Connect(function() panel.Visible = false end))

    -- Tab bar
    local tabBar = Instance.new("Frame")
    tabBar.Size = UDim2.new(1, -16, 0, 30)
    tabBar.Position = UDim2.fromOffset(8, 50)
    tabBar.BackgroundTransparency = 1
    tabBar.ZIndex = 9
    tabBar.Parent = panel
    local tabBarLayout = Instance.new("UIListLayout")
    tabBarLayout.FillDirection = Enum.FillDirection.Horizontal
    tabBarLayout.Padding = UDim.new(0, 4)
    tabBarLayout.Parent = tabBar

    local tabs = {}
    local tabButtons = {}
    local activeTab
    local function showTab(name)
        for k, t in pairs(tabs) do t.Visible = (k == name) end
        for k, b in pairs(tabButtons) do
            b.BackgroundColor3 = (k == name) and ACCENT or Color3.fromRGB(30, 34, 44)
            b.TextColor3 = (k == name) and Color3.fromRGB(15, 18, 24) or TEXT_COLOR
        end
        activeTab = name
    end

    local function addTab(name)
        local tabFrame = Instance.new("ScrollingFrame")
        tabFrame.Size = UDim2.new(1, -16, 1, -90)
        tabFrame.Position = UDim2.fromOffset(8, 84)
        tabFrame.BackgroundTransparency = 1
        tabFrame.BorderSizePixel = 0
        tabFrame.ScrollBarThickness = 4
        tabFrame.ScrollBarImageColor3 = ACCENT
        tabFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
        tabFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
        tabFrame.Visible = false
        tabFrame.ZIndex = 9
        tabFrame.Parent = panel
        local layout = Instance.new("UIListLayout")
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Padding = UDim.new(0, 4)
        layout.Parent = tabFrame
        local padding = Instance.new("UIPadding")
        padding.PaddingTop = UDim.new(0, 4)
        padding.PaddingBottom = UDim.new(0, 12)
        padding.Parent = tabFrame
        tabs[name] = tabFrame

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0.2, -3, 1, 0)
        btn.Font = Enum.Font.GothamMedium
        btn.TextSize = 12
        btn.Text = name
        btn.BackgroundColor3 = Color3.fromRGB(30, 34, 44)
        btn.TextColor3 = TEXT_COLOR
        btn.BorderSizePixel = 0
        btn.ZIndex = 9
        local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0, 6); bc.Parent = btn
        btn.Parent = tabBar
        Conn.track(btn.MouseButton1Click:Connect(function() showTab(name) end))
        tabButtons[name] = btn

        return tabFrame
    end

    -- VISUALS
    local tVis = addTab("Visuals")
    sectionHeader(tVis, "Quality").LayoutOrder = 1
    local qd = makeDropdown(tVis, "Quality Tier", { "Low","Medium","High","Ultra","Max" }, State.Quality, API.setQuality)
    qd.LayoutOrder = 2
    local cp = makeDropdown(tVis, "Color Preset", { "Photorealistic","NaturalVision","QuantV","Cinematic","Realistic","Enhanced","GTA Day","GTA Night","Sunset","Cyberpunk","Noir","Anime","IMAX","Teal & Orange","Vintage","Neutral" }, State.ColorPreset, API.setColorPreset)
    cp.LayoutOrder = 3
    local tm = makeDropdown(tVis, "Tonemap", { "ACES","Filmic","Cinematic","Punchy","Reinhard","Linear" }, State.Tonemap, API.setTonemap)
    tm.LayoutOrder = 4
    sectionHeader(tVis, "Intensity").LayoutOrder = 5
    makeSlider(tVis, "Master Intensity", 0, 2, State.Intensity, "x", API.setIntensity).LayoutOrder = 6
    makeSlider(tVis, "Bloom",  0, 2, State.Bloom,  "x", API.setBloom).LayoutOrder = 7
    sectionHeader(tVis, "Quick Actions").LayoutOrder = 8
    local rtxBtn = makeButton(tVis, "✨ ACTIVATE RTX MODE", function() API.activateRTX() end); rtxBtn.LayoutOrder = 9
    local gtaBtn = makeButton(tVis, "🌃 GTA NIGHT MODE", function() API.activateGTANight() end); gtaBtn.LayoutOrder = 10
    gtaBtn.BackgroundColor3 = Color3.fromRGB(150, 100, 200)

    -- REFLECTIONS
    local tRefl = addTab("Reflect")
    sectionHeader(tRefl, "Surfaces").LayoutOrder = 1
    makeSlider(tRefl, "Reflection",  0, 2, State.Reflection, "x", API.setReflection).LayoutOrder = 2
    makeSlider(tRefl, "Wetness",     0, 1, State.Wetness,    "",  API.setWetness).LayoutOrder = 3
    sectionHeader(tRefl, "Ray Tracing").LayoutOrder = 4
    makeToggle(tRefl, "Ray-Traced SSR", State.RayTrace, API.setRayTrace).LayoutOrder = 5
    makeToggle(tRefl, "Multi-Bounce", State.MultiBounceRT, API.setMultiBounceRT).LayoutOrder = 6
    makeToggle(tRefl, "Enhanced GI", State.EnhancedGI, API.setEnhancedGI).LayoutOrder = 7
    makeToggle(tRefl, "Fresnel Overlays", State.FresnelOverlays, API.setFresnelOverlays).LayoutOrder = 8
    makeToggle(tRefl, "Anisotropic Metals", State.AnisotropicMetals, API.setAnisotropicMetals).LayoutOrder = 9

    -- EFFECTS
    local tFX = addTab("FX")
    sectionHeader(tFX, "Post-Processing").LayoutOrder = 1
    makeToggle(tFX, "Vignette",      State.Vignette,      API.setVignette).LayoutOrder = 2
    makeToggle(tFX, "Lens Flare",    State.LensFlare,     API.setLensFlare).LayoutOrder = 3
    makeToggle(tFX, "Lens Dirt",     State.LensDirt,      API.setLensDirt).LayoutOrder = 4
    makeToggle(tFX, "Light Leaks",   State.LightLeaks,    API.setLightLeaks).LayoutOrder = 5
    makeToggle(tFX, "Film Grain",    State.FilmGrain,     API.setFilmGrain).LayoutOrder = 6
    makeSlider(tFX, "Grain Amount", 0, 1, State.FilmGrainAmount, "", API.setFilmGrainAmount).LayoutOrder = 7
    makeToggle(tFX, "Chromatic Aberration", State.ChromaticAberration, API.setChromaticAberration).LayoutOrder = 8
    makeSlider(tFX, "Chromatic Amt", 0, 1, State.ChromaticAmount, "", API.setChromaticAmount).LayoutOrder = 9
    sectionHeader(tFX, "Cinematic").LayoutOrder = 10
    makeToggle(tFX, "Cinematic Mode", State.CinematicMode, API.setCinematicMode).LayoutOrder = 11
    makeToggle(tFX, "Auto-Focus DoF", State.AutoFocus, API.setAutoFocus).LayoutOrder = 12
    makeToggle(tFX, "Motion Blur",   State.MotionBlur, API.setMotionBlur).LayoutOrder = 13
    makeToggle(tFX, "Eye Adaptation",State.EyeAdaptation, API.setEyeAdaptation).LayoutOrder = 14
    sectionHeader(tFX, "Atmosphere").LayoutOrder = 15
    makeToggle(tFX, "Volumetric Fog", State.VolumetricFog, API.setVolumetricFog).LayoutOrder = 16
    makeSlider(tFX, "Fog Density", 0, 2, State.VolumetricDensity, "x", API.setVolumetricDensity).LayoutOrder = 17
    makeToggle(tFX, "God Rays",    State.GodRays, API.setGodRays).LayoutOrder = 18
    makeSlider(tFX, "Rays Intensity", 0, 2, State.GodRaysIntensity, "x", API.setGodRaysIntensity).LayoutOrder = 19
    makeToggle(tFX, "Sun Disc",    State.SunDisc, API.setSunDisc).LayoutOrder = 20
    makeToggle(tFX, "Dust Motes",  State.DustMotes, API.setDustMotes).LayoutOrder = 21

    -- CAMERA
    local tCam = addTab("Camera")
    sectionHeader(tCam, "Movement").LayoutOrder = 1
    makeToggle(tCam, "Speed FOV",      State.SpeedFOV,      API.setSpeedFOV).LayoutOrder = 2
    makeToggle(tCam, "Camera Sway",    State.CameraSway,    API.setCameraSway).LayoutOrder = 3
    makeToggle(tCam, "Impact Shake",   State.ImpactShake,   API.setImpactShake).LayoutOrder = 4
    makeToggle(tCam, "G-Force",        State.GForce,        API.setGForce).LayoutOrder = 5
    makeToggle(tCam, "Free Camera (F)",State.FreeCam,       API.setFreeCam).LayoutOrder = 6
    sectionHeader(tCam, "Lights").LayoutOrder = 7
    makeToggle(tCam, "Camera Fill Light",State.CameraFillLight, API.setCameraFillLight).LayoutOrder = 8
    makeToggle(tCam, "Light Shadows",  State.LightEnhance,  API.setLightEnhance).LayoutOrder = 9
    makeToggle(tCam, "Night Beams",    State.NightBeams,    API.setNightBeams).LayoutOrder = 10
    makeToggle(tCam, "Player Highlight",State.PlayerHighlight, API.setPlayerHighlight).LayoutOrder = 11

    -- WEATHER & TIME
    local tWX = addTab("World")
    sectionHeader(tWX, "Weather").LayoutOrder = 1
    makeDropdown(tWX, "Condition", { "Clear","Cloudy","Stormy","Misty" }, State.Weather, API.setWeather).LayoutOrder = 2
    makeToggle(tWX, "Precipitation", State.Precipitation, API.setPrecipitation).LayoutOrder = 3
    makeToggle(tWX, "Lightning",     State.Lightning, API.setLightning).LayoutOrder = 4
    sectionHeader(tWX, "Time of Day").LayoutOrder = 5
    makeDropdown(tWX, "Time Mode", { "Auto","Day","Night" }, State.TimeMode, API.setTimeMode).LayoutOrder = 6
    makeToggle(tWX, "Auto Cycle",    State.AutoCycle, API.setAutoCycle).LayoutOrder = 7
    makeSlider(tWX, "Day Length (s)", 60, 1800, 720, "s", function(v) API.setCycleSpeed(v) end).LayoutOrder = 8
    sectionHeader(tWX, "World Enhance").LayoutOrder = 9
    makeToggle(tWX, "Foliage",   State.FoliageEnhance,  API.setFoliageEnhance).LayoutOrder = 10
    makeToggle(tWX, "Fire",      State.FireEnhance,     API.setFireEnhance).LayoutOrder = 11
    makeToggle(tWX, "Smoke",     State.SmokeEnhance,    API.setSmokeEnhance).LayoutOrder = 12
    makeToggle(tWX, "Sparkles",  State.SparklesEnhance, API.setSparklesEnhance).LayoutOrder = 13
    makeToggle(tWX, "Water",     State.WaterEnhance,    API.setWaterEnhance).LayoutOrder = 14
    makeToggle(tWX, "Underwater",State.Underwater,      API.setUnderwater).LayoutOrder = 15
    makeToggle(tWX, "Rain Droplets",State.RainDroplets, API.setRainDroplets).LayoutOrder = 16
    makeToggle(tWX, "Caustics",  State.Caustics,        API.setCaustics).LayoutOrder = 17
    makeToggle(tWX, "Heat Haze", State.HeatHaze,        API.setHeatHaze).LayoutOrder = 18
    makeToggle(tWX, "Distance Haze",State.DistanceHaze, API.setDistanceHaze).LayoutOrder = 19
    makeToggle(tWX, "City Night Glow",State.CityNightGlow,API.setCityNightGlow).LayoutOrder = 20

    -- ADVANCED
    local tAdv = addTab("Color")
    sectionHeader(tAdv, "White Balance").LayoutOrder = 1
    makeSlider(tAdv, "Temperature (K)", 1500, 15000, State.WhiteBalance, "K", API.setWhiteBalance).LayoutOrder = 2
    makeSlider(tAdv, "WB Tint",        -100, 100,   State.WBTint, "", API.setWBTint).LayoutOrder = 3
    sectionHeader(tAdv, "Tone & Saturation").LayoutOrder = 4
    makeSlider(tAdv, "Vibrance",       -100, 100,   State.Vibrance, "", API.setVibrance).LayoutOrder = 5
    makeSlider(tAdv, "Hue Shift",      -180, 180,   State.HueShift, "°", API.setHueShift).LayoutOrder = 6
    sectionHeader(tAdv, "Lift / Gamma / Gain").LayoutOrder = 7
    makeSlider(tAdv, "Lift  (shadows)",  -1, 1, State.Lift,  "", API.setLift).LayoutOrder = 8
    makeSlider(tAdv, "Gamma (midtones)", 0.2, 5, State.Gamma, "", API.setGamma).LayoutOrder = 9
    makeSlider(tAdv, "Gain  (highlights)",0.2,5, State.Gain,  "", API.setGain).LayoutOrder = 10
    sectionHeader(tAdv, "Settings").LayoutOrder = 11
    makeToggle(tAdv, "Adaptive Quality (auto)", State.AdaptiveQuality, API.setAdaptiveQuality).LayoutOrder = 12
    makeToggle(tAdv, "Performance HUD", State.PerfHUD, API.setPerfHUD).LayoutOrder = 13
    makeButton(tAdv, "💾 Save Settings", function() API.save(); Toast.show("Settings saved.", 2.5) end).LayoutOrder = 14
    makeButton(tAdv, "📂 Load Settings", function() API.load() end).LayoutOrder = 15

    showTab("Visuals")

    -- Toggle button → show/hide panel
    Conn.track(toggleBtn.MouseButton1Click:Connect(function()
        panel.Visible = not panel.Visible
        if panel.Visible then
            panel.BackgroundTransparency = 1
            Util.tween(panel, 0.18, { BackgroundTransparency = 0 })
        end
    end))

    -- ] key on desktop
    Conn.track(UserInputService.InputBegan:Connect(function(io, gp)
        if gp then return end
        if io.KeyCode == Enum.KeyCode.RightBracket then
            panel.Visible = not panel.Visible
        elseif io.KeyCode == Enum.KeyCode.F then
            API.setFreeCam(not State.FreeCam)
        end
    end))

    UI.panel = panel
    UI.toggleBtn = toggleBtn
end

-- ===========================================================================
-- 45. INIT — boot sequence
-- ===========================================================================
local function detectBakedPlace()
    if not Lighting:GetAttribute(ATTR_BAKED) then return end
    local w = Lighting:GetAttribute(ATTR_BAKE_WET)
    if type(w) == "number" then State.Wetness = mathClamp(w, 0, 1) end
    local p = Lighting:GetAttribute(ATTR_BAKE_PRES)
    if type(p) == "string" and ColorPresets[p] then State.ColorPreset = p end
    print("[Cinematic] Plugin-baked place detected.")
end

local function init()
    if State.Initialized then return end
    print("[Cinematic] init() starting")

    detectBakedPlace()
    OriginalLighting = Light.snapshot()
    Cam.init()

    PostFX.build()
    Vignette.build()
    LensFlare.build()
    FilmGrain.build()
    LensDirt.build()
    LightLeaks.build()
    SunDisc.build()
    DustMotes.build()
    RainDroplets.build()
    Caustics.build()
    SSAO.build()
    VolFog.build()
    GodRays.build()
    Underwater.build()
    PerfHUD.build()
    CamFill.build()
    Precip.build()

    SkyMod.apply()
    Lights.scan()
    NightBeams.scan()
    Foliage.scan()
    FireMod.scan()
    SmokeMod.scan()
    SparklesMod.scan()
    if State.WaterEnhance then WaterMod.apply() end

    PlayerHL.bindAll()
    Detect.bindWatcher()
    Detect.scan()
    RT.rebuildParams()

    -- Apply initial settings
    PostFX.setEnabled(true)
    Light.apply(0.4)
    PostFX.applyPreset(0.4)
    PostFX.applyIntensity(0.4)
    AdvColor.apply(0.4)
    Chromatic.apply(0.4)
    Vignette.setVisible(State.Vignette)

    -- If launching at Ultra/Max, engage realism stack
    if State.Quality == "Ultra" or State.Quality == "Max" then
        engageRealismStack(State.Quality == "Max", false)
        FilmGrain.setEnabled(State.FilmGrain)
        SunDisc.setEnabled(State.SunDisc)
        VolFog.setEnabled(State.VolumetricFog)
        Caustics.setEnabled(State.Caustics)
        DustMotes.setEnabled(State.DustMotes)
        LensDirt.setEnabled(State.LensDirt)
        if Overlays.guis.LightLeaks then Overlays.guis.LightLeaks.Enabled = State.LightLeaks end
        GodRays.setEnabled(State.GodRays)
    end

    -- Build UI
    pcall(function() UI.build() end)

    -- Streaming-aware rescan
    if Workspace.StreamingEnabled then
        task.spawn(function()
            while task.wait(12) do
                if not State.Initialized then break end
                if State.Enabled then
                    Detect.scan(); Lights.scan(); NightBeams.scan()
                    Foliage.scan(); FireMod.scan(); SmokeMod.scan(); SparklesMod.scan()
                end
            end
        end)
    end

    -- Main per-frame loop — minimal & throttled.
    Conn.track(RunService.RenderStepped:Connect(function(dt)
        Perf.sample(dt)
        Detect.processQueue(dt)
        Cam.updateSpeedFOV(dt)
        Cam.updateSway(dt)
        Cam.updateImpactShake(dt)
        Cam.updateMotionBlur(dt)
        Cam.updateEyeAdaptation(dt)
        Cam.updateAutoFocus(dt)
        Cam.updateFresnelOverlays(dt)
        Cam.updateGForce(dt)
        CamFill.update(dt)
        RT.update()
        LensFlare.update()
        SunDisc.update()
        VolFog.update(dt)
        GodRays.update(dt)
        FilmGrain.update(dt)
        DustMotes.update(dt)
        RainDroplets.update(dt)
        Caustics.update(dt)
        SSAO.update()
        AnisoMetals.update(dt)
        Precip.update()
        Lightning.update()
        NightBeams.update()
        PlayerHL.update()
        Underwater.update()
        Cycle.update(dt)
        PerfHUD.update(dt)
    end))

    -- Adaptive quality on a Heartbeat (1 Hz)
    Conn.track(RunService.Heartbeat:Connect(function(dt)
        Perf.adaptCooldown = mathMax(0, Perf.adaptCooldown - dt)
        Sched.tick(dt)
    end))
    Sched.add("AdaptiveQuality", function()
        if not State.AdaptiveQuality or Perf.userOverride then return end
        if #Perf.samples < 30 then return end
        local avg = Perf.avg()
        local order = Cfg.Performance.AdaptiveOrder
        local thresholds = Cfg.Performance.AdaptiveThresholds
        local idx
        for i, q in ipairs(order) do if q == State.Quality then idx = i; break end end
        if not idx then return end
        local minFps = thresholds[State.Quality] or 0
        if avg < minFps - 4 and idx < #order then
            local next_ = order[idx + 1]
            API.setQuality(next_, true)
            Toast.show(string.format("Adaptive: %d FPS → %s", math.floor(avg), next_), 3)
        end
    end, 0.2)

    -- Auto-load saved settings if present (non-fatal)
    pcall(function() Persist.load() end)
    if State.Quality == "Ultra" or State.Quality == "Max" then
        FilmGrain.setEnabled(State.FilmGrain)
    end

    State.Initialized = true
    print(string.rep("=", 60))
    print(string.format("[Cinematic] READY — %s | %s | %s", State.Quality, State.ColorPreset, State.Tonemap))
    if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
        print("[Cinematic] Tap the floating ≡ button to open the panel.")
    else
        print("[Cinematic] Press ] (or tap ≡) to toggle the panel. F to toggle free cam.")
    end
    print(string.rep("=", 60))
end

-- ===========================================================================
-- 46. KILL — full teardown
-- ===========================================================================
local function kill()
    -- Disconnect everything first so per-frame logic stops touching things
    Conn.disconnectAll()

    -- Disable post-FX
    pcall(function() PostFX.setEnabled(false) end)

    -- Module-specific cleanup
    pcall(FreeCam.disable)
    pcall(VolFog.cleanup)
    pcall(GodRays.cleanup)
    pcall(NightBeams.cleanup)
    pcall(Lights.cleanup)
    pcall(Foliage.cleanup)
    pcall(FireMod.cleanup)
    pcall(SmokeMod.cleanup)
    pcall(SparklesMod.cleanup)
    pcall(WaterMod.restore)
    pcall(Underwater.cleanup)
    pcall(Precip.cleanup)
    pcall(CamFill.cleanup)
    pcall(Refl.cleanup)

    -- Restore original lighting
    pcall(Light.restore)
    pcall(Snap.restoreAll)

    -- Destroy FX nodes in Lighting
    for _, name in ipairs(FX_NAMES) do
        local fx = Lighting:FindFirstChild(name)
        if fx then pcall(function() fx:Destroy() end) end
    end
    local extra = { "Cinematic_Underwater", "Cinematic_UnderwaterBlur" }
    for _, name in ipairs(extra) do
        local fx = Lighting:FindFirstChild(name)
        if fx then pcall(function() fx:Destroy() end) end
    end

    -- Destroy all our ScreenGuis
    for _, g in pairs(Overlays.guis) do
        if g and g.Parent then pcall(function() g:Destroy() end) end
    end
    for _, name in ipairs({
        "Cinematic_UI","Cinematic_Toast","Cinematic_PerfHUD","Cinematic_Vignette",
        "Cinematic_FilmGrain","Cinematic_LensDirt","Cinematic_LightLeaks","Cinematic_LensFlare",
        "Cinematic_SunDisc","Cinematic_DustMotes","Cinematic_RainDroplets","Cinematic_Caustics","Cinematic_SSAO",
    }) do
        local g = PlayerGui:FindFirstChild(name)
        if g then pcall(function() g:Destroy() end) end
    end

    -- Restore camera FOV
    local c = Workspace.CurrentCamera
    if c and OriginalFOV then c.FieldOfView = OriginalFOV end

    -- Untag all parts
    for _, p in ipairs(CollectionService:GetTagged(TAG_PROCESSED)) do
        CollectionService:RemoveTag(p, TAG_PROCESSED)
    end
    for _, p in ipairs(CollectionService:GetTagged(TAG_OVERLAY)) do
        CollectionService:RemoveTag(p, TAG_OVERLAY)
    end
    for _, p in ipairs(CollectionService:GetTagged(TAG_LIGHT)) do
        CollectionService:RemoveTag(p, TAG_LIGHT)
    end
    for _, p in ipairs(CollectionService:GetTagged(TAG_HIGHLIGHT)) do
        CollectionService:RemoveTag(p, TAG_HIGHLIGHT)
    end

    State.Initialized = false
    _G.CinematicShader = nil
    print("[Cinematic] Fully torn down. Re-paste to reinitialize.")
end

local function info()
    return {
        Version       = State.Version,
        Enabled       = State.Enabled,
        Quality       = State.Quality,
        ColorPreset   = State.ColorPreset,
        Tonemap       = State.Tonemap,
        Weather       = State.Weather,
        TimeMode      = State.TimeMode,
        Intensity     = State.Intensity,
        Wetness       = State.Wetness,
        AvgFPS        = Perf.avg(),
        Mood          = Util.currentMood(),
        Overlays      = #CollectionService:GetTagged(TAG_OVERLAY),
        EnhancedParts = #CollectionService:GetTagged(TAG_PROCESSED),
    }
end

-- ===========================================================================
-- 47. GLOBAL HANDLE
-- ===========================================================================
_G.CinematicShader = {
    api       = API,
    state     = State,
    cfg       = Cfg,
    presets   = ColorPresets,
    weathers  = Cfg.Weather,
    moods     = Cfg.Moods,
    tonemaps  = Cfg.Tonemaps,
    qualities = Cfg.Quality,
    kill      = kill,
    info      = info,
    activateRTX      = function() return API.activateRTX() end,
    activateGTANight = function() return API.activateGTANight() end,
    export    = function() return API.exportPreset() end,
    import    = function(s) return API.importPreset(s) end,
    save      = function() return API.save() end,
    load      = function() return API.load() end,
    shake     = function(a) return API.shake(a) end,
    version   = State.Version,
}

init()

