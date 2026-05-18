--[[
	ULTRA CINEMATIC SHADER SYSTEM
	Single-file LocalScript / executor-compatible.
	Place inside StarterPlayer > StarterPlayerScripts, or paste into a console /
	executor / admin runner. Self-initializes.

	Visual stack:
	  - Future technology + tuned environment & exposure
	  - Stacked ColorCorrectionEffects for tonemap + grade
	  - BloomEffect (selective, threshold-gated)
	  - SunRaysEffect (sun-direction gated)
	  - Atmosphere (haze + glare, no thick fog)
	  - DepthOfFieldEffect (cinematic far)
	  - Glass overlay reflection layer ("wet road" / fake SSR)
	  - Vignette UI overlay
	  - Day/Night adaptive bloom + sunrays + glare
--]]

print("[UltraShader] Script execution started.")

local RunService = game:GetService("RunService")
if not RunService:IsClient() then
	warn("[UltraShader] Must run as a LocalScript on the client.")
	return
end

-- Double-paste handler: if a previous instance exists in this session,
-- tear it down cleanly before re-initializing. Pasting the script twice
-- now works without silently doing nothing.
if _G.CinematicShader then
	print("[UltraShader] Previous instance detected — tearing down before re-init...")
	pcall(function()
		if _G.CinematicShader.kill then
			_G.CinematicShader.kill()
		end
	end)
	_G.CinematicShader = nil
	task.wait(0.15)
end

-- Track every connection so kill() can disconnect them cleanly.
local Connections = {}
local function track(conn)
	table.insert(Connections, conn)
	return conn
end

local Lighting          = game:GetService("Lighting")
local Workspace         = game:GetService("Workspace")
local TweenService      = game:GetService("TweenService")
local Players           = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local UserInputService  = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	repeat task.wait() until Players.LocalPlayer
	LocalPlayer = Players.LocalPlayer
end
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- =========================================================================
-- TAGS / ATTRIBUTES
-- =========================================================================

-- Shared namespace with StudioCinematicPlugin so a place baked in Studio
-- is detected on join and the runtime inherits its overlays/tags/settings.
local TAG_PROCESSED  = "Cinematic_Processed"
local TAG_OVERLAY    = "Cinematic_Overlay"
local OVERLAY_NAME   = "Cinematic_WetOverlay"
local ATTR_CLASS     = "Cinematic_Class"
local ATTR_ORIG_MAT  = "Cinematic_OrigMat"
local ATTR_ORIG_REF  = "Cinematic_OrigRef"
local ATTR_ORIG_CST  = "Cinematic_OrigCast"

-- Plugin-bake metadata read from Lighting attributes
local ATTR_BAKED        = "Cinematic_Baked"
local ATTR_BAKE_WETNESS = "Cinematic_BakeWetness"
local ATTR_BAKE_PRESET  = "Cinematic_BakePreset"
local ATTR_BAKE_TIME    = "Cinematic_BakeTime"

-- =========================================================================
-- STATE
-- =========================================================================

local State = {
	Enabled            = true,
	Initialized        = false,
	Intensity          = 1.0,
	Wetness            = 0.5,
	Bloom              = 1.0,
	Reflection         = 1.0,
	Quality            = "Ultra",       -- Low / Medium / High / Ultra
	ColorPreset        = "Enhanced",    -- Enhanced / Cinematic / Realistic / GTA Day / GTA Night / Sunset / Neutral
	Vignette           = true,
	LensFlare          = true,
	AutoFocus          = true,
	WeatherMood        = true,
	FresnelOverlays    = true,
	MotionBlur         = true,
	EyeAdaptation      = true,
	LightEnhance       = true,
	SpeedFOV           = true,
	NightBeams         = true,
	RayTrace           = true,
	MultiBounceRT      = true,
	CameraFillLight    = true,
	GForce             = true,
	PlayerHighlight    = false,
	FoliageEnhance     = true,
	FireEnhance        = true,
	SmokeEnhance       = true,
	SparklesEnhance    = true,
	WaterEnhance       = true,
	Weather            = "Clear",   -- Clear / Cloudy / Stormy / Misty
	Precipitation      = true,
	Lightning          = true,
	AutoCycle          = false,
	CycleSpeed         = 24 / (12 * 60),  -- 12 real-min full day = 0.0333 ClockTime/sec
	Underwater         = true,
	FreeCam            = false,
	Tonemap            = "Filmic",  -- Linear / Filmic / ACES / Punchy
	PerfHUD            = false,
	CinematicMode      = false,
	TimeMode           = "Auto",        -- Auto / Day / Night

	-- ===================================================================
	-- ADVANCED REALISM ("RTX" stack). All off by default; the RTX preset
	-- in the UI flips them on together. Roblox Lua can't run real GPU
	-- shaders, so each module is a property/post-processing/raycast
	-- approximation of a real-shader feature. They stack additively.
	-- ===================================================================

	-- AdvancedColor: drives 4 extra ColorCorrectionEffect layers
	WhiteBalance       = 6500,   -- Kelvin (1500 warm → 15000 cool, 6500 neutral)
	WBTint             = 0,      -- magenta/green tint, -100..100
	Vibrance           = 0,      -- smart saturation, -100..100
	HueShift           = 0,      -- degrees, -180..180
	Lift               = 0,      -- shadow brightness, -1..1
	Gamma              = 1,      -- midtone gamma, 0.2..5
	Gain               = 1,      -- highlight multiplier, 0.2..5

	-- Post-processing modules
	FilmGrain          = false,
	FilmGrainAmount    = 0.18,
	ChromaticAberration= false,
	ChromaticAmount    = 0.5,
	SunDisc            = false,
	VolumetricFog      = false,
	VolumetricDensity  = 1.0,
	Caustics           = false,
	EnhancedGI         = false,
	SSAO               = false,
	SSAOIntensity      = 0.6,
	AnisotropicMetals  = false,
}

local CINEMATIC_FOV       = 62
local NORMAL_FOV_FALLBACK = 70
local OriginalFOV

-- =========================================================================
-- PBR-INSPIRED HELPERS
-- Albedo-aware reflectance: dark surfaces should stay dark even when "wet" or
-- "glossy". This mimics the Fresnel intuition that a black asphalt mostly
-- absorbs the sky color it would reflect, rather than becoming chrome.
-- =========================================================================

local function getColorLuminance(c)
	return c.R * 0.2126 + c.G * 0.7152 + c.B * 0.0722
end

local function albedoScale(part)
	-- brightness 0.00 → 0.10×   (true blacks barely reflect)
	-- brightness 0.50 → 0.85×   (mid greys near full)
	-- brightness 1.00 → 1.15×   (whites slightly boosted)
	local b = getColorLuminance(part.Color)
	return math.clamp(b * 1.5 + 0.05, 0.1, 1.15)
end

-- Overlay-side scale: more permissive than part scale so wet asphalt at night
-- still kicks specular against streetlights, but black floors don't read silver
-- under bright daylight.
local function overlayAlbedoScale(part)
	local b = getColorLuminance(part.Color)
	return math.clamp(b * 0.7 + 0.3, 0.3, 1.05)
end

-- =========================================================================
-- PRESETS — color grading targets per look
-- =========================================================================

local ColorPresets = {
	Enhanced = {
		Main  = { Brightness = 0.0,   Contrast = 0.28, Saturation = 0.13, TintColor = Color3.fromRGB(255, 250, 243) },
		Grade = { Brightness = 0.0,   Contrast = 0.10, Saturation = 0.04, TintColor = Color3.fromRGB(255, 246, 236) },
		AmbientShift = {  7,   4,   0},
	},
	Cinematic = {
		Main  = { Brightness = 0.0,   Contrast = 0.18, Saturation = 0.06, TintColor = Color3.fromRGB(255, 252, 248) },
		Grade = { Brightness = 0.0,   Contrast = 0.05, Saturation = 0.02, TintColor = Color3.fromRGB(252, 250, 248) },
		AmbientShift = {  0,   0,   0},
	},
	Realistic = {
		Main  = { Brightness = 0.0,   Contrast = 0.10, Saturation = 0.0,  TintColor = Color3.fromRGB(255, 253, 248) },
		Grade = { Brightness = 0.0,   Contrast = 0.0,  Saturation = 0.0,  TintColor = Color3.fromRGB(252, 252, 252) },
		AmbientShift = {  0,   0,   0},
	},
	["GTA Day"] = {
		Main  = { Brightness = 0.02,  Contrast = 0.20, Saturation = 0.12, TintColor = Color3.fromRGB(255, 246, 230) },
		Grade = { Brightness = 0.0,   Contrast = 0.06, Saturation = 0.04, TintColor = Color3.fromRGB(255, 232, 200) },
		AmbientShift = { 12,   8,   0},
	},
	["GTA Night"] = {
		Main  = { Brightness = -0.05, Contrast = 0.30, Saturation = 0.18, TintColor = Color3.fromRGB(220, 230, 255) },
		Grade = { Brightness = -0.04, Contrast = 0.10, Saturation = 0.10, TintColor = Color3.fromRGB(170, 195, 245) },
		AmbientShift = {-15, -10,   8},
	},
	Sunset = {
		Main  = { Brightness = 0.04,  Contrast = 0.22, Saturation = 0.20, TintColor = Color3.fromRGB(255, 224, 196) },
		Grade = { Brightness = 0.0,   Contrast = 0.08, Saturation = 0.05, TintColor = Color3.fromRGB(255, 200, 150) },
		AmbientShift = { 18,   6, -10},
	},
	Neutral = {
		Main  = { Brightness = 0.0,   Contrast = 0.05, Saturation = 0.0,  TintColor = Color3.fromRGB(255, 255, 255) },
		Grade = { Brightness = 0.0,   Contrast = 0.0,  Saturation = 0.0,  TintColor = Color3.fromRGB(255, 255, 255) },
		AmbientShift = {  0,   0,   0},
	},
	-- New: warm, slightly desaturated, gentle film-stock vibe
	Vintage = {
		Main  = { Brightness = -0.01, Contrast = 0.18, Saturation = -0.04, TintColor = Color3.fromRGB(255, 245, 218) },
		Grade = { Brightness = 0.0,   Contrast = 0.05, Saturation = 0.02,  TintColor = Color3.fromRGB(245, 232, 210) },
		AmbientShift = { 12,   6,  -8},
	},
	-- Designed for "Max" quality: pulls saturation DOWN (real photographs
	-- almost never have Roblox-default saturation), adds a film-stock contrast
	-- curve, and keeps tints close to white. The goal is a clean window-into-
	-- reality look rather than a stylised grade.
	Photorealistic = {
		Main  = { Brightness = -0.02, Contrast = 0.20, Saturation = -0.08, TintColor = Color3.fromRGB(252, 250, 247) },
		Grade = { Brightness = -0.01, Contrast = 0.09, Saturation = -0.04, TintColor = Color3.fromRGB(248, 246, 244) },
		AmbientShift = {  4,   2,   0},
	},
}

-- =========================================================================
-- PROFILE — base values; sliders multiply against these
-- =========================================================================

local Profile = {
	Lighting = {
		Technology               = Enum.Technology.Future,
		Ambient                  = Color3.fromRGB(70, 67, 62),
		OutdoorAmbient           = Color3.fromRGB(154, 150, 144),
		Brightness               = 2.5,
		ClockTime                = 14.5,
		ColorShift_Top           = Color3.fromRGB(16, 14, 12),
		ColorShift_Bottom        = Color3.fromRGB(232, 218, 196),
		EnvironmentDiffuseScale  = 0.58,
		EnvironmentSpecularScale = 1.0,
		ExposureCompensation     = 0.18,
		FogColor                 = Color3.fromRGB(208, 208, 208),
		FogEnd                   = 100000,
		FogStart                 = 2500,
		GeographicLatitude       = 41.7,
		GlobalShadows            = true,
		ShadowSoftness           = 0.13,
	},
	Atmosphere = {
		Density = 0.20,
		Offset  = 0.38,
		Color   = Color3.fromRGB(212, 212, 212),
		Decay   = Color3.fromRGB(115, 115, 115),
		Glare   = 0.20,
		Haze    = 1.35,
	},
	Bloom = {
		Intensity = 0.60,
		Size      = 22,
		Threshold = 2.0,
	},
	SunRays = {
		Intensity = 0.32,
		Spread    = 0.97,
	},
	DepthOfField = {
		FarIntensity   = 0.22,
		FocusDistance  = 80,
		InFocusRadius  = 50,
		NearIntensity  = 0.0,
	},
	Reflectance = {
		Floor   = 0.20,
		Glass   = 0.55,
		Metal   = 0.32,
		Surface = 0.03,
	},
	Detection = {
		FloorMinArea     = 55,
		FloorNormalDot   = 0.88,
		SmallPartCutoff  = 0.55,
		OverlayMinArea   = 90,
		OverlayMaxCount  = 800,
	},
	Performance = {
		ProcessBudget = 80,
		ScanBatch     = 250,
	},
	TweenTime = 1.4,
}

-- =========================================================================
-- QUALITY PROFILES
-- =========================================================================

-- OverlayMax / BeamMax / TraceDist / TracesPerTick / ExposureBoost / Photoreal
-- are read by the runtime when present. Profiles that omit them fall back to
-- the legacy constants (`Profile.Detection.OverlayMaxCount`, `NIGHT_BEAM_MAX`,
-- `TRACE_DIST_MAX`) so existing tiers behave exactly as before.
--
-- "Max" is the absolute ceiling — designed to make Nvidia RTX-class GPUs
-- sweat: triple the ray-trace budget, triple the reflection overlay count,
-- sharper-than-pixel shadows, and a brighter exposure pass so the scene
-- actually looks like a different engine rather than Roblox. There's no
-- automatic downgrade — if your hardware can't keep up, drop the Quality
-- tier yourself in the UI.
local QualityProfiles = {
	-- Low/Medium/High keep their "no-realism-stack" mandate.
	Low    = { OverlayEnabled = false, BloomMul = 0.6,  AtmosMul = 0.7,  DOFMul = 0.0,  ShadowSoft = 0.45, Spec = 0.55, Diff = 0.35, TracesPerTick = 0 },
	Medium = { OverlayEnabled = false, BloomMul = 0.9,  AtmosMul = 1.0,  DOFMul = 0.0,  ShadowSoft = 0.28, Spec = 0.75, Diff = 0.48, TracesPerTick = 0 },
	High   = { OverlayEnabled = true,  BloomMul = 1.0,  AtmosMul = 1.0,  DOFMul = 0.4,  ShadowSoft = 0.14, Spec = 0.95, Diff = 0.55, TracesPerTick = 5,  OverlayMax = 800,  BeamMax = 250,  TraceDist = 130 },
	-- Ultra is now photorealistic: every realism module flips on, mid-heavy
	-- ray-trace budget (12/frame = ~720 primary + 720 second-bounce raycasts/sec),
	-- razor-sharp shadows, lifted exposure for HDR feel. Still survivable on a
	-- decent mid-range GPU.
	Ultra  = { OverlayEnabled = true,  BloomMul = 1.35, AtmosMul = 1.18, DOFMul = 0.85, ShadowSoft = 0.02, Spec = 1.0,  Diff = 0.72, TracesPerTick = 12, OverlayMax = 2000, BeamMax = 500,  TraceDist = 200, ExposureBoost = 0.06, Photoreal = true },
	-- Max is "make your hardware suffer" territory: double Ultra's ray budget,
	-- 4500 reflection overlays, 320-stud trace range, max diffuse environment
	-- scale, near-1.0 DOF, atmosphere density ×1.45. Visually the goal is
	-- "doesn't read as Roblox anymore". No auto-downgrade — if it tanks your
	-- FPS, manually drop to Ultra.
	Max    = { OverlayEnabled = true,  BloomMul = 1.75, AtmosMul = 1.45, DOFMul = 1.20, ShadowSoft = 0.0,  Spec = 1.0,  Diff = 0.95, TracesPerTick = 32, OverlayMax = 4500, BeamMax = 1200, TraceDist = 320, ExposureBoost = 0.18, Photoreal = true },
}

-- =========================================================================
-- MATERIAL TABLES
-- =========================================================================

local FLOOR_MATERIALS = {
	[Enum.Material.Plastic]       = true,
	[Enum.Material.SmoothPlastic] = true,
	[Enum.Material.Concrete]      = true,
	[Enum.Material.Slate]         = true,
	[Enum.Material.Wood]          = true,
	[Enum.Material.WoodPlanks]    = true,
	[Enum.Material.Marble]        = true,
	[Enum.Material.Granite]       = true,
	[Enum.Material.Brick]         = true,
	[Enum.Material.Pebble]        = true,
	[Enum.Material.Cobblestone]   = true,
	[Enum.Material.CeramicTiles]  = true,
	[Enum.Material.Limestone]     = true,
	[Enum.Material.Pavement]      = true,
	[Enum.Material.Asphalt]       = true,
	[Enum.Material.Basalt]        = true,
	[Enum.Material.Sand]          = true,
	[Enum.Material.Sandstone]     = true,
	[Enum.Material.Ice]           = true,
	[Enum.Material.Glacier]       = true,
	[Enum.Material.RoofShingles]  = true,
	[Enum.Material.Salt]          = true,
	[Enum.Material.Mud]           = true,
	[Enum.Material.Ground]        = true,
}

local METAL_MATERIALS = {
	[Enum.Material.Metal]         = true,
	[Enum.Material.DiamondPlate]  = true,
	[Enum.Material.CorrodedMetal] = true,
	[Enum.Material.Foil]          = true,
}

local FLOOR_REFLECTIVITY = {
	[Enum.Material.Plastic]       = 1.0,
	[Enum.Material.SmoothPlastic] = 1.05,
	[Enum.Material.Marble]        = 1.0,
	[Enum.Material.Granite]       = 0.85,
	[Enum.Material.CeramicTiles]  = 1.0,
	[Enum.Material.Concrete]      = 0.75,
	[Enum.Material.Slate]         = 0.75,
	[Enum.Material.Pavement]      = 0.7,
	[Enum.Material.Asphalt]       = 0.78,
	[Enum.Material.Limestone]     = 0.5,
	[Enum.Material.Brick]         = 0.4,
	[Enum.Material.Cobblestone]   = 0.45,
	[Enum.Material.Pebble]        = 0.3,
	[Enum.Material.Wood]          = 0.5,
	[Enum.Material.WoodPlanks]    = 0.55,
	[Enum.Material.Basalt]        = 0.5,
	[Enum.Material.Sand]          = 0.15,
	[Enum.Material.Sandstone]     = 0.45,
	[Enum.Material.Ice]           = 1.25,
	[Enum.Material.Glacier]       = 1.15,
	[Enum.Material.RoofShingles]  = 0.40,
	[Enum.Material.Salt]          = 0.55,
	[Enum.Material.Mud]           = 0.25,
	[Enum.Material.Ground]        = 0.20,
}

-- =========================================================================
-- MODULE: HELPERS
-- =========================================================================

local Helpers = {}

function Helpers.isCharacterPart(part)
	local cur = part.Parent
	while cur and cur ~= Workspace do
		if cur:IsA("Model") and cur:FindFirstChildOfClass("Humanoid") then return true end
		if cur:IsA("Accessory") or cur:IsA("Tool") or cur:IsA("Hat") then return true end
		cur = cur.Parent
	end
	return false
end

function Helpers.hasSurfaceAppearance(part)
	return part:FindFirstChildOfClass("SurfaceAppearance") ~= nil
end

function Helpers.isTooSmall(part)
	local s = part.Size
	local cutoff = Profile.Detection.SmallPartCutoff
	return s.X < cutoff and s.Y < cutoff and s.Z < cutoff
end

function Helpers.isOurOverlay(part)
	return part.Name == OVERLAY_NAME or CollectionService:HasTag(part, TAG_OVERLAY)
end

function Helpers.canHaveOverlay(part)
	if not part:IsA("Part") then return false end
	if part.Shape ~= Enum.PartType.Block then return false end
	local size = part.Size
	if size.X * size.Z < Profile.Detection.OverlayMinArea then return false end
	if size.Y > math.max(size.X, size.Z) * 0.8 then return false end
	return true
end

-- =========================================================================
-- MODULE: SNAPSHOTS — preserve original part state for clean disable
-- =========================================================================

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

-- =========================================================================
-- MODULE: REFLECTIONS — wet floor / fake SSR via thin Glass overlay
-- =========================================================================

local Reflections = {}

function Reflections.create(part)
	if not Helpers.canHaveOverlay(part) then return end
	if part:FindFirstChild(OVERLAY_NAME) then return end
	local qp = QualityProfiles[State.Quality]
	local overlayMax = (qp and qp.OverlayMax) or Profile.Detection.OverlayMaxCount
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
	-- Slight floor-tint baseline. Ray tracer blends environment color toward this.
	local c = part.Color
	local baseline = Color3.new(
		math.clamp(c.R * 0.4 + 0.55, 0, 1),
		math.clamp(c.G * 0.4 + 0.55, 0, 1),
		math.clamp(c.B * 0.4 + 0.55, 0, 1)
	)
	overlay.Color = baseline
	overlay:SetAttribute("Cinematic_BaselineColor", baseline)
	overlay.Size = Vector3.new(size.X * 0.99, 0.035, size.Z * 0.99)
	overlay.CFrame = part.CFrame * CFrame.new(0, size.Y * 0.5 + 0.024, 0)

	local wet = State.Wetness * State.Reflection
	local oa  = overlayAlbedoScale(part)
	-- Quadratic curve: subtle at low wetness, mirror-like only when fully wet.
	overlay.Transparency = math.clamp(1 - (wet * 0.55), 0.4, 1)
	overlay.Reflectance  = math.clamp(wet * wet * 0.95 * oa, 0, 0.95)

	overlay.Parent = part
	CollectionService:AddTag(overlay, TAG_OVERLAY)
end

function Reflections.update(overlay)
	if not overlay or not overlay.Parent then return end
	local floor = overlay.Parent
	if not floor:IsA("BasePart") then return end
	local wet = State.Wetness * State.Reflection
	local oa  = overlayAlbedoScale(floor)
	overlay.Transparency = math.clamp(1 - (wet * 0.55), 0.4, 1)
	overlay.Reflectance  = math.clamp(wet * wet * 0.95 * oa, 0, 0.95)
end

function Reflections.updateAll()
	for _, overlay in ipairs(CollectionService:GetTagged(TAG_OVERLAY)) do
		Reflections.update(overlay)
	end
end

function Reflections.cleanup()
	task.spawn(function()
		local tagged = CollectionService:GetTagged(TAG_OVERLAY)
		for i, overlay in ipairs(tagged) do
			overlay:Destroy()
			if i % 60 == 0 then task.wait() end
		end
	end)
end

function Reflections.repopulate()
	task.spawn(function()
		local tagged = CollectionService:GetTagged(TAG_PROCESSED)
		for i, part in ipairs(tagged) do
			if part:IsA("BasePart") and part.Parent and part:GetAttribute(ATTR_CLASS) == "floor" then
				Reflections.create(part)
			end
			if i % 80 == 0 then task.wait() end
		end
	end)
end

-- =========================================================================
-- MODULE: MATERIALS — classify and apply per-class treatments
-- =========================================================================

local Materials = {}

function Materials.classify(part)
	if not part:IsA("BasePart") then return nil end
	if part:IsDescendantOf(Lighting) then return nil end
	if Helpers.isOurOverlay(part) then return nil end
	if Helpers.isCharacterPart(part) then return nil end
	if Helpers.hasSurfaceAppearance(part) then return nil end
	if Helpers.isTooSmall(part) then return nil end
	if part.Transparency >= 0.97 then return nil end

	local mat = part.Material

	if mat == Enum.Material.Neon then return "neon" end
	if mat == Enum.Material.Glass then return "glass" end
	if METAL_MATERIALS[mat] then return "metal" end

	if FLOOR_MATERIALS[mat] then
		local up = part.CFrame.UpVector
		local size = part.Size
		local area = size.X * size.Z
		local longestHoriz = math.max(size.X, size.Z)
		if up.Y >= Profile.Detection.FloorNormalDot
			and area >= Profile.Detection.FloorMinArea
			and size.Y <= longestHoriz * 0.85 then
			return "floor"
		end
		return "surface"
	end

	return nil
end

function Materials.applyFloor(part)
	Snap.takePart(part)
	if part.Material == Enum.Material.Plastic then
		part.Material = Enum.Material.SmoothPlastic
	end
	local matMult = FLOOR_REFLECTIVITY[part.Material] or 1.0
	local albedo  = albedoScale(part)
	part.Reflectance = math.clamp(Profile.Reflectance.Floor * matMult * albedo * State.Intensity, 0, 0.35)
	part.CastShadow = true
	part:SetAttribute(ATTR_CLASS, "floor")
	CollectionService:AddTag(part, TAG_PROCESSED)

	if QualityProfiles[State.Quality].OverlayEnabled and State.Reflection > 0 and State.Wetness > 0.05 then
		Reflections.create(part)
	end
end

function Materials.applyGlass(part)
	Snap.takePart(part)
	part.Material = Enum.Material.Glass
	-- Glass reflects regardless of color, but we still scale modestly so
	-- tinted glass stays tinted instead of mirroring sky.
	local albedo = math.max(0.55, albedoScale(part))
	part.Reflectance = math.clamp(Profile.Reflectance.Glass * albedo * State.Reflection * State.Intensity, 0, 0.85)
	part:SetAttribute(ATTR_CLASS, "glass")
	CollectionService:AddTag(part, TAG_PROCESSED)
end

function Materials.applyMetal(part)
	Snap.takePart(part)
	-- Real metals: dark metals (gunmetal, lead) reflect less than chrome.
	local albedo = math.max(0.4, albedoScale(part))
	part.Reflectance = math.clamp(Profile.Reflectance.Metal * albedo * State.Reflection * State.Intensity, 0, 0.6)
	part:SetAttribute(ATTR_CLASS, "metal")
	CollectionService:AddTag(part, TAG_PROCESSED)
end

function Materials.applyNeon(part)
	Snap.takePart(part)
	part.CastShadow = false
	part:SetAttribute(ATTR_CLASS, "neon")
	CollectionService:AddTag(part, TAG_PROCESSED)
end

function Materials.applySurface(part)
	Snap.takePart(part)
	local albedo = albedoScale(part)
	local target = math.clamp(Profile.Reflectance.Surface * albedo * State.Intensity, 0, 0.08)
	if part.Reflectance < target then part.Reflectance = target end
	part:SetAttribute(ATTR_CLASS, "surface")
	CollectionService:AddTag(part, TAG_PROCESSED)
end

function Materials.process(part)
	if not part or not part.Parent then return end
	if not part:IsA("BasePart") then return end
	if CollectionService:HasTag(part, TAG_PROCESSED) then return end
	if Helpers.isOurOverlay(part) then return end

	local class = Materials.classify(part)
	if class == "floor" then Materials.applyFloor(part)
	elseif class == "glass"   then Materials.applyGlass(part)
	elseif class == "metal"   then Materials.applyMetal(part)
	elseif class == "neon"    then Materials.applyNeon(part)
	elseif class == "surface" then Materials.applySurface(part)
	end
end

function Materials.reapplyReflectance()
	for _, part in ipairs(CollectionService:GetTagged(TAG_PROCESSED)) do
		if part:IsA("BasePart") and part.Parent then
			local class = part:GetAttribute(ATTR_CLASS)
			local albedo = albedoScale(part)
			if class == "floor" then
				local mult = FLOOR_REFLECTIVITY[part.Material] or 1.0
				part.Reflectance = math.clamp(Profile.Reflectance.Floor * mult * albedo * State.Intensity, 0, 0.35)
			elseif class == "glass" then
				local a = math.max(0.55, albedo)
				part.Reflectance = math.clamp(Profile.Reflectance.Glass * a * State.Reflection * State.Intensity, 0, 0.85)
			elseif class == "metal" then
				local a = math.max(0.4, albedo)
				part.Reflectance = math.clamp(Profile.Reflectance.Metal * a * State.Reflection * State.Intensity, 0, 0.6)
			elseif class == "surface" then
				part.Reflectance = math.clamp(Profile.Reflectance.Surface * albedo * State.Intensity, 0, 0.08)
			end
		end
	end
end

-- =========================================================================
-- MODULE: LIGHTING — snapshot, tween, restore
-- =========================================================================

local LightingMod = {}

local LIGHTING_TWEEN_KEYS = {
	"Ambient", "OutdoorAmbient", "Brightness", "ClockTime",
	"ColorShift_Top", "ColorShift_Bottom",
	"EnvironmentDiffuseScale", "EnvironmentSpecularScale",
	"ExposureCompensation", "FogColor", "FogEnd", "FogStart",
	"GeographicLatitude", "ShadowSoftness",
}

local LIGHTING_DIRECT_KEYS = { "Technology", "GlobalShadows" }

function LightingMod.snapshot()
	local snap = {}
	for _, k in ipairs(LIGHTING_TWEEN_KEYS) do snap[k] = Lighting[k] end
	for _, k in ipairs(LIGHTING_DIRECT_KEYS) do snap[k] = Lighting[k] end
	return snap
end

function LightingMod.tween(target, time)
	local goal = {}
	for _, k in ipairs(LIGHTING_TWEEN_KEYS) do
		if target[k] ~= nil then goal[k] = target[k] end
	end
	TweenService:Create(
		Lighting,
		TweenInfo.new(time or Profile.TweenTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		goal
	):Play()
end

function LightingMod.applyDirect(target)
	for _, k in ipairs(LIGHTING_DIRECT_KEYS) do
		if target[k] ~= nil then Lighting[k] = target[k] end
	end
end

local function shiftColor(base, shift)
	return Color3.new(
		math.clamp(base.R + (shift[1] or 0) / 255, 0, 1),
		math.clamp(base.G + (shift[2] or 0) / 255, 0, 1),
		math.clamp(base.B + (shift[3] or 0) / 255, 0, 1)
	)
end

function LightingMod.applyProfile(time)
	local quality = QualityProfiles[State.Quality]
	local preset = ColorPresets[State.ColorPreset] or ColorPresets.Cinematic
	local shift = preset.AmbientShift

	LightingMod.applyDirect({
		Technology    = Profile.Lighting.Technology,
		GlobalShadows = Profile.Lighting.GlobalShadows,
	})

	LightingMod.tween({
		Ambient                  = shiftColor(Profile.Lighting.Ambient, shift),
		OutdoorAmbient           = shiftColor(Profile.Lighting.OutdoorAmbient, shift),
		Brightness               = Profile.Lighting.Brightness * (0.75 + State.Intensity * 0.25),
		ClockTime                = Profile.Lighting.ClockTime,
		ColorShift_Top           = Profile.Lighting.ColorShift_Top,
		ColorShift_Bottom        = Profile.Lighting.ColorShift_Bottom,
		EnvironmentDiffuseScale  = quality.Diff,
		EnvironmentSpecularScale = quality.Spec,
		-- Max quality adds an ExposureBoost on top of base exposure so the
		-- scene reads brighter and more HDR-like ("real" rather than flat).
		ExposureCompensation     = Profile.Lighting.ExposureCompensation * State.Intensity + (quality.ExposureBoost or 0),
		FogColor                 = Profile.Lighting.FogColor,
		FogEnd                   = Profile.Lighting.FogEnd,
		FogStart                 = Profile.Lighting.FogStart,
		GeographicLatitude       = Profile.Lighting.GeographicLatitude,
		ShadowSoftness           = quality.ShadowSoft,
	}, time)
end

local OriginalLighting
local StashedAtmospheres = {}

function LightingMod.restore(time)
	if not OriginalLighting then return end
	LightingMod.applyDirect(OriginalLighting)
	LightingMod.tween(OriginalLighting, time)
end

-- =========================================================================
-- MODULE: POST FX — bloom, sun rays, color grading, atmosphere, DOF
-- =========================================================================

local PostFX = {}

local FX = {}

local function getOrMakeChild(parent, className, name)
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA(className) then return existing end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = parent
	return inst
end

local function stashExistingAtmospheres()
	for _, child in ipairs(Lighting:GetChildren()) do
		if child:IsA("Atmosphere") and child.Name ~= "Cinematic_Atmosphere" then
			child.Parent = nil
			table.insert(StashedAtmospheres, child)
		end
	end
end

local function unstashAtmospheres()
	for _, atmo in ipairs(StashedAtmospheres) do
		if atmo and not atmo:IsDescendantOf(game) then
			atmo.Parent = Lighting
		end
	end
	table.clear(StashedAtmospheres)
end

function PostFX.build()
	stashExistingAtmospheres()
	FX.Atmosphere = getOrMakeChild(Lighting, "Atmosphere",            "Cinematic_Atmosphere")
	FX.Bloom      = getOrMakeChild(Lighting, "BloomEffect",           "Cinematic_Bloom")
	FX.SunRays    = getOrMakeChild(Lighting, "SunRaysEffect",         "Cinematic_SunRays")
	FX.CCMain     = getOrMakeChild(Lighting, "ColorCorrectionEffect", "Cinematic_CC_Main")
	-- AdvancedColor chain — sits between CCMain and CCGrade so it grades the
	-- already-toned image. Each layer starts disabled until AdvancedColor.apply
	-- enables it when the user moves a slider.
	FX.CCWhiteBal = getOrMakeChild(Lighting, "ColorCorrectionEffect", "Cinematic_CC_WhiteBal")
	FX.CCLGG      = getOrMakeChild(Lighting, "ColorCorrectionEffect", "Cinematic_CC_LiftGammaGain")
	FX.CCVibrance = getOrMakeChild(Lighting, "ColorCorrectionEffect", "Cinematic_CC_Vibrance")
	FX.CCHue      = getOrMakeChild(Lighting, "ColorCorrectionEffect", "Cinematic_CC_Hue")
	FX.CCChromaR  = getOrMakeChild(Lighting, "ColorCorrectionEffect", "Cinematic_CC_ChromaR")
	FX.CCChromaB  = getOrMakeChild(Lighting, "ColorCorrectionEffect", "Cinematic_CC_ChromaB")
	FX.CCGrade    = getOrMakeChild(Lighting, "ColorCorrectionEffect", "Cinematic_CC_Grade")
	FX.CCTone     = getOrMakeChild(Lighting, "ColorCorrectionEffect", "Cinematic_CC_Tone")  -- tonemap curve pass
	FX.Blur       = getOrMakeChild(Lighting, "BlurEffect",            "Cinematic_Blur")
	FX.DOF        = getOrMakeChild(Lighting, "DepthOfFieldEffect",    "Cinematic_DOF")

	-- New CC layers start neutral & disabled so they're invisible until activated
	for _, k in ipairs({ "CCWhiteBal", "CCLGG", "CCVibrance", "CCHue", "CCChromaR", "CCChromaB" }) do
		local e = FX[k]
		e.Brightness = 0
		e.Contrast   = 0
		e.Saturation = 0
		e.TintColor  = Color3.new(1, 1, 1)
		e.Enabled    = false
	end

	FX.Blur.Size = 0
end

function PostFX.getDayBlend()
	local mode = State.TimeMode
	if mode == "Day" then return 1 end
	if mode == "Night" then return 0 end
	local t = Lighting.ClockTime
	if t < 5 or t > 19 then return 0 end
	return math.sin(((t - 5) / 14) * math.pi)
end

-- Each mood now also drives Brightness multiplier and ColorShift_Top (shadow tint),
-- giving proper cinematic shadow color + scene exposure per time of day.
local MOODS = {
	Night   = { bloom=1.65, glare=0.00, density=1.30, expBias=-0.05, brightnessMul=0.65,
	            bottomTint=Color3.fromRGB(192, 198, 222), topTint=Color3.fromRGB(15, 18, 30) },
	Dawn    = { bloom=1.40, glare=0.65, density=1.25, expBias= 0.02, brightnessMul=0.85,
	            bottomTint=Color3.fromRGB(255, 210, 182), topTint=Color3.fromRGB(22, 16, 12) },
	Morning = { bloom=1.28, glare=0.85, density=1.12, expBias= 0.08, brightnessMul=0.95,
	            bottomTint=Color3.fromRGB(255, 226, 192), topTint=Color3.fromRGB(24, 18, 14) },
	Midday  = { bloom=0.95, glare=1.00, density=0.92, expBias= 0.07, brightnessMul=1.00,
	            bottomTint=Color3.fromRGB(230, 220, 200), topTint=Color3.fromRGB(15, 13, 10) },
	Golden  = { bloom=1.32, glare=0.95, density=1.05, expBias= 0.06, brightnessMul=0.95,
	            bottomTint=Color3.fromRGB(255, 198, 152), topTint=Color3.fromRGB(28, 20, 12) },
	Sunset  = { bloom=1.45, glare=0.75, density=1.22, expBias= 0.04, brightnessMul=0.85,
	            bottomTint=Color3.fromRGB(255, 175, 125), topTint=Color3.fromRGB(34, 18, 10) },
	Dusk    = { bloom=1.35, glare=0.20, density=1.25, expBias=-0.02, brightnessMul=0.72,
	            bottomTint=Color3.fromRGB(208, 196, 222), topTint=Color3.fromRGB(18, 16, 26) },
}

local NEUTRAL_MOOD = {
	bloom=1.0, glare=1.0, density=1.0, expBias=0.0, brightnessMul=1.0,
	bottomTint=Profile.Lighting.ColorShift_Bottom,
	topTint   =Profile.Lighting.ColorShift_Top,
}

-- Weather is a SECOND multiplier layer on top of mood. Independent of time of
-- day — you can have a stormy noon, a clear night, etc. Combines with mood:
-- final density = profile × quality × mood × weather.
local WEATHERS = {
	Clear   = { density=1.00, haze=1.00, bloom=1.00, brightnessMul=1.00, glare=1.00, atmosColor=nil },
	Cloudy  = { density=1.45, haze=1.55, bloom=0.75, brightnessMul=0.85, glare=0.55, atmosColor=Color3.fromRGB(202, 204, 208) },
	Stormy  = { density=1.85, haze=2.05, bloom=0.65, brightnessMul=0.62, glare=0.30, atmosColor=Color3.fromRGB(150, 152, 158) },
	Misty   = { density=2.30, haze=2.55, bloom=0.85, brightnessMul=0.90, glare=0.70, atmosColor=Color3.fromRGB(220, 220, 224) },
}

function PostFX.getWeather()
	return WEATHERS[State.Weather] or WEATHERS.Clear
end

function PostFX.getMood()
	if not State.WeatherMood or State.TimeMode ~= "Auto" then
		return NEUTRAL_MOOD
	end
	local t = Lighting.ClockTime
	if t < 5 then return MOODS.Night
	elseif t < 6.5 then return MOODS.Dawn
	elseif t < 9 then return MOODS.Morning
	elseif t < 15 then return MOODS.Midday
	elseif t < 17 then return MOODS.Golden
	elseif t < 18.5 then return MOODS.Sunset
	elseif t < 20 then return MOODS.Dusk
	else return MOODS.Night
	end
end

function PostFX.applyIntensity(time)
	time = time or Profile.TweenTime
	local intensity = State.Intensity
	local quality = QualityProfiles[State.Quality]
	local preset = ColorPresets[State.ColorPreset] or ColorPresets.Cinematic
	local dayBlend = PostFX.getDayBlend()
	local nightBoost = 1 + (1 - dayBlend) * 0.4
	local mood = PostFX.getMood()
	local weather = PostFX.getWeather()

	local atmoTI = TweenInfo.new(time, Enum.EasingStyle.Quad)
	TweenService:Create(FX.Atmosphere, atmoTI, {
		Density = Profile.Atmosphere.Density * quality.AtmosMul * mood.density * weather.density * (0.7 + intensity * 0.3),
		Offset  = Profile.Atmosphere.Offset,
		Color   = weather.atmosColor or Profile.Atmosphere.Color,
		Decay   = Profile.Atmosphere.Decay,
		Glare   = Profile.Atmosphere.Glare * intensity * dayBlend * mood.glare * weather.glare,
		Haze    = Profile.Atmosphere.Haze * weather.haze * (0.6 + intensity * 0.4),
	}):Play()

	TweenService:Create(FX.Bloom, atmoTI, {
		Intensity = Profile.Bloom.Intensity * intensity * State.Bloom * quality.BloomMul * nightBoost * mood.bloom * weather.bloom,
		Size      = Profile.Bloom.Size,
		Threshold = Profile.Bloom.Threshold,
	}):Play()

	-- SunRays.Intensity is managed in real time by CameraFX (view-direction aware).
	TweenService:Create(FX.SunRays, atmoTI, {
		Spread = Profile.SunRays.Spread,
	}):Play()

	-- Mood-driven lighting shifts. All four properties tween together so the
	-- transition between moods feels seamless:
	--   • Brightness  — actual sun strength: night dim, day bright
	--   • Exposure    — HDR-style bias on top
	--   • BottomTint  — warm ground bounce (golden hr) → cool (night)
	--   • TopTint     — shadow color: warm at sunset, cool at night, neutral midday
	local moodBrightness = Profile.Lighting.Brightness
		* (0.75 + intensity * 0.25)
		* (mood.brightnessMul or 1)
		* (weather.brightnessMul or 1)
	TweenService:Create(Lighting, atmoTI, {
		Brightness           = moodBrightness,
		ExposureCompensation = Profile.Lighting.ExposureCompensation * intensity + mood.expBias + (quality.ExposureBoost or 0),
		ColorShift_Bottom    = mood.bottomTint or Profile.Lighting.ColorShift_Bottom,
		ColorShift_Top       = mood.topTint    or Profile.Lighting.ColorShift_Top,
	}):Play()

	TweenService:Create(FX.CCMain, atmoTI, {
		Brightness = preset.Main.Brightness * intensity,
		Contrast   = preset.Main.Contrast   * intensity,
		Saturation = preset.Main.Saturation * intensity,
		TintColor  = preset.Main.TintColor,
	}):Play()

	TweenService:Create(FX.CCGrade, atmoTI, {
		Brightness = preset.Grade.Brightness * intensity,
		Contrast   = preset.Grade.Contrast   * intensity,
		Saturation = preset.Grade.Saturation * intensity,
		TintColor  = preset.Grade.TintColor,
	}):Play()

	-- Tonemap pass: third CC layer that applies a film-stock curve
	local tone = TONEMAPS[State.Tonemap] or TONEMAPS.Filmic
	TweenService:Create(FX.CCTone, atmoTI, {
		Brightness = tone.Brightness,
		Contrast   = tone.Contrast,
		Saturation = tone.Saturation,
		TintColor  = Color3.fromRGB(255, 255, 255),
	}):Play()

	TweenService:Create(FX.DOF, atmoTI, {
		FarIntensity  = State.CinematicMode and (Profile.DepthOfField.FarIntensity * intensity * quality.DOFMul) or 0,
		FocusDistance = Profile.DepthOfField.FocusDistance,
		InFocusRadius = Profile.DepthOfField.InFocusRadius,
		NearIntensity = Profile.DepthOfField.NearIntensity,
	}):Play()
end

function PostFX.setEnabled(enabled)
	FX.Bloom.Enabled    = enabled
	FX.SunRays.Enabled  = enabled
	FX.CCMain.Enabled   = enabled
	FX.CCGrade.Enabled  = enabled
	if FX.CCTone then FX.CCTone.Enabled = enabled end
	FX.DOF.Enabled      = enabled
	if enabled then
		stashExistingAtmospheres()
		FX.Atmosphere.Parent = Lighting
	else
		FX.Atmosphere.Parent = nil
		unstashAtmospheres()
		FX.Blur.Size = 0
	end
end

-- =========================================================================
-- MODULE: VIGNETTE — soft corner darkening via UI overlay
-- =========================================================================

local VignetteMod = {}
local vignetteGui

function VignetteMod.build()
	if vignetteGui and vignetteGui.Parent then return end
	vignetteGui = Instance.new("ScreenGui")
	vignetteGui.Name = "Cinematic_Vignette"
	vignetteGui.ResetOnSpawn = false
	vignetteGui.IgnoreGuiInset = true
	vignetteGui.DisplayOrder = -10
	vignetteGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	vignetteGui.Parent = PlayerGui

	local function fade(name, anchor, size, position, rot, startT, endT)
		local f = Instance.new("Frame")
		f.Name = name
		f.AnchorPoint = anchor
		f.Size = size
		f.Position = position
		f.BackgroundColor3 = Color3.new(0, 0, 0)
		f.BorderSizePixel = 0
		f.BackgroundTransparency = 0
		f.ZIndex = 1
		local g = Instance.new("UIGradient", f)
		g.Color = ColorSequence.new(Color3.new(0, 0, 0))
		-- Smoothstep-style multi-point curve so corners don't have a visible
		-- linear ramp — the gradient eases naturally into transparent.
		local mid1 = startT + (endT - startT) * 0.30
		local mid2 = startT + (endT - startT) * 0.65
		local mid3 = startT + (endT - startT) * 0.88
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0,    startT),
			NumberSequenceKeypoint.new(0.25, mid1),
			NumberSequenceKeypoint.new(0.55, mid2),
			NumberSequenceKeypoint.new(0.82, mid3),
			NumberSequenceKeypoint.new(1,    endT),
		})
		g.Rotation = rot
		f.Parent = vignetteGui
		return f
	end

	-- Rotation defines which physical edge maps to gradient position 0 (the dark end):
	-- 90  = top edge,  270 = bottom edge,  0 = left edge,  180 = right edge
	-- Frames are smaller and starting transparency much higher so the four
	-- frames don't compound to nearly-opaque black at the screen corners.
	fade("VTop",    Vector2.new(0.5, 0), UDim2.new(1, 0, 0.20, 0), UDim2.new(0.5, 0, 0, 0),     90, 0.72, 1)
	fade("VBottom", Vector2.new(0.5, 1), UDim2.new(1, 0, 0.20, 0), UDim2.new(0.5, 0, 1, 0),    270, 0.72, 1)
	fade("VLeft",   Vector2.new(0, 0.5), UDim2.new(0.13, 0, 1, 0), UDim2.new(0, 0, 0.5, 0),      0, 0.80, 1)
	fade("VRight",  Vector2.new(1, 0.5), UDim2.new(0.13, 0, 1, 0), UDim2.new(1, 0, 0.5, 0),    180, 0.80, 1)
end

function VignetteMod.setVisible(visible)
	if not vignetteGui then return end
	vignetteGui.Enabled = visible and State.Vignette
end

-- =========================================================================
-- MODULE: LENS FLARE — sun-tracked screen overlay
-- =========================================================================

local LensFlare = {}
local flareGui
local flareElements = {}
local lastSunVisCheck = 0
local sunVisibleCached = false

-- offset 0 = at sun, 1.0 = at screen center, 2.0 = mirrored across center
-- w / h: per-element width/height in pixels (defaults to size / size if absent)
-- anamorphic = true: rendered as a wide horizontal streak (cinema lens flare)
local FLARE_DEFS = {
	{ offset = 0.00, size = 190, color = Color3.fromRGB(255, 248, 215), trans = 0.25 },
	-- Anamorphic horizontal streak — the long bright bar you see across cinema shots
	{ offset = 0.00, w = 540, h = 18, color = Color3.fromRGB(255, 240, 200), trans = 0.55, anamorphic = true },
	{ offset = 0.32, size = 72,  color = Color3.fromRGB(255, 232, 180), trans = 0.62 },
	{ offset = 0.55, size = 44,  color = Color3.fromRGB(220, 232, 255), trans = 0.78 },
	{ offset = 0.78, size = 62,  color = Color3.fromRGB(255, 215, 160), trans = 0.7 },
	{ offset = 1.00, size = 100, color = Color3.fromRGB(255, 235, 195), trans = 0.55 },
	{ offset = 1.32, size = 36,  color = Color3.fromRGB(220, 245, 255), trans = 0.82 },
	{ offset = 1.55, size = 54,  color = Color3.fromRGB(255, 220, 180), trans = 0.74 },
}

function LensFlare.build()
	if flareGui and flareGui.Parent then return end
	flareGui = Instance.new("ScreenGui")
	flareGui.Name = "Cinematic_LensFlare"
	flareGui.ResetOnSpawn = false
	flareGui.IgnoreGuiInset = true
	flareGui.DisplayOrder = -5
	flareGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	flareGui.Parent = PlayerGui

	for _, def in ipairs(FLARE_DEFS) do
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.BorderSizePixel = 0
		f.BackgroundColor3 = def.color
		f.BackgroundTransparency = 1
		-- Per-element dimensions: w/h take precedence, else fall back to size square.
		local w = def.w or def.size or 100
		local h = def.h or def.size or 100
		f.Size = UDim2.fromOffset(w, h)
		f.Visible = false
		-- Round elements get a circle corner; anamorphic streak gets pill shape
		local cornerRadius = def.anamorphic and UDim.new(1, 0) or UDim.new(1, 0)
		Instance.new("UICorner", f).CornerRadius = cornerRadius
		local g = Instance.new("UIGradient", f)
		-- Smoother multi-stop falloff so the bright core eases into the
		-- transparent rim instead of having a visible shoulder.
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0,    0),
			NumberSequenceKeypoint.new(0.18, 0.08),
			NumberSequenceKeypoint.new(0.42, 0.32),
			NumberSequenceKeypoint.new(0.68, 0.62),
			NumberSequenceKeypoint.new(0.88, 0.88),
			NumberSequenceKeypoint.new(1,    1),
		})
		f.Parent = flareGui
		table.insert(flareElements, { frame = f, def = def })
	end
end

local function hideFlare()
	for _, el in ipairs(flareElements) do
		if el.frame then el.frame.Visible = false end
	end
end

function LensFlare.update()
	if not State.Enabled or not State.LensFlare then
		hideFlare()
		return
	end

	local cam = workspace.CurrentCamera
	if not cam then return end

	local sunDir = Lighting:GetSunDirection()
	if sunDir.Y < -0.05 then hideFlare(); return end

	local lookDot = cam.CFrame.LookVector:Dot(sunDir)
	if lookDot < 0.1 then hideFlare(); return end

	local sunWorldPos = cam.CFrame.Position + sunDir * 5000
	local screenPos = cam:WorldToViewportPoint(sunWorldPos)
	if screenPos.Z < 0 then hideFlare(); return end

	local now = os.clock()
	if now - lastSunVisCheck > 0.15 then
		lastSunVisCheck = now
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		local excl = {}
		if LocalPlayer.Character then table.insert(excl, LocalPlayer.Character) end
		rayParams.FilterDescendantsInstances = excl
		local ray = Workspace:Raycast(cam.CFrame.Position, sunDir * 900, rayParams)
		sunVisibleCached = ray == nil
	end

	local visMult  = sunVisibleCached and 1.0 or 0.22
	local intensity = (lookDot ^ 1.6) * visMult * State.Intensity * PostFX.getDayBlend()
	if intensity < 0.04 then hideFlare(); return end

	local viewport      = cam.ViewportSize
	local screenCenter  = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
	local sunScreen     = Vector2.new(screenPos.X, screenPos.Y)
	local axis          = screenCenter - sunScreen

	for _, el in ipairs(flareElements) do
		local pos = sunScreen + axis * el.def.offset
		el.frame.Position = UDim2.fromOffset(pos.X, pos.Y)
		el.frame.BackgroundTransparency = math.clamp(el.def.trans + (1 - intensity) * 0.55, 0, 1)
		el.frame.Visible = true
	end
end

-- =========================================================================
-- MODULE: CAMERA FX — FOV / view-direction sun rays / auto-focus DoF
-- =========================================================================

local CameraFX = {}

function CameraFX.applyCinematicFOV(enabled)
	local cam = workspace.CurrentCamera
	if not cam then return end
	if enabled then
		if not OriginalFOV then OriginalFOV = cam.FieldOfView end
		TweenService:Create(cam, TweenInfo.new(1.5, Enum.EasingStyle.Quad), {
			FieldOfView = CINEMATIC_FOV
		}):Play()
	else
		local target = OriginalFOV or NORMAL_FOV_FALLBACK
		TweenService:Create(cam, TweenInfo.new(1.5, Enum.EasingStyle.Quad), {
			FieldOfView = target
		}):Play()
	end
end

local sunRaysSmoothed = 0
function CameraFX.updateSunRays(dt)
	if not State.Enabled or not FX.SunRays then return end
	local cam = workspace.CurrentCamera
	if not cam then return end

	local sunDir = Lighting:GetSunDirection()
	local target = 0
	if sunDir.Y > 0 then
		local facing = math.max(0, cam.CFrame.LookVector:Dot(sunDir))
		local mood = PostFX.getMood()
		target = Profile.SunRays.Intensity * State.Intensity * PostFX.getDayBlend()
			* (0.25 + facing * 0.75) * mood.glare
	end
	sunRaysSmoothed = sunRaysSmoothed + (target - sunRaysSmoothed) * math.min(1, dt * 5)
	FX.SunRays.Intensity = sunRaysSmoothed
end

local lastFocusUpdate = 0
local focusSmoothed   = 80
function CameraFX.updateAutoFocus()
	if not State.Enabled or not State.AutoFocus or not State.CinematicMode or not FX.DOF then return end
	local now = os.clock()
	if now - lastFocusUpdate < 0.1 then return end
	lastFocusUpdate = now

	local cam = workspace.CurrentCamera
	if not cam then return end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local excl = {}
	if LocalPlayer.Character then table.insert(excl, LocalPlayer.Character) end
	rayParams.FilterDescendantsInstances = excl

	local ray = Workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * 500, rayParams)
	local target = ray and ray.Distance or 250
	focusSmoothed = focusSmoothed + (target - focusSmoothed) * 0.18
	FX.DOF.FocusDistance = focusSmoothed
end

-- =========================================================================
-- MODULE: FRESNEL OVERLAYS — view-angle aware reflectance on wet overlays
-- Closer surfaces / grazing angles read brighter, mimicking real fresnel.
-- =========================================================================

-- =========================================================================
-- IMPACT SHAKE — small camera jolt on hard landings / fall damage states
-- Hooks Humanoid.StateChanged and applies a transient CFrame offset to the
-- Camera each RenderStepped while the shake decays exponentially.
-- =========================================================================

local impactShakeAmount = 0
local lastFallVelocity  = 0
local trackedRoot       = nil
local stateChangedConn  = nil

function CameraFX.bindCharacter()
	local function attach(char)
		if stateChangedConn then stateChangedConn:Disconnect() end
		local hum    = char:WaitForChild("Humanoid", 5)
		trackedRoot  = char:WaitForChild("HumanoidRootPart", 5)
		if not hum then return end

		stateChangedConn = hum.StateChanged:Connect(function(_, new)
			if new == Enum.HumanoidStateType.Landed and State.CinematicMode then
				local v = math.abs(lastFallVelocity)
				if v > 35 then
					impactShakeAmount = math.min(impactShakeAmount + (v - 35) / 90, 0.9)
				end
			end
		end)
	end

	if LocalPlayer.Character then attach(LocalPlayer.Character) end
	track(LocalPlayer.CharacterAdded:Connect(attach))
end

function CameraFX.updateImpactShake(dt)
	if not State.Enabled then return end
	if trackedRoot and trackedRoot.Parent then
		lastFallVelocity = trackedRoot.AssemblyLinearVelocity.Y
	end
	-- We no longer mutate Camera.CFrame here — it conflicts with vehicle camera
	-- systems and causes stuttering during high-speed crashes. The G-force
	-- system already provides motion-blur "impact feel" which is enough.
	-- impactShakeAmount is still tracked so other systems can read it as a
	-- magnitude signal, but it just decays here without applying anything.
	if impactShakeAmount < 0.001 then return end
	impactShakeAmount = impactShakeAmount * math.max(0, 1 - dt * 6)
end

local function disconnectImpactShake()
	if stateChangedConn then
		stateChangedConn:Disconnect()
		stateChangedConn = nil
	end
end

-- =========================================================================
-- SPEED FOV / G-FORCE — combined FOV controller + acceleration tracker.
-- SpeedFOV widens FOV at sprint speeds when CinematicMode is on.
-- GForce works independently: detects vehicle-like acceleration and applies
-- forward-pull FOV (accel) or backward-narrow FOV (brake), plus a motion
-- blur boost (read by updateMotionBlur), plus subtle shake at sustained
-- high G. Active any time GForce is on, even without CinematicMode.
-- =========================================================================

local fovSmoothed
local gForceSpeedSmoothed  = 0   -- low-pass speed BEFORE differentiating
local gForceLastSpeed      = 0
local gForceAccelSmoothed  = 0
local gForceLevel = 0        -- 0..1, magnitude of current G effect
local gForceSign  = 1         -- +1 = accelerating, -1 = braking
local gForceCapturedFOV       -- camera FOV at the moment G-force started touching it
local ACCEL_HARD_CAP      = 180  -- studs/s², caps insane spikes from crashes

function CameraFX.updateSpeedFOV(dt)
	if not State.Enabled then return end

	-- Sample raw horizontal velocity
	local rawSpeed = 0
	local char = LocalPlayer.Character
	if char then
		local root = char:FindFirstChild("HumanoidRootPart")
		if root then
			local v = root.AssemblyLinearVelocity
			rawSpeed = Vector3.new(v.X, 0, v.Z).Magnitude
		end
	end

	-- ===== ANTI-STUTTER SPEED SMOOTHING =====
	-- Smooth the speed FIRST, then differentiate. Prevents a single-frame
	-- speed snap (crash from 80 → 0) from producing a -5000 studs/s² accel
	-- spike that destabilises the entire G-force pipeline. The 8x lerp
	-- factor is fast enough to feel responsive but kills 1-frame transients.
	gForceSpeedSmoothed = gForceSpeedSmoothed
		+ (rawSpeed - gForceSpeedSmoothed) * math.min(1, dt * 8)

	-- Now compute accel from the smoothed value
	local accel = (gForceSpeedSmoothed - gForceLastSpeed) / math.max(dt, 0.001)
	gForceLastSpeed = gForceSpeedSmoothed

	-- Hard cap absolute accel — even after smoothing, exceptional events
	-- like teleports or vehicle resets shouldn't blow up the system.
	if accel > ACCEL_HARD_CAP then accel = ACCEL_HARD_CAP
	elseif accel < -ACCEL_HARD_CAP then accel = -ACCEL_HARD_CAP end

	-- Final lowpass on the (now-tame) accel value
	gForceAccelSmoothed = gForceAccelSmoothed
		+ (accel - gForceAccelSmoothed) * math.min(1, dt * 5)

	-- G-force level: needs vehicle-like speed AND meaningful acceleration
	if State.GForce then
		local speedGate = math.clamp((gForceSpeedSmoothed - 20) / 30, 0, 1)
		local accelGate = math.clamp((math.abs(gForceAccelSmoothed) - 10) / 80, 0, 1)
		local targetG   = speedGate * accelGate
		gForceLevel = gForceLevel + (targetG - gForceLevel) * math.min(1, dt * 4)
		gForceSign  = gForceAccelSmoothed >= 0 and 1 or -1
	else
		gForceLevel = gForceLevel * math.max(0, 1 - dt * 4)
	end

	-- Decide whether to drive FOV at all this frame
	local cinematicWantsFOV = State.CinematicMode and State.SpeedFOV
	local gforceWantsFOV    = State.GForce and gForceLevel > 0.015
	if not cinematicWantsFOV and not gforceWantsFOV then
		-- Glide back to captured FOV if we'd previously taken it over
		if gForceCapturedFOV and workspace.CurrentCamera then
			local cam = workspace.CurrentCamera
			cam.FieldOfView = cam.FieldOfView + (gForceCapturedFOV - cam.FieldOfView) * math.min(1, dt * 4)
			if math.abs(cam.FieldOfView - gForceCapturedFOV) < 0.2 then
				cam.FieldOfView = gForceCapturedFOV
				gForceCapturedFOV = nil
				fovSmoothed = cam.FieldOfView
			end
		end
		return
	end

	local cam = workspace.CurrentCamera
	if not cam then return end

	if not gForceCapturedFOV then
		gForceCapturedFOV = OriginalFOV or cam.FieldOfView
	end

	local baseFOV = State.CinematicMode and CINEMATIC_FOV or gForceCapturedFOV
	local fovDelta = 0

	if cinematicWantsFOV then
		fovDelta = fovDelta + math.clamp((speed - 14) / 30, 0, 1) * 6
	end

	if gforceWantsFOV then
		-- Accelerating: pull FOV out (speed feel). Braking: pull in (focus).
		-- Tamer than before so the world doesn't lurch when you floor it.
		fovDelta = fovDelta + gForceLevel * gForceSign * 5
	end

	local target = baseFOV + fovDelta
	fovSmoothed = fovSmoothed or cam.FieldOfView
	fovSmoothed = fovSmoothed + (target - fovSmoothed) * math.min(1, dt * 5)
	cam.FieldOfView = fovSmoothed

	-- Sustained high G induces a subtle camera tremor (feeds the existing shake system)
	if gForceLevel > 0.55 then
		impactShakeAmount = math.max(impactShakeAmount, (gForceLevel - 0.55) * 0.25)
	end
end

-- =========================================================================
-- MOTION BLUR — camera-velocity-driven BlurEffect.Size
-- =========================================================================

local lastCamPos, lastCamLook
local blurSmoothed = 0

function CameraFX.updateMotionBlur(dt)
	if not State.Enabled or not FX.Blur then return end
	if not State.MotionBlur then
		if FX.Blur.Size > 0.01 then
			FX.Blur.Size = FX.Blur.Size + (0 - FX.Blur.Size) * math.min(1, dt * 8)
		else
			FX.Blur.Size = 0
		end
		blurSmoothed = FX.Blur.Size
		return
	end

	local cam = workspace.CurrentCamera
	if not cam then return end
	local pos  = cam.CFrame.Position
	local look = cam.CFrame.LookVector

	if lastCamPos and dt > 0 then
		local linSpeed = (pos - lastCamPos).Magnitude / dt
		local angSpeed = (look - lastCamLook).Magnitude / dt
		-- Linear blur: kicks in above ~25 studs/s, soft cap at 2.5 — never enough
		-- to make billboards / chat bubbles unreadable.
		local linBlur = math.clamp((linSpeed - 25) / 90, 0, 1) * 2.5
		-- Angular blur: gentle even on fast turn
		local angBlur = math.clamp(angSpeed * 1.6, 0, 1) * 2.5
		local target  = math.max(linBlur, angBlur) * State.Intensity

		-- G-force adds a small extra during hard acceleration / braking.
		-- Capped low specifically so the ground hint of motion blur is felt
		-- without washing out the entire 3D scene.
		if State.GForce and gForceLevel > 0.1 then
			target = target + (gForceLevel - 0.1) * 1.6 * State.Intensity
		end

		target = math.min(target, 3.5)   -- hard cap regardless of input

		blurSmoothed = blurSmoothed + (target - blurSmoothed) * math.min(1, dt * 8)
		FX.Blur.Size = blurSmoothed
	end

	lastCamPos  = pos
	lastCamLook = look
end

-- =========================================================================
-- EYE ADAPTATION — raycast-based exposure drift toward what camera sees
-- =========================================================================

local lastEyeTick = 0
local exposureSmoothed
function CameraFX.updateEyeAdaptation()
	if not State.Enabled or not State.EyeAdaptation then return end
	local now = os.clock()
	if now - lastEyeTick < 0.25 then return end
	lastEyeTick = now

	local cam = workspace.CurrentCamera
	if not cam then return end

	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	local excl = {}
	if LocalPlayer.Character then table.insert(excl, LocalPlayer.Character) end
	for _, ov in ipairs(CollectionService:GetTagged(TAG_OVERLAY)) do
		table.insert(excl, ov)
	end
	rp.FilterDescendantsInstances = excl

	local ray = Workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * 600, rp)
	local sceneLum
	if not ray then
		-- Open sky — luminance proxy from time of day
		sceneLum = 0.7 + PostFX.getDayBlend() * 0.3
	else
		sceneLum = getColorLuminance(ray.Instance.Color)
		-- Materials with strong texture brightness affect it too; approximate
		if ray.Material == Enum.Material.Neon then sceneLum = 1.0 end
		if ray.Material == Enum.Material.Glass then sceneLum = math.max(sceneLum, 0.4) end
	end

	-- Eye adapts: dark scene → raise exposure, bright scene → lower it.
	local mood        = PostFX.getMood()
	local qBoost      = (QualityProfiles[State.Quality] and QualityProfiles[State.Quality].ExposureBoost) or 0
	local baseExp     = Profile.Lighting.ExposureCompensation * State.Intensity + mood.expBias + qBoost
	local adaptDelta  = (0.5 - sceneLum) * 0.18
	local target      = baseExp + adaptDelta

	if not exposureSmoothed then exposureSmoothed = baseExp end
	exposureSmoothed = exposureSmoothed + (target - exposureSmoothed) * 0.18
	Lighting.ExposureCompensation = exposureSmoothed
end

local lastFresnelTick = 0

function CameraFX.updateFresnelOverlays()
	if not State.Enabled or not State.FresnelOverlays then return end
	local now = os.clock()
	if now - lastFresnelTick < 0.08 then return end  -- ~12 Hz
	lastFresnelTick = now

	local cam = workspace.CurrentCamera
	if not cam then return end
	local camPos = cam.CFrame.Position

	local wet = State.Wetness * State.Reflection
	local wetSq = wet * wet

	for _, overlay in ipairs(CollectionService:GetTagged(TAG_OVERLAY)) do
		local floor = overlay.Parent
		if floor and floor:IsA("BasePart") then
			local toCam = camPos - overlay.Position
			local dist = toCam.Magnitude
			if dist < 350 and dist > 0.001 then
				local dir = toCam / dist
				local upDot = math.abs(dir:Dot(overlay.CFrame.UpVector))
				local grazing = 1 - upDot
				local oa = overlayAlbedoScale(floor)
				-- Schlick-style fresnel with a steeper curve. At grazing angles
				-- reflectance pushes toward true mirror, creating the depth
				-- illusion you see in wet GTA-style pavement where the puddle
				-- ahead reflects the whole scene.
				local fresnelPow = grazing ^ 5
				local base    = wetSq * 0.95 * oa
				local fresnel = base * (0.35 + fresnelPow * 1.6)
				overlay.Reflectance = math.clamp(fresnel, 0, 0.97)
			end
		end
	end
end

-- =========================================================================
-- MODULE: FPS SAMPLER — rolling-average FPS used by PerfHUD.
-- Previously this module also auto-switched Quality up/down based on
-- framerate ("Adaptive Quality"). That behaviour has been removed at the
-- user's request — Quality is now whatever the user picks, full stop. The
-- table is still named AdaptiveQuality for call-site compatibility but only
-- exposes .sample() and .average() now.
-- =========================================================================

local AdaptiveQuality = {}

local fpsSamples = {}
local FPS_SAMPLE_CAP = 60

function AdaptiveQuality.sample(dt)
	if dt <= 0 then return end
	table.insert(fpsSamples, 1 / dt)
	if #fpsSamples > FPS_SAMPLE_CAP then
		table.remove(fpsSamples, 1)
	end
end

function AdaptiveQuality.average()
	if #fpsSamples == 0 then return 60 end
	local sum = 0
	for _, v in ipairs(fpsSamples) do sum = sum + v end
	return sum / #fpsSamples
end

-- =========================================================================
-- MODULE: PERF HUD — small FPS/quality readout in top-right
-- =========================================================================

local PerfHUD = {}
local hudGui, hudLabel
local lastHUDTick = 0

function PerfHUD.build()
	if hudGui and hudGui.Parent then return end
	hudGui = Instance.new("ScreenGui")
	hudGui.Name = "Cinematic_PerfHUD"
	hudGui.ResetOnSpawn = false
	hudGui.IgnoreGuiInset = true
	hudGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	hudGui.Enabled = State.PerfHUD
	hudGui.Parent = PlayerGui

	local frame = Instance.new("Frame", hudGui)
	frame.AnchorPoint = Vector2.new(1, 0)
	frame.Size = UDim2.fromOffset(220, 110)
	frame.Position = UDim2.new(1, -14, 0, 14)
	frame.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
	frame.BackgroundTransparency = 0.10
	frame.BorderSizePixel = 0
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 6)
	local stroke = Instance.new("UIStroke", frame)
	stroke.Color = Color3.fromRGB(70, 120, 220)
	stroke.Thickness = 1
	stroke.Transparency = 0.5

	hudLabel = Instance.new("TextLabel", frame)
	hudLabel.Size = UDim2.new(1, -16, 1, -10)
	hudLabel.Position = UDim2.fromOffset(8, 5)
	hudLabel.BackgroundTransparency = 1
	hudLabel.TextColor3 = Color3.fromRGB(220, 230, 250)
	hudLabel.Font = Enum.Font.RobotoMono
	hudLabel.TextSize = 11
	hudLabel.TextXAlignment = Enum.TextXAlignment.Left
	hudLabel.TextYAlignment = Enum.TextYAlignment.Top
	hudLabel.Text = "..."
end

local function moodName(t)
	if t < 5 then return "Night"
	elseif t < 6.5 then return "Dawn"
	elseif t < 9 then return "Morning"
	elseif t < 15 then return "Midday"
	elseif t < 17 then return "Golden"
	elseif t < 18.5 then return "Sunset"
	elseif t < 20 then return "Dusk"
	else return "Night" end
end

function PerfHUD.update()
	if not hudGui or not hudGui.Enabled or not hudLabel then return end
	local now = os.clock()
	if now - lastHUDTick < 0.4 then return end
	lastHUDTick = now

	local fps      = AdaptiveQuality.average()
	local overlays = #CollectionService:GetTagged(TAG_OVERLAY)
	local lights   = #CollectionService:GetTagged(TAG_LIGHT)
	local beams    = #CollectionService:GetTagged(TAG_NIGHT_BEAM)
	local mood = (State.WeatherMood and State.TimeMode == "Auto")
		and moodName(Lighting.ClockTime) or State.TimeMode

	-- FPS color tier for visual feedback
	local fpsColor = Color3.fromRGB(120, 230, 130)
	if fps < 30 then fpsColor = Color3.fromRGB(230, 100, 100)
	elseif fps < 50 then fpsColor = Color3.fromRGB(230, 200, 100) end
	hudLabel.TextColor3 = fpsColor  -- header color reflects FPS

	local rt   = State.RayTrace and (State.MultiBounceRT and "RT 2-bounce" or "RT 1-bounce") or "RT off"
	local uw   = uwActive and "  • UNDER" or ""
	hudLabel.Text = string.format(
		"FPS: %.0f  |  %s%s\n" ..
		"Overlays: %d  Lights: %d  Beams: %d\n" ..
		"Mood: %s   Weather: %s\n" ..
		"Preset: %s   Tonemap: %s\n" ..
		"%s",
		fps, State.Quality, uw,
		overlays, lights, beams,
		mood, State.Weather,
		State.ColorPreset, State.Tonemap,
		rt
	)
end

function PerfHUD.setVisible(v)
	if hudGui then hudGui.Enabled = v end
end

-- =========================================================================
-- TOAST — small non-intrusive on-screen notification
-- =========================================================================

local function showToast(message, duration)
	duration = duration or 4
	local gui = Instance.new("ScreenGui")
	gui.Name = "Cinematic_Toast"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = PlayerGui

	local frame = Instance.new("Frame", gui)
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Size = UDim2.fromOffset(420, 38)
	frame.Position = UDim2.new(0.5, 0, 0, 56)
	frame.BackgroundColor3 = Color3.fromRGB(22, 24, 32)
	frame.BackgroundTransparency = 0.1
	frame.BorderSizePixel = 0
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

	local stroke = Instance.new("UIStroke", frame)
	stroke.Color = Color3.fromRGB(70, 120, 220)
	stroke.Thickness = 1
	stroke.Transparency = 0.5

	local label = Instance.new("TextLabel", frame)
	label.Size = UDim2.new(1, -18, 1, 0)
	label.Position = UDim2.fromOffset(9, 0)
	label.BackgroundTransparency = 1
	label.Text = message
	label.TextColor3 = Color3.fromRGB(225, 232, 250)
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 12
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextWrapped = true

	task.delay(duration, function()
		TweenService:Create(frame, TweenInfo.new(0.4), {
			BackgroundTransparency = 1,
			Position = frame.Position + UDim2.fromOffset(0, -16),
		}):Play()
		TweenService:Create(label, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
		task.wait(0.5)
		gui:Destroy()
	end)
end

-- =========================================================================
-- ROBLOX SETTINGS HINT — read in-game quality, suggest manual max if needed
-- =========================================================================

local function checkRobloxQuality()
	local ok, ugs = pcall(function()
		return UserSettings():GetService("UserGameSettings")
	end)
	if not ok or not ugs then return end
	local saved = ugs.SavedQualityLevel
	local level = saved and saved.Value or 0
	-- 0 = Automatic. 1..10 = manual quality 1 through 10.
	if level == 0 then
		showToast("Tip: Roblox Settings → Graphics Mode = Manual + Quality 10 for best results.", 6)
	elseif level > 0 and level < 8 then
		showToast(string.format("Tip: Quality %d → bump to 10 in Roblox Settings for best results.", level), 6)
	end
end

-- RenderStepped loop is bound from init() once all modules are defined.
-- (Binding it here would cause `NightBeams`/`RayTrace`/`CameraFill` to
-- resolve to nil since their `local` declarations come later in the file.)

-- =========================================================================
-- MODULE: LIGHT ENHANCEMENT — enable shadows on every Light in workspace
-- This is the single biggest indoor / nighttime visual upgrade. Future tech
-- supports per-light shadow casting but defaults to false.
-- =========================================================================

local Lights = {}
local TAG_LIGHT       = "Cinematic_LightProc"
local ATTR_LIGHT_SH   = "Cinematic_LightShadows"
local ATTR_LIGHT_BR   = "Cinematic_LightBrightness"

function Lights.enhance(light)
	if not light:IsA("Light") then return end
	if CollectionService:HasTag(light, TAG_LIGHT) then return end
	if not State.LightEnhance then return end

	light:SetAttribute(ATTR_LIGHT_SH, light.Shadows)
	light:SetAttribute(ATTR_LIGHT_BR, light.Brightness)
	light.Shadows = true
	-- Subtle brightness lift, capped: ambient lights stay close to author intent.
	if light.Brightness > 0 and light.Brightness < 4 then
		light.Brightness = math.min(light.Brightness * 1.15, light.Brightness + 0.4)
	end
	CollectionService:AddTag(light, TAG_LIGHT)
end

function Lights.restore(light)
	if not CollectionService:HasTag(light, TAG_LIGHT) then return end
	local sh = light:GetAttribute(ATTR_LIGHT_SH)
	local br = light:GetAttribute(ATTR_LIGHT_BR)
	if sh ~= nil then light.Shadows = sh end
	if br ~= nil then light.Brightness = br end
	light:SetAttribute(ATTR_LIGHT_SH, nil)
	light:SetAttribute(ATTR_LIGHT_BR, nil)
	CollectionService:RemoveTag(light, TAG_LIGHT)
end

function Lights.scan()
	task.spawn(function()
		local descendants = Workspace:GetDescendants()
		for i, d in ipairs(descendants) do
			if d:IsA("Light") then Lights.enhance(d) end
			if i % 300 == 0 then task.wait() end
		end
	end)
end

function Lights.cleanup()
	task.spawn(function()
		for _, light in ipairs(CollectionService:GetTagged(TAG_LIGHT)) do
			Lights.restore(light)
		end
	end)
end

-- =========================================================================
-- MODULE: NIGHT BEAMS — volumetric-looking god rays from every light source
-- A billboard Beam parented to each Light. Visible only when dayBlend is low.
-- Camera-facing, additive emission, tapered narrow→wide for the cone illusion.
-- =========================================================================

local NightBeams = {}
local TAG_NIGHT_BEAM   = "Cinematic_NightBeam"
local NIGHT_BEAM_MAX   = 250
local nightBeamCount   = 0

-- Convert a face on the part into a WORLD-space direction vector. PointLight
-- has no face — we always beam straight down in world space (streetlight feel).
local function worldFaceDir(part, face)
	if face == Enum.NormalId.Top    then return  part.CFrame.UpVector
	elseif face == Enum.NormalId.Bottom then return -part.CFrame.UpVector
	elseif face == Enum.NormalId.Front  then return -part.CFrame.LookVector
	elseif face == Enum.NormalId.Back   then return  part.CFrame.LookVector
	elseif face == Enum.NormalId.Right  then return  part.CFrame.RightVector
	elseif face == Enum.NormalId.Left   then return -part.CFrame.RightVector
	end
	return Vector3.new(0, -1, 0)
end

function NightBeams.attach(light)
	if not State.NightBeams then return end
	if not (light:IsA("PointLight") or light:IsA("SpotLight") or light:IsA("SurfaceLight")) then return end
	local parent = light.Parent
	if not parent or not parent:IsA("BasePart") then return end
	if light.Range < 8 then return end
	if parent:FindFirstChild("Cinematic_NightBeam_a0") then return end
	local q = QualityProfiles[State.Quality]
	local beamMax = (q and q.BeamMax) or NIGHT_BEAM_MAX
	if nightBeamCount >= beamMax then return end
	if not q.OverlayEnabled then return end -- only on High / Ultra / Max

	-- WORLD-space direction. PointLight goes straight down (streetlight),
	-- SpotLight/SurfaceLight follows the part's actual face orientation.
	local worldDir
	if light:IsA("PointLight") then
		worldDir = Vector3.new(0, -1, 0)
	else
		worldDir = worldFaceDir(parent, light.Face)
	end

	-- Both beams share these attachments
	local att0 = Instance.new("Attachment")
	att0.Name = "Cinematic_NightBeam_a0"
	att0.WorldPosition = parent.Position
	att0.Parent = parent

	local att1 = Instance.new("Attachment")
	att1.Name = "Cinematic_NightBeam_a1"
	att1.WorldPosition = parent.Position + worldDir * (light.Range * 0.85)
	att1.Parent = parent

	-- Helper: build a beam with a layer tag + opacity multiplier
	local function buildBeam(suffix, layer, w0, w1, opacityMul, segments)
		local b = Instance.new("Beam")
		b.Name           = "Cinematic_NightBeam_" .. suffix
		b.Attachment0    = att0
		b.Attachment1    = att1
		b.Color          = ColorSequence.new(light.Color)
		b.LightInfluence = 0
		b.LightEmission  = 1
		b.FaceCamera     = true
		b.Width0         = w0
		b.Width1         = w1
		b.Segments       = segments or 6
		b.Transparency   = NumberSequence.new(1)
		b.Enabled        = false
		b:SetAttribute("Cinematic_BeamLayer", layer)
		b:SetAttribute("Cinematic_OpacityMul", opacityMul)
		b.Parent         = parent
		CollectionService:AddTag(b, TAG_NIGHT_BEAM)
		return b
	end

	-- Vehicle-headlight detection: SpotLights inside a Model with a VehicleSeat
	-- get bigger, brighter beams since headlights throw way more visible light
	-- than streetlamps.
	local isVehicleLight = false
	if light:IsA("SpotLight") or light:IsA("SurfaceLight") then
		local model = parent:FindFirstAncestorOfClass("Model")
		if model and model:FindFirstChildOfClass("VehicleSeat") then
			isVehicleLight = true
		end
	end
	local widthMul = isVehicleLight and 1.6 or 1.0
	local maxInner = isVehicleLight and 4.0 or 1.4
	local maxInnerEnd = isVehicleLight and 6.0 or 3.0
	local maxOuter = isVehicleLight and 7.5 or 4.5
	local maxOuterEnd = isVehicleLight and 14.0 or 9.0
	local opacityMul = isVehicleLight and 1.25 or 1.0

	-- =====  INNER beam: tight, brighter core (the "shaft")  =====
	buildBeam("Inner", "inner",
		math.clamp(light.Range * 0.05 * widthMul, 0.25, maxInner),
		math.clamp(light.Range * 0.11 * widthMul, 0.5, maxInnerEnd),
		1.0 * opacityMul,
		6)

	-- =====  OUTER beam: wide, very soft halo (the "glow")  =====
	buildBeam("Outer", "outer",
		math.clamp(light.Range * 0.16 * widthMul, 0.6, maxOuter),
		math.clamp(light.Range * 0.32 * widthMul, 1.5, maxOuterEnd),
		0.40 * opacityMul,
		8)

	nightBeamCount = nightBeamCount + 1
end

function NightBeams.scan()
	if not State.NightBeams then return end
	task.spawn(function()
		local descendants = Workspace:GetDescendants()
		for i, d in ipairs(descendants) do
			if d:IsA("Light") then NightBeams.attach(d) end
			if i % 300 == 0 then task.wait() end
		end
	end)
end

function NightBeams.cleanup()
	for _, beam in ipairs(CollectionService:GetTagged(TAG_NIGHT_BEAM)) do
		local parent = beam.Parent
		if parent then
			local a0 = parent:FindFirstChild("Cinematic_NightBeam_a0")
			local a1 = parent:FindFirstChild("Cinematic_NightBeam_a1")
			if a0 then a0:Destroy() end
			if a1 then a1:Destroy() end
		end
		beam:Destroy()
	end
	nightBeamCount = 0
end

-- Real-time beam follow: re-projects attachments into world space EVERY frame
-- so moving / rotating lights are tracked at full frame rate. Without this,
-- attachment local offsets are baked at creation time and the beam "freezes"
-- relative to the original part orientation.
function NightBeams.updateRealtime()
	if not State.Enabled or not State.NightBeams then return end

	local cam = workspace.CurrentCamera
	if not cam then return end
	local camPos = cam.CFrame.Position

	-- Both beams per light share att0/att1, so dedupe by parent
	local processedParents = {}
	for _, beam in ipairs(CollectionService:GetTagged(TAG_NIGHT_BEAM)) do
		local parent = beam.Parent
		if parent and parent:IsA("BasePart") and not processedParents[parent] then
			local dist = (parent.Position - camPos).Magnitude
			if dist <= 220 then
				processedParents[parent] = true

				-- Find the light source on this part
				local light
				for _, child in ipairs(parent:GetChildren()) do
					if child:IsA("PointLight") or child:IsA("SpotLight") or child:IsA("SurfaceLight") then
						light = child
						break
					end
				end
				if light then
					local worldDir
					if light:IsA("PointLight") then
						worldDir = Vector3.new(0, -1, 0)
					else
						worldDir = worldFaceDir(parent, light.Face)
					end

					local att0 = parent:FindFirstChild("Cinematic_NightBeam_a0")
					local att1 = parent:FindFirstChild("Cinematic_NightBeam_a1")
					if att0 and att1 then
						att0.WorldPosition = parent.Position
						att1.WorldPosition = parent.Position + worldDir * (light.Range * 0.85)
					end

					-- Sync color on both layers
					local cs = ColorSequence.new(light.Color)
					for _, b in ipairs(parent:GetChildren()) do
						if b:IsA("Beam") and CollectionService:HasTag(b, TAG_NIGHT_BEAM) then
							b.Color = cs
						end
					end
				end
			end
		end
	end
end

-- =========================================================================
-- MODULE: RAY TRACE — actual reflection raycasts, blended into wet overlays
-- This is genuine ray casting: for nearby overlays we fire a real ray in the
-- reflection direction off the overlay's normal, sample the hit surface's
-- color, and blend it toward the overlay's baseline color. The Glass material
-- then renders with that environment-aware tint. Low sample count (≤14 rays
-- per tick at ~6 Hz) keeps it cheap; effect is per-overlay tint shifting as
-- the camera and surroundings move — Cyberpunk-RT-Diffuse on a budget.
-- =========================================================================

local RayTrace = {}
local ATTR_BASELINE  = "Cinematic_BaselineColor"
local lastTraceTick  = 0
local lastParamsBuilt = 0
local traceParams

local function rebuildTraceParams()
	traceParams = RaycastParams.new()
	traceParams.FilterType = Enum.RaycastFilterType.Exclude
	local excl = {}
	if LocalPlayer.Character then table.insert(excl, LocalPlayer.Character) end
	-- Don't reflect overlays into other overlays
	for _, ov in ipairs(CollectionService:GetTagged(TAG_OVERLAY)) do
		table.insert(excl, ov)
	end
	-- Don't reflect lens flare beams either
	for _, b in ipairs(CollectionService:GetTagged(TAG_NIGHT_BEAM)) do
		table.insert(excl, b)
	end
	traceParams.FilterDescendantsInstances = excl
end

local TRACE_DIST_MAX      = 130
local TRACE_RAY_LENGTH    = 340
local lastTracedIndex     = 0

-- Per-FRAME sample budget. At 60 fps this is now true real-time. Reads from
-- QualityProfiles so adding a new tier ("Max") just means setting one number.
--   Max:   16 × 60 = 960 primary + 960 2nd-bounce = ~1920 raycasts/sec
--   Ultra:  8 × 60 = 480/sec + 480/sec            = ~960 raycasts/sec
--   High:   5 × 60 = 300/sec + 300/sec            = ~600 raycasts/sec
local function tracesPerTick()
	local q = QualityProfiles[State.Quality]
	return (q and q.TracesPerTick) or 0
end

-- Trace ray cast distance per quality tier (how far reflections "see"). Bigger
-- numbers = more environment reflection accuracy at GPU cost. Max sees twice
-- as far as Ultra.
local function traceDist()
	local q = QualityProfiles[State.Quality]
	return (q and q.TraceDist) or TRACE_DIST_MAX
end

function RayTrace.update()
	if not State.Enabled or not State.RayTrace then return end
	-- Only the higher tiers do raycast reflections
	if State.Quality == "Low" then return end

	local cam = workspace.CurrentCamera
	if not cam then return end

	-- Rebuild filter params periodically to pick up new overlays / beams
	local now = os.clock()
	if not traceParams or now - lastParamsBuilt > 3 then
		rebuildTraceParams()
		lastParamsBuilt = now
	end

	local camPos    = cam.CFrame.Position
	local camLook   = cam.CFrame.LookVector
	local overlays  = CollectionService:GetTagged(TAG_OVERLAY)
	if #overlays == 0 then return end

	-- Round-robin so we don't always trace the same N overlays
	local count       = #overlays
	local startIx     = (lastTracedIndex % count) + 1
	local traced      = 0
	local i           = startIx
	local budget      = tracesPerTick()
	if budget == 0 then return end
	local maxDist     = traceDist()  -- quality-aware reflection range

	while traced < budget and traced < count do
		local overlay = overlays[i]
		if overlay and overlay.Parent then
			local floor = overlay.Parent
			if floor:IsA("BasePart") then
				local toOv = overlay.Position - camPos
				local dist = toOv.Magnitude

				-- Frustum-aware: skip overlays behind the camera unless they're
				-- very close (so you still get reflection updates for floors
				-- right under you). Lets the budget concentrate on overlays
				-- the player is actually looking at, like real RTX would.
				local inFront = (toOv.Unit):Dot(camLook) > -0.15 or dist < 25

				if dist > 2 and dist < maxDist and inFront then
					local viewDir = toOv / dist
					local normal  = overlay.CFrame.UpVector
					local upDot   = math.abs(viewDir:Dot(normal))
					-- Skip when looking nearly straight down (no useful reflection)
					if upDot < 0.94 then
						local reflDir = viewDir - 2 * viewDir:Dot(normal) * normal
						local origin  = overlay.Position + normal * 0.06
						local hit     = Workspace:Raycast(origin, reflDir * TRACE_RAY_LENGTH, traceParams)

						local baseline = overlay:GetAttribute(ATTR_BASELINE)
						if not baseline then
							local fc = floor.Color
							baseline = Color3.new(
								math.clamp(fc.R * 0.4 + 0.55, 0, 1),
								math.clamp(fc.G * 0.4 + 0.55, 0, 1),
								math.clamp(fc.B * 0.4 + 0.55, 0, 1)
							)
							overlay:SetAttribute(ATTR_BASELINE, baseline)
						end

						local target
						if hit and hit.Instance then
							local hc = hit.Instance.Color

							-- ===== SECOND BOUNCE =====
							-- Real path-tracing logic: from the first-hit surface,
							-- fire another reflection ray off ITS normal, sample
							-- whatever that hits, blend it into the first-hit color.
							-- This is what gives reflections their proper "color
							-- bleeding" — a wet floor near a red wall reflects the
							-- red wall, AND the red wall reflects the green sign on
							-- the building beyond it, etc.
							if State.MultiBounceRT then
								local hitNormal = hit.Normal
								-- Reflect the (now-incoming) reflDir off hit's normal
								local reflDir2  = reflDir - 2 * reflDir:Dot(hitNormal) * hitNormal
								local origin2   = hit.Position + hitNormal * 0.05
								local hit2 = Workspace:Raycast(origin2, reflDir2 * (TRACE_RAY_LENGTH * 0.65), traceParams)
								if hit2 and hit2.Instance then
									local h2c    = hit2.Instance.Color
									-- 2nd-bounce attenuation by distance
									local atten  = 1 - math.clamp(hit2.Distance / (TRACE_RAY_LENGTH * 0.65), 0, 1)
									local b2mix  = 0.22 + atten * 0.18  -- 22-40% influence
									hc = Color3.new(
										hc.R * (1 - b2mix) + h2c.R * b2mix,
										hc.G * (1 - b2mix) + h2c.G * b2mix,
										hc.B * (1 - b2mix) + h2c.B * b2mix
									)
								end
							end

							-- Stronger primary blend when ray hits something nearby
							local hitDistFalloff = 1 - math.clamp(hit.Distance / TRACE_RAY_LENGTH, 0, 1)
							local mix = 0.30 + hitDistFalloff * 0.25
							target = Color3.new(
								math.clamp(baseline.R * (1 - mix) + hc.R * mix, 0, 1),
								math.clamp(baseline.G * (1 - mix) + hc.G * mix, 0, 1),
								math.clamp(baseline.B * (1 - mix) + hc.B * mix, 0, 1)
							)
						else
							target = baseline
						end

						-- =====  ENHANCED GI  =====
						-- 6-tap hemisphere sampling for indirect light. Each sample
						-- shoots a short ray off the overlay normal into a rotated
						-- direction; the colors are averaged and blended into the
						-- overlay as bounced ambient — i.e. the floor near a red
						-- wall picks up a red wash from the wall's diffuse light.
						-- Full path-traced GI would integrate the rendering eqn over
						-- the hemisphere; six samples is enough to capture dominant
						-- nearby influences and reads as proper light bleed.
						if State.EnhancedGI then
							local sR, sG, sB, n = 0, 0, 0, 0
							for s = 1, 6 do
								local theta = (s / 6) * math.pi * 2
								local d = Vector3.new(
									math.cos(theta) * 0.78,
									0.55,
									math.sin(theta) * 0.78
								).Unit
								local giHit = Workspace:Raycast(origin, d * 60, traceParams)
								if giHit and giHit.Instance then
									sR = sR + giHit.Instance.Color.R
									sG = sG + giHit.Instance.Color.G
									sB = sB + giHit.Instance.Color.B
									n = n + 1
								end
							end
							if n > 0 then
								local giCol = Color3.new(sR / n, sG / n, sB / n)
								-- Subtle GI mix (real GI is usually ~5-15% of direct light contribution)
								local giMix = 0.18
								target = Color3.new(
									math.clamp(target.R * (1 - giMix) + giCol.R * giMix, 0, 1),
									math.clamp(target.G * (1 - giMix) + giCol.G * giMix, 0, 1),
									math.clamp(target.B * (1 - giMix) + giCol.B * giMix, 0, 1)
								)
							end
						end

						-- Bake the SSAO factor into the final target so AO
						-- shading from corners/crevices survives the per-frame
						-- ray-trace blend instead of getting overwritten.
						local aoFactor = overlay:GetAttribute("Cinematic_SSAOFactor")
						if aoFactor and aoFactor < 1 then
							target = Color3.new(target.R * aoFactor, target.G * aoFactor, target.B * aoFactor)
						end

						local cur = overlay.Color
						overlay.Color = Color3.new(
							cur.R + (target.R - cur.R) * 0.35,
							cur.G + (target.G - cur.G) * 0.35,
							cur.B + (target.B - cur.B) * 0.35
						)
						traced = traced + 1
					end
				end
			end
		end
		i = i + 1
		if i > count then i = 1 end
		if i == startIx then break end
	end

	lastTracedIndex = i
end

function RayTrace.reset()
	-- Snap every overlay back to its baseline (used when toggling RayTrace off)
	for _, overlay in ipairs(CollectionService:GetTagged(TAG_OVERLAY)) do
		local baseline = overlay:GetAttribute(ATTR_BASELINE)
		if baseline then overlay.Color = baseline end
	end
end

-- =========================================================================
-- MODULE: CAMERA FILL LIGHT — a real-time PointLight attached to the camera
-- Classic cinematography technique: a subtle key/fill light that follows the
-- camera, gives the foreground a soft directional rim. Color shifts warm in
-- daytime, cool at night, off in midday outdoor scenes.
-- =========================================================================

local CameraFill = {}
local fillPart, fillLight

function CameraFill.build()
	if fillPart and fillPart.Parent then return end
	fillPart = Instance.new("Part")
	fillPart.Name = "Cinematic_FillAnchor"
	fillPart.Anchored = true
	fillPart.CanCollide = false
	fillPart.CanTouch = false
	fillPart.CanQuery = false
	fillPart.Transparency = 1
	fillPart.Size = Vector3.new(0.05, 0.05, 0.05)
	fillPart.Locked = true
	fillPart.Massless = true
	fillPart.Parent = Workspace

	fillLight = Instance.new("PointLight")
	fillLight.Name = "Cinematic_FillLight"
	fillLight.Brightness = 0
	fillLight.Range = 30
	fillLight.Shadows = false
	fillLight.Color = Color3.fromRGB(255, 240, 220)
	fillLight.Parent = fillPart
end

function CameraFill.update(dt)
	if not State.Enabled or not State.CameraFillLight or not fillPart then return end
	local cam = workspace.CurrentCamera
	if not cam then return end

	-- Position the fill slightly above & behind the camera so it acts as
	-- a soft over-the-shoulder fill rather than a face-blaster
	local cf = cam.CFrame
	local pos = cf.Position + cf.UpVector * 1.5 - cf.LookVector * 0.5
	fillPart.CFrame = CFrame.new(pos)

	-- Brightness curve: stronger at night (fill the darkness), gentle at noon,
	-- intermediate at dawn/dusk. Eye-adaptation friendly.
	local dayBlend = PostFX.getDayBlend()
	local target = 0.55 * (1 - dayBlend * 0.7)  -- 0.55 at night, 0.16 at noon
	fillLight.Brightness = fillLight.Brightness + (target - fillLight.Brightness) * math.min(1, dt * 2)

	-- Color: warm during day/morning, cool moonlight at night
	local moonColor = Color3.fromRGB(190, 205, 235)
	local sunColor  = Color3.fromRGB(255, 240, 215)
	local r = moonColor.R + (sunColor.R - moonColor.R) * dayBlend
	local g = moonColor.G + (sunColor.G - moonColor.G) * dayBlend
	local b = moonColor.B + (sunColor.B - moonColor.B) * dayBlend
	fillLight.Color = Color3.new(r, g, b)
end

function CameraFill.cleanup()
	if fillPart then fillPart:Destroy(); fillPart = nil; fillLight = nil end
end

-- =========================================================================
-- MODULE: PLAYER HIGHLIGHT — subtle look-at highlight on other players.
-- Uses Roblox's Highlight instance with DepthMode = Occluded so it only shows
-- when the player is actually visible. Fill + outline fade in based on the
-- dot product between camera look direction and direction to the player.
-- Distance-attenuated so distant players don't get an invisibly-thin outline.
-- =========================================================================

local PlayerHighlight = {}
local TAG_HIGHLIGHT = "Cinematic_PlayerHL"
local HL_NAME       = "Cinematic_Highlight"

function PlayerHighlight.attach(character)
	if character == LocalPlayer.Character then return nil end
	if not character or not character.Parent then return nil end
	local existing = character:FindFirstChild(HL_NAME)
	if existing then return existing end

	local hl = Instance.new("Highlight")
	hl.Name              = HL_NAME
	hl.FillColor         = Color3.fromRGB(255, 240, 215)
	hl.OutlineColor      = Color3.fromRGB(255, 220, 185)
	hl.FillTransparency  = 1
	hl.OutlineTransparency = 1
	hl.DepthMode         = Enum.HighlightDepthMode.Occluded
	hl.Adornee           = character
	hl.Parent            = character
	CollectionService:AddTag(hl, TAG_HIGHLIGHT)
	return hl
end

function PlayerHighlight.bindAll()
	-- Existing players + their current characters
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			if player.Character then PlayerHighlight.attach(player.Character) end
			track(player.CharacterAdded:Connect(function(char)
				task.wait(0.2)  -- give body parts time to load
				PlayerHighlight.attach(char)
			end))
		end
	end
	-- Future players joining mid-session
	track(Players.PlayerAdded:Connect(function(player)
		track(player.CharacterAdded:Connect(function(char)
			task.wait(0.2)
			PlayerHighlight.attach(char)
		end))
	end))
end

function PlayerHighlight.cleanup()
	for _, hl in ipairs(CollectionService:GetTagged(TAG_HIGHLIGHT)) do
		hl:Destroy()
	end
end

-- =========================================================================
-- MODULE: SKY MOD — bumps the visible disc size of the sun and moon in the
-- sky so they read as bigger / more cinematic celestial bodies.
-- These properties live on the Sky instance (NOT on Lighting itself, which
-- is why an earlier attempt to set them on Lighting crashed). We only modify
-- if a Sky already exists in the place — never create a new one, since that
-- would replace the place's actual skybox.
-- =========================================================================

local SkyMod = {}
local OriginalSky

function SkyMod.apply()
	local sky = Lighting:FindFirstChildOfClass("Sky")
	if not sky then return false end

	if not OriginalSky then
		OriginalSky = {
			SunAngularSize  = sky.SunAngularSize,
			MoonAngularSize = sky.MoonAngularSize,
			StarCount       = sky.StarCount,
		}
	end

	sky.SunAngularSize  = 18      -- default 11 → bigger sun disc
	sky.MoonAngularSize = 25      -- default 11 → cinematic moon
	sky.StarCount       = math.max(sky.StarCount, 4500)  -- denser star field at night
	return true
end

function SkyMod.restore()
	if not OriginalSky then return end
	local sky = Lighting:FindFirstChildOfClass("Sky")
	if sky then
		sky.SunAngularSize  = OriginalSky.SunAngularSize
		sky.MoonAngularSize = OriginalSky.MoonAngularSize
		sky.StarCount       = OriginalSky.StarCount
	end
	OriginalSky = nil
end

-- =========================================================================
-- MODULE: FOLIAGE — enhance leaf / grass parts for richer greens
-- Pushes leaf parts toward deeper saturated green and adds tiny reflectance
-- so wet leaves shimmer under sun. Skips parts with SurfaceAppearance (PBR)
-- and skips character/accessory parts.
-- =========================================================================

local Foliage = {}
local TAG_FOLIAGE  = "Cinematic_FoliageProc"
local LEAF_MATERIALS = {
	[Enum.Material.Grass]      = true,
	[Enum.Material.LeafyGrass] = true,
}

function Foliage.enhance(part)
	if not part:IsA("BasePart") then return end
	if not LEAF_MATERIALS[part.Material] then return end
	if CollectionService:HasTag(part, TAG_FOLIAGE) then return end
	if Helpers.hasSurfaceAppearance(part) then return end
	if Helpers.isCharacterPart(part) then return end

	part:SetAttribute("Cinematic_OrigColor", part.Color)
	part:SetAttribute("Cinematic_OrigRefl",  part.Reflectance)

	-- Subtle: 8% darker, 5% green-channel lift, tiny reflectance for wet sheen
	local c = part.Color
	part.Color = Color3.new(
		math.clamp(c.R * 0.92, 0, 1),
		math.clamp(c.G * 0.96 + 0.04, 0, 1),
		math.clamp(c.B * 0.92, 0, 1)
	)
	if part.Reflectance < 0.04 then part.Reflectance = 0.04 end

	CollectionService:AddTag(part, TAG_FOLIAGE)
end

function Foliage.restore(part)
	if not CollectionService:HasTag(part, TAG_FOLIAGE) then return end
	local c = part:GetAttribute("Cinematic_OrigColor")
	local r = part:GetAttribute("Cinematic_OrigRefl")
	if c then part.Color = c end
	if r then part.Reflectance = r end
	part:SetAttribute("Cinematic_OrigColor", nil)
	part:SetAttribute("Cinematic_OrigRefl",  nil)
	CollectionService:RemoveTag(part, TAG_FOLIAGE)
end

function Foliage.scan()
	if not State.FoliageEnhance then return end
	task.spawn(function()
		for i, d in ipairs(Workspace:GetDescendants()) do
			if d:IsA("BasePart") then Foliage.enhance(d) end
			if i % 300 == 0 then task.wait() end
		end
	end)
end

function Foliage.cleanup()
	task.spawn(function()
		for i, p in ipairs(CollectionService:GetTagged(TAG_FOLIAGE)) do
			Foliage.restore(p)
			if i % 200 == 0 then task.wait() end
		end
	end)
end

-- =========================================================================
-- MODULE: FIRE ENHANCE — vivid color + bumped size/heat on Fire instances
-- =========================================================================

local FireMod = {}
local TAG_FIRE = "Cinematic_FireProc"

function FireMod.enhance(fire)
	if not fire:IsA("Fire") then return end
	if CollectionService:HasTag(fire, TAG_FIRE) then return end

	fire:SetAttribute("Cinematic_OrigColor",     fire.Color)
	fire:SetAttribute("Cinematic_OrigSecondary", fire.SecondaryColor)
	fire:SetAttribute("Cinematic_OrigSize",      fire.Size)
	fire:SetAttribute("Cinematic_OrigHeat",      fire.Heat)

	-- Vibrant flame palette: orange core with bright yellow tips
	fire.Color          = Color3.fromRGB(255, 105, 25)
	fire.SecondaryColor = Color3.fromRGB(255, 215, 70)
	-- Bump size 15% (capped) and heat for stronger dynamic glow
	fire.Size = math.min(fire.Size * 1.15, fire.Size + 1.5)
	fire.Heat = math.max(fire.Heat, 14)

	CollectionService:AddTag(fire, TAG_FIRE)
end

function FireMod.restore(fire)
	if not CollectionService:HasTag(fire, TAG_FIRE) then return end
	local c  = fire:GetAttribute("Cinematic_OrigColor")
	local sc = fire:GetAttribute("Cinematic_OrigSecondary")
	local sz = fire:GetAttribute("Cinematic_OrigSize")
	local h  = fire:GetAttribute("Cinematic_OrigHeat")
	if c  then fire.Color          = c  end
	if sc then fire.SecondaryColor = sc end
	if sz then fire.Size           = sz end
	if h  then fire.Heat           = h  end
	fire:SetAttribute("Cinematic_OrigColor",     nil)
	fire:SetAttribute("Cinematic_OrigSecondary", nil)
	fire:SetAttribute("Cinematic_OrigSize",      nil)
	fire:SetAttribute("Cinematic_OrigHeat",      nil)
	CollectionService:RemoveTag(fire, TAG_FIRE)
end

function FireMod.scan()
	if not State.FireEnhance then return end
	task.spawn(function()
		for i, d in ipairs(Workspace:GetDescendants()) do
			if d:IsA("Fire") then FireMod.enhance(d) end
			if i % 400 == 0 then task.wait() end
		end
	end)
end

function FireMod.cleanup()
	for _, f in ipairs(CollectionService:GetTagged(TAG_FIRE)) do
		FireMod.restore(f)
	end
end

-- =========================================================================
-- MODULE: SMOKE — denser, darker, taller smoke columns near fire
-- =========================================================================

local SmokeMod = {}
local TAG_SMOKE = "Cinematic_SmokeProc"

function SmokeMod.enhance(smoke)
	if not smoke:IsA("Smoke") then return end
	if CollectionService:HasTag(smoke, TAG_SMOKE) then return end

	smoke:SetAttribute("Cinematic_OrigColor",   smoke.Color)
	smoke:SetAttribute("Cinematic_OrigSize",    smoke.Size)
	smoke:SetAttribute("Cinematic_OrigOpacity", smoke.Opacity)
	smoke:SetAttribute("Cinematic_OrigRise",    smoke.RiseVelocity)

	smoke.Color        = Color3.fromRGB(38, 36, 33)   -- dense dark grey
	smoke.Size         = math.min(smoke.Size * 1.2, smoke.Size + 2)
	smoke.Opacity      = math.max(smoke.Opacity, 0.62)
	smoke.RiseVelocity = math.max(smoke.RiseVelocity, 8)

	CollectionService:AddTag(smoke, TAG_SMOKE)
end

function SmokeMod.restore(smoke)
	if not CollectionService:HasTag(smoke, TAG_SMOKE) then return end
	local c = smoke:GetAttribute("Cinematic_OrigColor")
	local s = smoke:GetAttribute("Cinematic_OrigSize")
	local o = smoke:GetAttribute("Cinematic_OrigOpacity")
	local r = smoke:GetAttribute("Cinematic_OrigRise")
	if c then smoke.Color        = c end
	if s then smoke.Size         = s end
	if o then smoke.Opacity      = o end
	if r then smoke.RiseVelocity = r end
	smoke:SetAttribute("Cinematic_OrigColor",   nil)
	smoke:SetAttribute("Cinematic_OrigSize",    nil)
	smoke:SetAttribute("Cinematic_OrigOpacity", nil)
	smoke:SetAttribute("Cinematic_OrigRise",    nil)
	CollectionService:RemoveTag(smoke, TAG_SMOKE)
end

function SmokeMod.scan()
	if not State.SmokeEnhance then return end
	task.spawn(function()
		for i, d in ipairs(Workspace:GetDescendants()) do
			if d:IsA("Smoke") then SmokeMod.enhance(d) end
			if i % 400 == 0 then task.wait() end
		end
	end)
end

function SmokeMod.cleanup()
	for _, s in ipairs(CollectionService:GetTagged(TAG_SMOKE)) do
		SmokeMod.restore(s)
	end
end

-- =========================================================================
-- MODULE: SPARKLES — vivid, slightly bigger sparkles for magic / particle FX
-- =========================================================================

local SparklesMod = {}
local TAG_SPARKLE = "Cinematic_SparkleProc"

function SparklesMod.enhance(sparkle)
	if not sparkle:IsA("Sparkles") then return end
	if CollectionService:HasTag(sparkle, TAG_SPARKLE) then return end

	sparkle:SetAttribute("Cinematic_OrigColor", sparkle.SparkleColor)
	-- Boost saturation: lift each channel by 15%, keep within color
	local c = sparkle.SparkleColor
	sparkle.SparkleColor = Color3.new(
		math.clamp(c.R * 1.12 + 0.05, 0, 1),
		math.clamp(c.G * 1.12 + 0.05, 0, 1),
		math.clamp(c.B * 1.12 + 0.05, 0, 1)
	)
	CollectionService:AddTag(sparkle, TAG_SPARKLE)
end

function SparklesMod.restore(sparkle)
	if not CollectionService:HasTag(sparkle, TAG_SPARKLE) then return end
	local c = sparkle:GetAttribute("Cinematic_OrigColor")
	if c then sparkle.SparkleColor = c end
	sparkle:SetAttribute("Cinematic_OrigColor", nil)
	CollectionService:RemoveTag(sparkle, TAG_SPARKLE)
end

function SparklesMod.scan()
	if not State.SparklesEnhance then return end
	task.spawn(function()
		for i, d in ipairs(Workspace:GetDescendants()) do
			if d:IsA("Sparkles") then SparklesMod.enhance(d) end
			if i % 400 == 0 then task.wait() end
		end
	end)
end

function SparklesMod.cleanup()
	for _, s in ipairs(CollectionService:GetTagged(TAG_SPARKLE)) do
		SparklesMod.restore(s)
	end
end

-- =========================================================================
-- MODULE: WATER — Workspace.Terrain water properties for cinematic lakes
-- =========================================================================

local WaterMod = {}
local OriginalWater

local WATER_PROFILE = {
	WaterColor        = Color3.fromRGB(38, 84, 110),
	WaterReflectance  = 0.45,
	WaterTransparency = 0.30,
	WaterWaveSize     = 0.15,
	WaterWaveSpeed    = 8,
}

function WaterMod.apply()
	if not State.WaterEnhance then return end
	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if not terrain then return end
	if not OriginalWater then
		OriginalWater = {
			WaterColor        = terrain.WaterColor,
			WaterReflectance  = terrain.WaterReflectance,
			WaterTransparency = terrain.WaterTransparency,
			WaterWaveSize     = terrain.WaterWaveSize,
			WaterWaveSpeed    = terrain.WaterWaveSpeed,
		}
	end
	for k, v in pairs(WATER_PROFILE) do terrain[k] = v end
end

function WaterMod.restore()
	if not OriginalWater then return end
	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if terrain then
		for k, v in pairs(OriginalWater) do terrain[k] = v end
	end
	OriginalWater = nil
end

-- =========================================================================
-- MODULE: PRECIPITATION — rain (Stormy) and snow (Misty) following the camera
-- A camera-anchored part with a ParticleEmitter; configures itself based on
-- the current Weather. The part stays above the camera so particles fall
-- "everywhere" without world-space spawning logic.
-- =========================================================================

local Precipitation = {}
local rainPart, rainEmitter

function Precipitation.build()
	if rainPart and rainPart.Parent then return end
	rainPart = Instance.new("Part")
	rainPart.Name = "Cinematic_Precipitation"
	rainPart.Anchored = true
	rainPart.CanCollide = false
	rainPart.CanTouch = false
	rainPart.CanQuery = false
	rainPart.Massless = true
	rainPart.Locked = true
	rainPart.Transparency = 1
	rainPart.Size = Vector3.new(60, 1, 60)
	rainPart.Parent = Workspace

	rainEmitter = Instance.new("ParticleEmitter")
	rainEmitter.Name = "Cinematic_PrecipEmitter"
	rainEmitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	rainEmitter.LightInfluence = 0
	rainEmitter.LightEmission = 0.4
	rainEmitter.Color = ColorSequence.new(Color3.fromRGB(220, 230, 240))
	rainEmitter.Size = NumberSequence.new(0.3)
	rainEmitter.Transparency = NumberSequence.new(0.45)
	rainEmitter.Lifetime = NumberRange.new(0.5, 1.0)
	rainEmitter.Rate = 0
	rainEmitter.Rotation = NumberRange.new(0, 0)
	rainEmitter.SpreadAngle = Vector2.new(6, 6)
	rainEmitter.Speed = NumberRange.new(60, 90)
	rainEmitter.Acceleration = Vector3.new(0, -50, 0)
	rainEmitter.Enabled = false
	rainEmitter.Parent = rainPart
end

local lastIndoorCheck = 0
local cachedIndoor    = false

function Precipitation.update()
	if not rainPart or not rainEmitter then return end
	local cam = workspace.CurrentCamera
	if not cam then return end

	-- Position part 25 studs above camera
	rainPart.CFrame = CFrame.new(cam.CFrame.Position + Vector3.new(0, 25, 0))

	if not State.Enabled or not State.Precipitation then
		rainEmitter.Enabled = false
		return
	end

	-- Indoor detection: cast a ray straight up from the camera. If it hits
	-- something within 80 studs, we're under cover — disable precipitation
	-- so it doesn't rain INSIDE buildings. Cached at 0.4 Hz to be cheap.
	local now = os.clock()
	if now - lastIndoorCheck > 0.4 then
		lastIndoorCheck = now
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		local excl = { rainPart }
		if LocalPlayer.Character then table.insert(excl, LocalPlayer.Character) end
		rp.FilterDescendantsInstances = excl
		local hit = Workspace:Raycast(cam.CFrame.Position + Vector3.new(0, 1, 0),
			Vector3.new(0, 80, 0), rp)
		cachedIndoor = hit ~= nil
	end

	if cachedIndoor then
		rainEmitter.Enabled = false
		return
	end

	if State.Weather == "Stormy" then
		rainEmitter.Enabled  = true
		rainEmitter.Rate     = 600
		rainEmitter.Color    = ColorSequence.new(Color3.fromRGB(215, 225, 240))
		rainEmitter.Size     = NumberSequence.new(0.25)
		rainEmitter.Speed    = NumberRange.new(85, 115)
		rainEmitter.Acceleration = Vector3.new(0, -85, 0)
		rainEmitter.Lifetime = NumberRange.new(0.45, 0.85)
		rainEmitter.Transparency = NumberSequence.new(0.40)
	elseif State.Weather == "Misty" then
		-- Snow: slow, drifty, rounder flakes
		rainEmitter.Enabled  = true
		rainEmitter.Rate     = 180
		rainEmitter.Color    = ColorSequence.new(Color3.fromRGB(255, 255, 255))
		rainEmitter.Size     = NumberSequence.new(0.5)
		rainEmitter.Speed    = NumberRange.new(8, 16)
		rainEmitter.Acceleration = Vector3.new(0, -8, 0)
		rainEmitter.Lifetime = NumberRange.new(2.0, 4.0)
		rainEmitter.Transparency = NumberSequence.new(0.30)
	else
		rainEmitter.Enabled = false
	end
end

function Precipitation.cleanup()
	if rainPart then rainPart:Destroy(); rainPart = nil; rainEmitter = nil end
end

-- =========================================================================
-- MODULE: LIGHTNING — random brief flashes during Stormy weather
-- Pulses ColorCorrection brightness (not Lighting.Brightness — that fights
-- with the running tweens). Two-strike pattern for realism.
-- =========================================================================

local Lightning = {}
local nextStrike = math.huge

function Lightning.update()
	if not State.Enabled or not State.Lightning then return end
	if State.Weather ~= "Stormy" then return end
	if not FX.CCMain then return end

	local now = os.clock()
	if now < nextStrike then return end
	-- Schedule next strike 5–22 seconds away
	nextStrike = now + 5 + math.random() * 17

	task.spawn(function()
		local cc = FX.CCMain
		local origBright = cc.Brightness
		-- First strike
		cc.Brightness = origBright + 0.50
		task.wait(0.05)
		cc.Brightness = origBright + 0.05
		task.wait(0.04)
		-- Second strike (brighter)
		cc.Brightness = origBright + 0.65
		task.wait(0.07)
		-- Smooth fade back over 0.4s
		TweenService:Create(cc, TweenInfo.new(0.4, Enum.EasingStyle.Quart), {
			Brightness = origBright,
		}):Play()
	end)
end

-- =========================================================================
-- MODULE: DAY/NIGHT CYCLE — slowly advance Lighting.ClockTime over real time
-- Won't override server-controlled time (server's tick wins next frame).
-- Useful for static-time places.
-- =========================================================================

local CycleMod = {}

function CycleMod.update(dt)
	if not State.Enabled or not State.AutoCycle then return end
	-- ClockTime advances by State.CycleSpeed units per second of real time
	Lighting.ClockTime = (Lighting.ClockTime + State.CycleSpeed * dt) % 24
end

-- =========================================================================
-- MODULE: UNDERWATER — detect camera in terrain water, apply blue blur shader
-- Uses Region3 sampling around the camera; checks for Water voxels.
-- =========================================================================

local UnderwaterMod = {}
local lastUWTick = 0
local uwActive = false
local origUWState

function UnderwaterMod.update()
	if not State.Enabled or not State.Underwater then
		if uwActive then
			-- Cancel underwater effect immediately
			uwActive = false
			if FX.CCMain and origUWState then
				TweenService:Create(FX.CCMain, TweenInfo.new(0.4), {
					Brightness = origUWState.Brightness,
					TintColor  = origUWState.TintColor,
				}):Play()
				if FX.Blur then
					TweenService:Create(FX.Blur, TweenInfo.new(0.4), { Size = 0 }):Play()
				end
				origUWState = nil
			end
		end
		return
	end

	local now = os.clock()
	if now - lastUWTick < 0.3 then return end
	lastUWTick = now

	local cam = workspace.CurrentCamera
	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if not cam or not terrain then return end

	-- Sample a small Region3 around the camera for Water material
	local pos = cam.CFrame.Position
	local r3 = Region3.new(pos - Vector3.new(2, 2, 2), pos + Vector3.new(2, 2, 2))
		:ExpandToGrid(4)
	local ok, materials, occupancies = pcall(function()
		return terrain:ReadVoxels(r3, 4)
	end)
	if not ok or not materials then return end

	local isUnder = false
	for x = 1, materials.Size.X do
		for y = 1, materials.Size.Y do
			for z = 1, materials.Size.Z do
				if materials[x][y][z] == Enum.Material.Water and occupancies[x][y][z] > 0.5 then
					isUnder = true
					break
				end
			end
			if isUnder then break end
		end
		if isUnder then break end
	end

	if isUnder and not uwActive then
		uwActive = true
		origUWState = {
			Brightness = FX.CCMain.Brightness,
			TintColor  = FX.CCMain.TintColor,
		}
		TweenService:Create(FX.CCMain, TweenInfo.new(0.4), {
			Brightness = -0.08,
			TintColor  = Color3.fromRGB(80, 130, 175),
		}):Play()
		if FX.Blur then
			TweenService:Create(FX.Blur, TweenInfo.new(0.4), { Size = 6 }):Play()
		end
	elseif not isUnder and uwActive then
		uwActive = false
		if origUWState then
			TweenService:Create(FX.CCMain, TweenInfo.new(0.4), {
				Brightness = origUWState.Brightness,
				TintColor  = origUWState.TintColor,
			}):Play()
			if FX.Blur then
				TweenService:Create(FX.Blur, TweenInfo.new(0.4), { Size = 0 }):Play()
			end
		end
	end
end

-- =========================================================================
-- MODULE: FREE CAMERA — disconnect camera from character for cinematic shots
-- WASD = horizontal move (relative to camera look)
-- Q/E = vertical down/up
-- LeftShift = sprint
-- Mouse delta = look
-- Toggling off restores Camera.CameraType + reattaches to character.
-- =========================================================================

local FreeCam = {}
local freeCamPosition
local freeCamYaw   = 0   -- accumulated rotation around world Y
local freeCamPitch = 0   -- accumulated rotation around local X (clamped)
local freeCamConn
local freeCamInputBegan, freeCamInputEnded, freeCamInputChanged
local origCameraType, origMouseBehavior
local moveKeys = {}

local function flatLookYaw(lookVec)
	return math.atan2(-lookVec.X, -lookVec.Z)
end

function FreeCam.enable()
	local cam = workspace.CurrentCamera
	if not cam then return end
	if freeCamPosition then return end -- already on

	origCameraType    = cam.CameraType
	origMouseBehavior = UserInputService.MouseBehavior

	-- Initialize position + angles from current camera so toggle-on doesn't snap
	freeCamPosition = cam.CFrame.Position
	freeCamYaw      = flatLookYaw(cam.CFrame.LookVector)
	freeCamPitch    = math.asin(math.clamp(cam.CFrame.LookVector.Y, -1, 1))

	cam.CameraType = Enum.CameraType.Scriptable
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter

	-- Track key state (block default behavior on movement keys to keep
	-- character still while in free cam)
	freeCamInputBegan = UserInputService.InputBegan:Connect(function(input, gp)
		if gp then return end
		moveKeys[input.KeyCode] = true
	end)
	freeCamInputEnded = UserInputService.InputEnded:Connect(function(input)
		moveKeys[input.KeyCode] = nil
	end)

	-- Mouse delta → accumulated yaw/pitch (cleaner than CFrame decomposition)
	freeCamInputChanged = UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
		local s = 0.0035
		freeCamYaw   = freeCamYaw   - input.Delta.X * s
		freeCamPitch = math.clamp(freeCamPitch - input.Delta.Y * s, -math.rad(85), math.rad(85))
	end)

	-- Per-frame: build CFrame from accumulators, apply movement
	freeCamConn = RunService.RenderStepped:Connect(function(dt)
		local rot = CFrame.Angles(0, freeCamYaw, 0) * CFrame.Angles(freeCamPitch, 0, 0)
		local cf  = CFrame.new(freeCamPosition) * rot

		local moveDir = Vector3.zero
		if moveKeys[Enum.KeyCode.W] then moveDir = moveDir + cf.LookVector end
		if moveKeys[Enum.KeyCode.S] then moveDir = moveDir - cf.LookVector end
		if moveKeys[Enum.KeyCode.A] then moveDir = moveDir - cf.RightVector end
		if moveKeys[Enum.KeyCode.D] then moveDir = moveDir + cf.RightVector end
		if moveKeys[Enum.KeyCode.E] then moveDir = moveDir + Vector3.new(0, 1, 0) end
		if moveKeys[Enum.KeyCode.Q] then moveDir = moveDir - Vector3.new(0, 1, 0) end
		if moveDir.Magnitude > 0.01 then
			local speed = moveKeys[Enum.KeyCode.LeftShift] and 90 or 30
			freeCamPosition = freeCamPosition + moveDir.Unit * speed * dt
			cf = CFrame.new(freeCamPosition) * rot
		end
		cam.CFrame = cf
	end)

	-- Briefly hint controls (uses existing toast helper, fades after 5s)
	pcall(function()
		showToast("Free Camera ON — WASD move • Q/E down/up • Shift sprint • Mouse look", 5)
	end)
end

function FreeCam.disable()
	local cam = workspace.CurrentCamera
	if not cam then return end
	if freeCamConn         then freeCamConn:Disconnect()         freeCamConn = nil end
	if freeCamInputBegan   then freeCamInputBegan:Disconnect()   freeCamInputBegan = nil end
	if freeCamInputEnded   then freeCamInputEnded:Disconnect()   freeCamInputEnded = nil end
	if freeCamInputChanged then freeCamInputChanged:Disconnect() freeCamInputChanged = nil end
	freeCamPosition = nil
	moveKeys = {}
	UserInputService.MouseBehavior = origMouseBehavior or Enum.MouseBehavior.Default
	cam.CameraType = origCameraType or Enum.CameraType.Custom
end

-- =========================================================================
-- TONEMAPS — additional ColorCorrectionEffect chained after Main+Grade for
-- film-stock-style highlight/shadow shaping. Each preset is a tiny CC
-- adjustment that simulates a tonemap curve.
-- =========================================================================

local TONEMAPS = {
	Linear    = { Brightness = 0.0,   Contrast = 0.0,  Saturation = 0.0  },
	Filmic    = { Brightness = 0.005, Contrast = 0.06, Saturation = 0.03 },
	ACES      = { Brightness = -0.01, Contrast = 0.10, Saturation = 0.06 },
	Punchy    = { Brightness = 0.0,   Contrast = 0.14, Saturation = 0.10 },
	Reinhard  = { Brightness = 0.0,   Contrast = 0.04, Saturation = 0.02 },  -- gentle classic
	Cinematic = { Brightness = -0.02, Contrast = 0.16, Saturation = 0.08 },  -- deep contrast film
}

function PlayerHighlight.update()
	if not State.Enabled or not State.PlayerHighlight then return end
	local cam = workspace.CurrentCamera
	if not cam then return end

	local camPos  = cam.CFrame.Position
	local camLook = cam.CFrame.LookVector

	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			local char = player.Character
			if char then
				local root = char:FindFirstChild("HumanoidRootPart")
				if root then
					local hl = char:FindFirstChild(HL_NAME)
					if not hl then hl = PlayerHighlight.attach(char) end
					if hl then
						local toChar = root.Position - camPos
						local dist = toChar.Magnitude
						local targetFill, targetOutline

						if dist < 3 or dist > 220 then
							targetFill, targetOutline = 1, 1
						else
							local dir = toChar / dist
							local dot = dir:Dot(camLook)
							-- Soft cone: starts at ~25° from view center, full at center
							local lookFactor = math.clamp((dot - 0.86) / 0.14, 0, 1)
							-- Distance attenuation: full up to 30 studs, fades to 40% by 200
							local distFactor = 1 - math.clamp((dist - 30) / 170, 0, 0.6)
							local intensity  = lookFactor * distFactor

							targetFill    = 1 - intensity * 0.16  -- max 16% fill (subtle)
							targetOutline = 1 - intensity * 0.55  -- max 55% outline (visible)
						end

						hl.FillTransparency    = hl.FillTransparency
							+ (targetFill - hl.FillTransparency) * 0.18
						hl.OutlineTransparency = hl.OutlineTransparency
							+ (targetOutline - hl.OutlineTransparency) * 0.18
					end
				end
			end
		end
	end
end

-- Visibility / transparency update: runs every frame, but the expensive
-- NumberSequence rebuild only fires when strength has shifted meaningfully.
-- Without caching this would allocate a new NumberSequence per beam per frame
-- → garbage-collector pressure on maps with hundreds of beams.
local lastStrengthApplied = -1
function NightBeams.update()
	if not State.Enabled then return end

	local night = math.clamp(1 - PostFX.getDayBlend(), 0, 1)
	-- Don't show until well past sunset / before sunrise
	local strength = math.max(0, (night - 0.35) / 0.65)
	local visible  = State.NightBeams and strength > 0.04

	-- Skip rebuilding curves if nothing visible has changed since last frame.
	if math.abs(strength - lastStrengthApplied) < 0.015 then return end
	lastStrengthApplied = strength

	for _, beam in ipairs(CollectionService:GetTagged(TAG_NIGHT_BEAM)) do
		if beam.Parent then
			beam.Enabled = visible
			if visible then
				-- Per-layer opacity: inner beam = full, outer halo = 40%.
				-- Combined effect = bright tight shaft inside soft diffuse glow.
				local opacityMul = beam:GetAttribute("Cinematic_OpacityMul") or 1
				local startT = 1 - (strength * 0.32 * opacityMul)
				local span   = 1 - startT
				beam.Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0,    startT),
					NumberSequenceKeypoint.new(0.22, startT + span * 0.18),
					NumberSequenceKeypoint.new(0.48, startT + span * 0.45),
					NumberSequenceKeypoint.new(0.74, startT + span * 0.75),
					NumberSequenceKeypoint.new(0.92, startT + span * 0.95),
					NumberSequenceKeypoint.new(1,    1),
				})
			end
		end
	end
end

-- =========================================================================
-- MODULE: DETECTION — initial scan + live watcher + heartbeat queue
-- =========================================================================

local Detection = {}

local pendingQueue = {}
local pendingHead, pendingTail = 1, 0
local pendingDedup = {}

function Detection.enqueue(part)
	if not part:IsA("BasePart") then return end
	if Helpers.isOurOverlay(part) then return end
	if pendingDedup[part] then return end
	if CollectionService:HasTag(part, TAG_PROCESSED) then return end
	pendingDedup[part] = true
	pendingTail = pendingTail + 1
	pendingQueue[pendingTail] = part
end

local function dequeue()
	if pendingHead > pendingTail then return nil end
	local part = pendingQueue[pendingHead]
	pendingQueue[pendingHead] = nil
	pendingHead = pendingHead + 1
	if pendingHead > pendingTail then
		pendingHead, pendingTail = 1, 0
	end
	return part
end

function Detection.flush()
	pendingQueue = {}
	pendingHead, pendingTail = 1, 0
	table.clear(pendingDedup)
end

function Detection.scan()
	task.spawn(function()
		local descendants = Workspace:GetDescendants()
		local batch = Profile.Performance.ScanBatch
		for i, descendant in ipairs(descendants) do
			if descendant:IsA("BasePart") then
				Detection.enqueue(descendant)
			end
			if i % batch == 0 then task.wait() end
		end
	end)
end

function Detection.bindAdded()
	track(Workspace.DescendantAdded:Connect(function(descendant)
		if not State.Enabled then return end
		if descendant:IsA("BasePart") then
			Detection.enqueue(descendant)
			if State.FoliageEnhance then Foliage.enhance(descendant) end
		elseif descendant:IsA("Light") then
			if State.LightEnhance then Lights.enhance(descendant) end
			if State.NightBeams   then NightBeams.attach(descendant) end
		elseif descendant:IsA("Fire") then
			if State.FireEnhance then FireMod.enhance(descendant) end
		elseif descendant:IsA("Smoke") then
			if State.SmokeEnhance then SmokeMod.enhance(descendant) end
		elseif descendant:IsA("Sparkles") then
			if State.SparklesEnhance then SparklesMod.enhance(descendant) end
		end
	end))
end

track(RunService.Heartbeat:Connect(function()
	if not State.Enabled then return end
	local budget = Profile.Performance.ProcessBudget
	local i = 0
	while i < budget do
		local part = dequeue()
		if not part then break end
		pendingDedup[part] = nil
		if part.Parent then
			Materials.process(part)
		end
		i = i + 1
	end
end))

-- =========================================================================
-- MODULE: ADAPTIVE — re-tween FX as time of day shifts
-- =========================================================================

local Adaptive = {}

function Adaptive.start()
	task.spawn(function()
		local lastBlend = -1
		while task.wait(2) do
			if State.Enabled and FX.Bloom and FX.Bloom.Parent then
				local newBlend = PostFX.getDayBlend()
				if math.abs(newBlend - lastBlend) > 0.04 then
					lastBlend = newBlend
					PostFX.applyIntensity(1.5)
				end
			end
		end
	end)
end

-- =========================================================================
-- MODULE: ADVANCED COLOR — Kelvin white balance, vibrance, hue, lift/gamma/gain.
-- Each control drives a dedicated ColorCorrectionEffect, chained between
-- CCMain and CCGrade. Layers stay disabled (`Enabled = false`) while their
-- slider sits at neutral, so the pipeline is zero-cost until the user moves
-- something. Roblox CC effects only expose Brightness/Contrast/Saturation/Tint,
-- so anything fancier (per-channel curves, real hue rotation) has to be
-- approximated by combining those four properties — close enough for cinema.
-- =========================================================================

local AdvancedColor = {}

-- Planckian black-body locus → RGB tint. Standard Tanner Helland approximation;
-- accurate enough across the 1500 K-15000 K photographic range.
local function kelvinToColor(K)
	K = math.clamp(K, 1500, 15000) / 100
	local R, G, B
	if K <= 66 then
		R = 255
	else
		R = math.clamp(329.698727446 * ((K - 60) ^ -0.1332047592), 0, 255)
	end
	if K <= 66 then
		G = math.clamp(99.4708025861 * math.log(math.max(K, 1)) - 161.1195681661, 0, 255)
	else
		G = math.clamp(288.1221695283 * ((K - 60) ^ -0.0755148492), 0, 255)
	end
	if K >= 66 then
		B = 255
	elseif K <= 19 then
		B = 0
	else
		B = math.clamp(138.5177312231 * math.log(math.max(K - 10, 1)) - 305.0447927307, 0, 255)
	end
	return Color3.fromRGB(R, G, B)
end

function AdvancedColor.apply(time)
	if not FX.CCWhiteBal then return end
	time = time or 0.4
	local ti = TweenInfo.new(time, Enum.EasingStyle.Quad)

	-- ===== WHITE BALANCE =====
	-- Kelvin tint + green/magenta correction. Disabled when the slider is
	-- exactly neutral so the pipeline stays zero-cost.
	local wbActive = State.WhiteBalance ~= 6500 or State.WBTint ~= 0
	if wbActive then
		local k = kelvinToColor(State.WhiteBalance)
		local tintMag = State.WBTint / 100   -- +1 = magenta, -1 = green
		-- Push G down for magenta, up for green
		local r = k.R
		local g = math.clamp(k.G - tintMag * 0.18, 0, 1)
		local b = math.clamp(k.B + tintMag * 0.05, 0, 1)
		FX.CCWhiteBal.Enabled = true
		TweenService:Create(FX.CCWhiteBal, ti, {
			TintColor  = Color3.new(r, g, b),
			Brightness = 0, Contrast = 0, Saturation = 0,
		}):Play()
	else
		FX.CCWhiteBal.Enabled = false
	end

	-- ===== LIFT / GAMMA / GAIN =====
	-- Lift = shadow brightness (Brightness shift)
	-- Gamma = midtone curve (approximated by tweaking Contrast inversely)
	-- Gain = highlight intensity (Contrast + slight brightness lift)
	local lggActive = State.Lift ~= 0 or State.Gamma ~= 1 or State.Gain ~= 1
	if lggActive then
		FX.CCLGG.Enabled = true
		-- Gain > 1 = punchier highlights → boost Contrast.
		-- Gamma < 1 = darker mids → boost Contrast.
		-- Gamma > 1 = lifted mids → reduce Contrast.
		local gammaInfluence = (1 - State.Gamma) * 0.25   -- -1..1 → -0.25..0.25
		local gainInfluence  = (State.Gain - 1) * 0.4     -- 0..4  → 0..1.6 capped below
		local liftBoost      = State.Lift * 0.35
		TweenService:Create(FX.CCLGG, ti, {
			Brightness = liftBoost,
			Contrast   = math.clamp(gainInfluence + gammaInfluence, -0.5, 0.5),
			Saturation = 0,
			TintColor  = Color3.new(1, 1, 1),
		}):Play()
	else
		FX.CCLGG.Enabled = false
	end

	-- ===== VIBRANCE =====
	-- Roblox doesn't expose true vibrance (saturation-of-low-saturation pixels),
	-- so we drive global Saturation at half strength — close enough that high-sat
	-- pixels don't clip into oversaturation immediately.
	if State.Vibrance ~= 0 then
		FX.CCVibrance.Enabled = true
		TweenService:Create(FX.CCVibrance, ti, {
			Saturation = (State.Vibrance / 100) * 0.55,
			Brightness = 0, Contrast = 0, TintColor = Color3.new(1, 1, 1),
		}):Play()
	else
		FX.CCVibrance.Enabled = false
	end

	-- ===== HUE SHIFT =====
	-- True hue rotation requires a 3×3 matrix multiply per pixel, which Roblox's
	-- CC effect can't do. Best approximation: convert the hue rotation into
	-- a low-saturation TintColor, which biases the entire image toward that hue
	-- without destroying neutral tones. Looks correct for ±90° rotations and
	-- exaggerates for larger values, which is fine for cinematic regrades.
	if State.HueShift ~= 0 then
		FX.CCHue.Enabled = true
		local h = ((State.HueShift + 360) % 360) / 360
		local tint = Color3.fromHSV(h, 0.35, 1)
		TweenService:Create(FX.CCHue, ti, {
			TintColor  = tint,
			Brightness = 0, Contrast = 0, Saturation = 0,
		}):Play()
	else
		FX.CCHue.Enabled = false
	end
end

-- =========================================================================
-- MODULE: FILM GRAIN — animated noise overlay
-- 200 tiny 2-4 px UI cells jitter to random screen positions every frame,
-- each one randomly white or black at low alpha. Cheap, atmospheric, makes
-- the image read as "captured by a sensor" rather than "rendered in real time".
-- =========================================================================

local FilmGrain = {}
local grainGui
local grainCells = {}
local NUM_GRAIN_CELLS = 220
local lastGrainTick = 0

function FilmGrain.build()
	if grainGui and grainGui.Parent then return end
	grainGui = Instance.new("ScreenGui")
	grainGui.Name = "Cinematic_FilmGrain"
	grainGui.ResetOnSpawn = false
	grainGui.IgnoreGuiInset = true
	grainGui.DisplayOrder = 8   -- above vignette/lens-flare, below toast
	grainGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	grainGui.Enabled = false
	grainGui.Parent = PlayerGui

	grainCells = {}
	for _ = 1, NUM_GRAIN_CELLS do
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Size = UDim2.fromOffset(math.random(2, 4), math.random(2, 4))
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Parent = grainGui
		table.insert(grainCells, f)
	end
end

function FilmGrain.update()
	if not State.Enabled or not State.FilmGrain or not grainGui then return end
	if not grainGui.Enabled then return end
	local now = os.clock()
	if now - lastGrainTick < 0.033 then return end  -- 30 Hz cap
	lastGrainTick = now

	local cam = workspace.CurrentCamera
	if not cam then return end
	local vp = cam.ViewportSize
	local amt = math.clamp(State.FilmGrainAmount, 0, 1)
	local maxAlpha = amt * 0.18

	for _, cell in ipairs(grainCells) do
		cell.Position = UDim2.fromOffset(math.random() * vp.X, math.random() * vp.Y)
		cell.BackgroundColor3 = (math.random() > 0.5) and Color3.new(1, 1, 1) or Color3.new(0, 0, 0)
		cell.BackgroundTransparency = 1 - (math.random() * maxAlpha)
	end
end

function FilmGrain.setEnabled(enabled)
	if grainGui then grainGui.Enabled = enabled end
end

function FilmGrain.cleanup()
	if grainGui then grainGui:Destroy() grainGui = nil end
	table.clear(grainCells)
end

-- =========================================================================
-- MODULE: CHROMATIC ABERRATION — edge color fringing
-- Lens-style RGB split: red and blue ColorCorrectionEffects with opposing
-- TintColors are stacked at low Brightness, producing the subtle red/cyan
-- shoulder you see on cinema cameras with vintage glass.
-- =========================================================================

local ChromaticAberration = {}

function ChromaticAberration.apply(time)
	if not FX.CCChromaR then return end
	time = time or 0.3
	local ti = TweenInfo.new(time, Enum.EasingStyle.Quad)
	local on = State.ChromaticAberration
	if on then
		local a = math.clamp(State.ChromaticAmount, 0, 1)
		FX.CCChromaR.Enabled = true
		FX.CCChromaB.Enabled = true
		TweenService:Create(FX.CCChromaR, ti, {
			TintColor  = Color3.new(1, 1 - 0.04 * a, 1 - 0.04 * a),
			Brightness = 0.01 * a,
			Contrast = 0, Saturation = 0,
		}):Play()
		TweenService:Create(FX.CCChromaB, ti, {
			TintColor  = Color3.new(1 - 0.04 * a, 1 - 0.04 * a, 1),
			Brightness = -0.01 * a,
			Contrast = 0, Saturation = 0,
		}):Play()
	else
		FX.CCChromaR.Enabled = false
		FX.CCChromaB.Enabled = false
	end
end

-- =========================================================================
-- MODULE: SUN DISC — visible sun in the sky with corona + atmospheric reddening
-- Tracks Lighting:GetSunDirection() through camera projection so the disc
-- sits exactly where the lens flare anchors. Color reddens toward the horizon
-- (Rayleigh scattering approximation) and fades out underground.
-- =========================================================================

local SunDisc = {}
local sunDiscGui
local sunCoronaFrame, sunRingFrame, sunDiscFrame, sunStreakFrame

function SunDisc.build()
	if sunDiscGui and sunDiscGui.Parent then return end
	sunDiscGui = Instance.new("ScreenGui")
	sunDiscGui.Name = "Cinematic_SunDisc"
	sunDiscGui.ResetOnSpawn = false
	sunDiscGui.IgnoreGuiInset = true
	sunDiscGui.DisplayOrder = -9     -- behind lens flare (which is -5)
	sunDiscGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sunDiscGui.Enabled = false
	sunDiscGui.Parent = PlayerGui

	local function ringFrame(name, size, baseColor, baseTrans, fadeEdges)
		local f = Instance.new("Frame", sunDiscGui)
		f.Name = name
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Size = UDim2.fromOffset(size, size)
		f.BackgroundColor3 = baseColor
		f.BackgroundTransparency = baseTrans
		f.BorderSizePixel = 0
		Instance.new("UICorner", f).CornerRadius = UDim.new(1, 0)
		if fadeEdges then
			local g = Instance.new("UIGradient", f)
			g.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0,    0),
				NumberSequenceKeypoint.new(0.45, 0.25),
				NumberSequenceKeypoint.new(0.85, 0.85),
				NumberSequenceKeypoint.new(1,    1),
			})
		end
		return f
	end

	sunCoronaFrame = ringFrame("Corona", 360, Color3.fromRGB(255, 220, 170), 0.55, true)
	sunRingFrame   = ringFrame("Ring",   170, Color3.fromRGB(255, 240, 200), 0.18, true)
	sunDiscFrame   = ringFrame("Disc",    66, Color3.fromRGB(255, 250, 235), 0.0,  false)

	-- Anamorphic horizontal streak (very wide pill, slight tint)
	sunStreakFrame = Instance.new("Frame", sunDiscGui)
	sunStreakFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	sunStreakFrame.Size = UDim2.fromOffset(640, 14)
	sunStreakFrame.BackgroundColor3 = Color3.fromRGB(255, 235, 195)
	sunStreakFrame.BackgroundTransparency = 0.55
	sunStreakFrame.BorderSizePixel = 0
	Instance.new("UICorner", sunStreakFrame).CornerRadius = UDim.new(1, 0)
	local sg = Instance.new("UIGradient", sunStreakFrame)
	sg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0,    1),
		NumberSequenceKeypoint.new(0.15, 0.7),
		NumberSequenceKeypoint.new(0.5,  0.25),
		NumberSequenceKeypoint.new(0.85, 0.7),
		NumberSequenceKeypoint.new(1,    1),
	})
end

local function hideSunDisc()
	if sunDiscFrame   then sunDiscFrame.Visible   = false end
	if sunCoronaFrame then sunCoronaFrame.Visible = false end
	if sunRingFrame   then sunRingFrame.Visible   = false end
	if sunStreakFrame then sunStreakFrame.Visible = false end
end

function SunDisc.update()
	if not State.Enabled or not State.SunDisc or not sunDiscGui or not sunDiscGui.Enabled then
		hideSunDisc()
		return
	end
	local cam = workspace.CurrentCamera
	if not cam then hideSunDisc() return end
	local sunDir = Lighting:GetSunDirection()
	if sunDir.Y < -0.05 then hideSunDisc() return end

	local sunWorldPos = cam.CFrame.Position + sunDir * 5000
	local screenPos = cam:WorldToViewportPoint(sunWorldPos)
	if screenPos.Z < 0 then hideSunDisc() return end

	-- Rayleigh approximation: dot toward horizon → redder. elev=0 at horizon, 1 at zenith.
	local elev = math.clamp(sunDir.Y, 0, 1)
	local sunsetMix = (1 - elev) ^ 2
	local discCol = Color3.new(
		1,
		math.clamp(0.96 - sunsetMix * 0.40, 0.30, 1),
		math.clamp(0.85 - sunsetMix * 0.65, 0.10, 1)
	)
	local coronaCol = Color3.new(
		1,
		math.clamp(0.85 - sunsetMix * 0.45, 0.25, 1),
		math.clamp(0.65 - sunsetMix * 0.55, 0.05, 1)
	)

	local lookDot   = cam.CFrame.LookVector:Dot(sunDir)
	local visBias   = math.clamp((lookDot + 0.25) / 1.25, 0, 1)
	local dayBlend  = PostFX.getDayBlend()
	local fade      = visBias * dayBlend

	local pos = UDim2.fromOffset(screenPos.X, screenPos.Y)
	sunDiscFrame.Position   = pos
	sunRingFrame.Position   = pos
	sunCoronaFrame.Position = pos
	sunStreakFrame.Position = pos

	sunDiscFrame.BackgroundColor3   = discCol
	sunRingFrame.BackgroundColor3   = coronaCol
	sunCoronaFrame.BackgroundColor3 = coronaCol
	sunStreakFrame.BackgroundColor3 = coronaCol

	sunDiscFrame.BackgroundTransparency   = 1 - fade
	sunRingFrame.BackgroundTransparency   = 0.18 + (1 - fade) * 0.5
	sunCoronaFrame.BackgroundTransparency = 0.4  + (1 - fade) * 0.5
	sunStreakFrame.BackgroundTransparency = 0.55 + (1 - fade) * 0.4

	sunDiscFrame.Visible   = true
	sunRingFrame.Visible   = true
	sunCoronaFrame.Visible = true
	sunStreakFrame.Visible = true
end

function SunDisc.setEnabled(enabled)
	if sunDiscGui then sunDiscGui.Enabled = enabled end
end

function SunDisc.cleanup()
	if sunDiscGui then sunDiscGui:Destroy() sunDiscGui = nil end
	sunDiscFrame, sunRingFrame, sunCoronaFrame, sunStreakFrame = nil, nil, nil, nil
end

-- =========================================================================
-- MODULE: VOLUMETRIC FOG — multi-layered animated mist that hugs the camera
-- A swarm of camera-facing Beams orbiting the player at varied heights and
-- radii. Each beam tints to the current mood's bottomTint so it picks up
-- sunset orange / midday white / night blue automatically, and drifts on a
-- procedural wind so the fog feels alive instead of static volumetrics.
-- =========================================================================

local VolFog = {}
local TAG_VOL_FOG     = "Cinematic_VolFog"
local volFogContainer
local volFogPieces    = {}
local NUM_VOL_LAYERS  = 56
local VOL_ORBIT_R     = 90

function VolFog.build()
	if volFogContainer and volFogContainer.Parent then return end
	volFogContainer = Instance.new("Folder")
	volFogContainer.Name = "Cinematic_VolFog"
	volFogContainer.Parent = Workspace

	volFogPieces = {}
	for i = 1, NUM_VOL_LAYERS do
		local part = Instance.new("Part")
		part.Name        = "VolFog_" .. i
		part.Anchored    = true
		part.CanCollide  = false
		part.CanTouch    = false
		part.CanQuery    = false
		part.Massless    = true
		part.Locked      = true
		part.CastShadow  = false
		part.Material    = Enum.Material.SmoothPlastic
		part.Transparency = 1
		part.Size        = Vector3.new(0.1, 0.1, 0.1)
		part.Parent      = volFogContainer

		local a0 = Instance.new("Attachment", part)
		a0.Position = Vector3.new(-22, 0, 0)
		local a1 = Instance.new("Attachment", part)
		a1.Position = Vector3.new(22, 0, 0)

		local beam = Instance.new("Beam", part)
		beam.Attachment0    = a0
		beam.Attachment1    = a1
		beam.FaceCamera     = true
		beam.LightInfluence = 0
		beam.LightEmission  = 0.55
		beam.Width0         = 28
		beam.Width1         = 40
		beam.Segments       = 4
		beam.Color          = ColorSequence.new(Color3.fromRGB(225, 225, 220))
		beam.Transparency   = NumberSequence.new(1)
		beam.Enabled        = false
		CollectionService:AddTag(beam, TAG_VOL_FOG)
		volFogPieces[i] = { part = part, beam = beam,
			-- Deterministic per-piece offsets so motion is smooth (no twinkle)
			angle = (i / NUM_VOL_LAYERS) * math.pi * 2 + math.random() * 0.4,
			r     = VOL_ORBIT_R * (0.45 + ((i * 73) % 100) / 100 * 0.65),
			h     = ((i * 41) % 36) - 8,
			phase = ((i * 17) % 100) / 100,
		}
	end
end

function VolFog.update(dt)
	if not State.Enabled or not State.VolumetricFog or not volFogContainer then return end
	local cam = workspace.CurrentCamera
	if not cam then return end
	local camPos    = cam.CFrame.Position
	local mood      = PostFX.getMood()
	local weather   = PostFX.getWeather()
	local dayBlend  = PostFX.getDayBlend()
	local fogColor  = mood.bottomTint or Color3.fromRGB(220, 220, 220)

	-- Wind drift accumulator (slow, low-frequency)
	local windT = os.clock() * 1.1

	local densityBase = math.clamp(State.VolumetricDensity, 0, 2)
	local densityMul  = densityBase * (mood.density or 1) * (weather.density or 1)

	for _, piece in ipairs(volFogPieces) do
		local a = piece.angle + windT * 0.03 + piece.phase
		local target = camPos + Vector3.new(
			math.cos(a) * piece.r,
			piece.h + math.sin(windT * 0.7 + piece.phase * 6) * 1.4,
			math.sin(a) * piece.r
		)
		piece.part.CFrame = CFrame.new(target)
		piece.beam.Enabled = true
		piece.beam.Color = ColorSequence.new(fogColor)
		local layerAlpha = 0.06 + 0.10 * piece.phase  -- per-piece variety
		piece.beam.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0,    1),
			NumberSequenceKeypoint.new(0.5,  math.clamp(1 - layerAlpha * densityMul, 0.78, 1)),
			NumberSequenceKeypoint.new(1,    1),
		})
	end
end

function VolFog.setEnabled(enabled)
	if not volFogContainer then return end
	for _, beam in ipairs(CollectionService:GetTagged(TAG_VOL_FOG)) do
		beam.Enabled = enabled
	end
end

function VolFog.cleanup()
	if volFogContainer then
		volFogContainer:Destroy()
		volFogContainer = nil
		volFogPieces = {}
	end
end

-- =========================================================================
-- MODULE: CAUSTICS — animated water-pattern overlay on wet/reflective floors
-- Procedural sinusoidal pattern drawn via 4 thin tiled SurfaceGui shapes
-- per overlay floor. Pattern phase advances in time; brightness pulses to
-- match the underlying floor's wetness setting.
-- Only applied to overlays the wet-floor system already created.
-- =========================================================================

local Caustics = {}
local TAG_CAUSTIC = "Cinematic_Caustic"
local MAX_CAUSTIC_OVERLAYS = 90
local causticAttachments = {}

function Caustics.attach(overlay)
	if not State.Caustics then return end
	if not overlay or not overlay.Parent then return end
	if overlay:FindFirstChild("Cinematic_CausticSurface") then return end
	if #causticAttachments >= MAX_CAUSTIC_OVERLAYS then return end

	local sg = Instance.new("SurfaceGui")
	sg.Name = "Cinematic_CausticSurface"
	sg.Face = Enum.NormalId.Top
	sg.Adornee = overlay
	sg.AlwaysOnTop = false
	sg.LightInfluence = 0
	sg.PixelsPerStud = 16
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.Parent = overlay
	CollectionService:AddTag(sg, TAG_CAUSTIC)

	-- Generate a small grid of "blob" frames whose alpha/position is animated.
	-- Real caustics need a refraction LUT — these are stylised but read as
	-- caustics under motion because they brighten/dim in a flowing pattern.
	local blobs = {}
	for i = 1, 6 do
		local blob = Instance.new("Frame", sg)
		blob.AnchorPoint = Vector2.new(0.5, 0.5)
		blob.Size = UDim2.fromScale(0.22, 0.22)
		blob.BackgroundColor3 = Color3.fromRGB(255, 245, 215)
		blob.BackgroundTransparency = 1
		blob.BorderSizePixel = 0
		Instance.new("UICorner", blob).CornerRadius = UDim.new(1, 0)
		local g = Instance.new("UIGradient", blob)
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0,    0.5),
			NumberSequenceKeypoint.new(0.5,  0.85),
			NumberSequenceKeypoint.new(1,    1),
		})
		blobs[i] = blob
	end
	table.insert(causticAttachments, { gui = sg, overlay = overlay, blobs = blobs,
		seed = math.random() * 100 })
end

function Caustics.update()
	if not State.Enabled or not State.Caustics then return end
	local t = os.clock()
	for _, entry in ipairs(causticAttachments) do
		if entry.overlay and entry.overlay.Parent then
			local wet  = State.Wetness * State.Reflection
			local base = 0.55 + math.sin(t * 1.6 + entry.seed) * 0.18
			for i, blob in ipairs(entry.blobs) do
				local phase = t * 0.7 + entry.seed + i
				blob.Position = UDim2.fromScale(
					0.5 + math.cos(phase) * 0.35,
					0.5 + math.sin(phase * 1.3) * 0.35
				)
				local alpha = math.clamp(0.5 + math.sin(phase * 1.7) * 0.5, 0, 1) * wet
				blob.BackgroundTransparency = 1 - alpha * 0.18 * base
			end
		end
	end
end

function Caustics.setEnabled(enabled)
	if enabled then
		-- Attach to every existing wet overlay
		for _, ov in ipairs(CollectionService:GetTagged(TAG_OVERLAY)) do
			Caustics.attach(ov)
		end
	else
		for _, sg in ipairs(CollectionService:GetTagged(TAG_CAUSTIC)) do
			sg:Destroy()
		end
		causticAttachments = {}
	end
end

function Caustics.cleanup()
	for _, sg in ipairs(CollectionService:GetTagged(TAG_CAUSTIC)) do
		sg:Destroy()
	end
	causticAttachments = {}
end

-- =========================================================================
-- MODULE: SSAO — screen-space ambient occlusion (approximate)
-- For each wet overlay, cast a handful of short upward-hemisphere rays. The
-- proportion that hit something nearby is the AO factor; we then darken the
-- overlay's color slightly. Real SSAO operates per-pixel in a shader, which
-- isn't accessible — overlay-level AO is the next best thing.
-- =========================================================================

local SSAO = {}
local lastSSAOTick = 0

-- Stored on each overlay so RayTrace can multiply it in. RayTrace writes
-- overlay.Color every frame; we can't fight that. Instead we annotate the
-- overlay with an AO factor and the ray-trace target blend reads it.
local ATTR_SSAO_FACTOR = "Cinematic_SSAOFactor"

function SSAO.update()
	if not State.Enabled or not State.SSAO then return end
	local now = os.clock()
	if now - lastSSAOTick < 0.14 then return end   -- ~7 Hz
	lastSSAOTick = now

	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	local excl = {}
	if LocalPlayer.Character then table.insert(excl, LocalPlayer.Character) end
	for _, ov in ipairs(CollectionService:GetTagged(TAG_OVERLAY)) do
		table.insert(excl, ov)
	end
	rp.FilterDescendantsInstances = excl

	local intensity = math.clamp(State.SSAOIntensity, 0, 1)
	for _, overlay in ipairs(CollectionService:GetTagged(TAG_OVERLAY)) do
		if overlay and overlay.Parent then
			local origin = overlay.Position + Vector3.new(0, 0.4, 0)
			-- 6 short rays in a tilted hemisphere
			local hits = 0
			local total = 6
			for s = 1, total do
				local theta = (s / total) * math.pi * 2
				local dir = Vector3.new(math.cos(theta) * 0.7, 0.55, math.sin(theta) * 0.7).Unit
				local r = Workspace:Raycast(origin, dir * 8, rp)
				if r then hits = hits + 1 end
			end
			local occ    = hits / total                          -- 0..1
			local darken = 1 - occ * intensity * 0.40            -- 0.60..1
			overlay:SetAttribute(ATTR_SSAO_FACTOR, darken)
			-- Also nudge the live color so darkening is visible even when
			-- RayTrace is off (RayTrace will pick the attribute up next frame
			-- if it IS on, so they stack instead of fight).
			if not State.RayTrace then
				local base = overlay:GetAttribute("Cinematic_BaselineColor") or overlay.Color
				overlay.Color = Color3.new(
					math.clamp(base.R * darken, 0, 1),
					math.clamp(base.G * darken, 0, 1),
					math.clamp(base.B * darken, 0, 1)
				)
			end
		end
	end
end

-- =========================================================================
-- MODULE: ANISOTROPIC METALS — directional reflection bias on metal parts.
-- True anisotropy in PBR stretches the specular highlight along a surface
-- tangent (think brushed aluminium). Roblox metal materials reflect
-- isotropically, but we can fake the LOOK by varying Reflectance per
-- viewing angle, so brushed-metal parts appear brighter when viewed
-- along their long axis and dimmer across.
-- =========================================================================

local AnisotropicMetals = {}
local lastAnisoTick = 0

function AnisotropicMetals.update()
	if not State.Enabled or not State.AnisotropicMetals then return end
	local now = os.clock()
	if now - lastAnisoTick < 0.10 then return end   -- 10 Hz
	lastAnisoTick = now

	local cam = workspace.CurrentCamera
	if not cam then return end
	local camPos = cam.CFrame.Position

	for _, part in ipairs(CollectionService:GetTagged(TAG_PROCESSED)) do
		if part:IsA("BasePart") and part:GetAttribute(ATTR_CLASS) == "metal" then
			-- Dominant axis = whichever extent is largest
			local size = part.Size
			local dom
			if size.X >= size.Y and size.X >= size.Z then dom = part.CFrame.RightVector
			elseif size.Y >= size.Z then                  dom = part.CFrame.UpVector
			else                                          dom = part.CFrame.LookVector end

			local toCam = (camPos - part.Position)
			if toCam.Magnitude > 0.001 then
				local viewDir = toCam.Unit
				local alongAxis = math.abs(viewDir:Dot(dom))    -- 0..1
				-- Recompute baseline reflectance, then add up to +30% along axis
				local albedo = math.max(0.4, albedoScale(part))
				local baseR = math.clamp(Profile.Reflectance.Metal * albedo * State.Reflection * State.Intensity, 0, 0.6)
				local boost = (1 + alongAxis * 0.55)
				part.Reflectance = math.clamp(baseR * boost, 0, 0.85)
			end
		end
	end
end

-- =========================================================================
-- MODULE: API — public toggle/intensity/preset functions
-- =========================================================================

local API = {}

function API.applyAll(time)
	LightingMod.applyProfile(time)
	PostFX.applyIntensity(time)
	Materials.reapplyReflectance()
	Reflections.updateAll()
end

function API.setIntensity(value)
	State.Intensity = math.clamp(value, 0, 2)
	if not State.Enabled then return end
	API.applyAll(0.4)
end

function API.setBloom(value)
	State.Bloom = math.clamp(value, 0, 2)
	if not State.Enabled then return end
	PostFX.applyIntensity(0.4)
end

function API.setReflection(value)
	State.Reflection = math.clamp(value, 0, 2)
	if not State.Enabled then return end
	Materials.reapplyReflectance()
	Reflections.updateAll()
end

function API.setWetness(value)
	State.Wetness = math.clamp(value, 0, 1)
	if not State.Enabled then return end
	if value > 0.05 and QualityProfiles[State.Quality].OverlayEnabled then
		Reflections.repopulate()
		Reflections.updateAll()
	else
		Reflections.cleanup()
	end
end

function API.setColorPreset(name)
	if not ColorPresets[name] then return end
	State.ColorPreset = name
	if not State.Enabled then return end
	LightingMod.applyProfile(0.6)
	PostFX.applyIntensity(0.6)
end

function API.setQuality(name)
	if not QualityProfiles[name] then return end
	local prev = State.Quality
	State.Quality = name

	-- ===== ULTRA & MAX: PHOTOREALISTIC MODE =====
	-- Both tiers auto-engage the entire realism stack so the visual jump
	-- matches the rendering cost. Max goes harder on every tunable knob and
	-- surfaces the GPU warning toast. There's no automatic FPS-based
	-- downgrade — if Max is too heavy, the user drops the tier manually.
	if (name == "Ultra" or name == "Max") and prev ~= name then
		local isMax = (name == "Max")
		pcall(function()
			if isMax then
				showToast("MAX MODE: Nvidia RTX-class GPU recommended. Full realism stack at maximum — expect severe FPS impact. If your hardware can't sustain it, manually drop to Ultra or High.", 10)
			else
				showToast("ULTRA: photorealistic realism stack engaged.", 5)
			end
		end)

		-- Base feature flags — both tiers turn everything on
		State.RayTrace        = true
		State.MultiBounceRT   = true
		State.FresnelOverlays = true
		State.NightBeams      = true
		State.LightEnhance    = true
		State.MotionBlur      = true
		State.EyeAdaptation   = true
		State.Vignette        = true
		State.LensFlare       = true
		State.WeatherMood     = true
		State.AutoFocus       = true
		State.CameraFillLight = true
		State.FoliageEnhance  = true
		State.FireEnhance     = true
		State.SmokeEnhance    = true
		State.SparklesEnhance = true
		State.WaterEnhance    = true
		State.CinematicMode   = true
		State.GForce          = true

		-- Realism stack modules
		State.EnhancedGI         = true
		State.SSAO               = true
		State.AnisotropicMetals  = true
		State.VolumetricFog      = true
		State.Caustics           = true
		State.SunDisc            = true
		State.FilmGrain          = true
		-- Chromatic aberration is heavier and reads "stylised"; Max gets it
		-- by default, Ultra leaves it off (user can toggle on if wanted).
		State.ChromaticAberration = isMax

		-- Photographic-neutral colour grade. Real footage is rarely as saturated
		-- as default Roblox; pulling vibrance down and lifting gain reads as
		-- "captured by a sensor" rather than "engine output".
		State.WhiteBalance       = 6500
		State.WBTint             = 0
		State.HueShift           = 0
		State.Vibrance           = isMax and -14 or -8
		State.Lift               = isMax and 0.03 or 0.01
		State.Gamma              = 1.0
		State.Gain               = isMax and 1.12 or 1.06
		State.FilmGrainAmount    = isMax and 0.20 or 0.13
		State.ChromaticAmount    = isMax and 0.40 or 0.0
		State.VolumetricDensity  = isMax and 1.30 or 1.05
		State.SSAOIntensity      = isMax and 0.70 or 0.55

		-- Auto-promote grade and tonemap to photoreal/cinematic. Leave the
		-- user's pick alone if it's a deliberate stylised look.
		if State.ColorPreset == "Neutral"
			or State.ColorPreset == "Enhanced"
			or State.ColorPreset == "Cinematic"
			or State.ColorPreset == "Realistic" then
			State.ColorPreset = "Photorealistic"
		end
		if State.Tonemap == "Linear" or State.Tonemap == "Filmic" or State.Tonemap == "Reinhard" then
			State.Tonemap = "ACES"
		end
	end

	if not State.Enabled then return end
	LightingMod.applyProfile(0.6)
	PostFX.applyIntensity(0.6)
	-- Push the auto-enabled realism modules to the engine
	AdvancedColor.apply(0.5)
	ChromaticAberration.apply(0.4)
	FilmGrain.setEnabled(State.FilmGrain and State.Enabled)
	SunDisc.setEnabled(State.SunDisc and State.Enabled)
	VolFog.setEnabled(State.VolumetricFog and State.Enabled)
	Caustics.setEnabled(State.Caustics and State.Enabled)

	if QualityProfiles[name].OverlayEnabled then
		Reflections.repopulate()
	else
		Reflections.cleanup()
	end
	-- Re-scan world so newly-allowed overlay/beam slots get filled when
	-- jumping from e.g. High (cap 800) up to Max (cap 4500).
	if QualityProfiles[name].OverlayMax
		and (QualityProfiles[prev] == nil
			or (QualityProfiles[prev].OverlayMax or 0) < QualityProfiles[name].OverlayMax) then
		Detection.scan()
		if State.NightBeams then NightBeams.scan() end
	end
end

function API.setTimeMode(mode)
	if mode ~= "Auto" and mode ~= "Day" and mode ~= "Night" then return end
	State.TimeMode = mode
	if not State.Enabled then return end
	PostFX.applyIntensity(0.6)
end

function API.setVignette(enabled)
	State.Vignette = enabled
	VignetteMod.setVisible(State.Enabled and enabled)
end

function API.setLensFlare(enabled)
	State.LensFlare = enabled
end

function API.setAutoFocus(enabled)
	State.AutoFocus = enabled
end

function API.setWeatherMood(enabled)
	State.WeatherMood = enabled
	if not State.Enabled then return end
	PostFX.applyIntensity(0.6)
end

function API.setFresnelOverlays(enabled)
	State.FresnelOverlays = enabled
	-- If disabled, snap overlays back to their static reflectance
	if not enabled then Reflections.updateAll() end
end

function API.setMotionBlur(enabled)
	State.MotionBlur = enabled
	if not enabled and FX.Blur then FX.Blur.Size = 0 end
end

function API.setEyeAdaptation(enabled)
	State.EyeAdaptation = enabled
	if not enabled and State.Enabled then
		-- Reset to base exposure (incl. quality-tier ExposureBoost so Max
		-- doesn't lose its brightness when EyeAdaptation is toggled off)
		local qBoost = (QualityProfiles[State.Quality] and QualityProfiles[State.Quality].ExposureBoost) or 0
		Lighting.ExposureCompensation =
			Profile.Lighting.ExposureCompensation * State.Intensity + PostFX.getMood().expBias + qBoost
	end
end

function API.setLightEnhance(enabled)
	State.LightEnhance = enabled
	if enabled then
		Lights.scan()
	else
		Lights.cleanup()
	end
end

function API.setNightBeams(enabled)
	State.NightBeams = enabled
	if enabled then
		NightBeams.scan()
	else
		NightBeams.cleanup()
	end
end

function API.setRayTrace(enabled)
	State.RayTrace = enabled
	if not enabled then RayTrace.reset() end
end

function API.setMultiBounceRT(enabled)
	State.MultiBounceRT = enabled
end

function API.setCameraFillLight(enabled)
	State.CameraFillLight = enabled
	if not enabled and fillLight then
		fillLight.Brightness = 0
	end
end

function API.setGForce(enabled)
	State.GForce = enabled
end

function API.setPlayerHighlight(enabled)
	State.PlayerHighlight = enabled
	if not enabled then
		-- Snap all highlights invisible (don't destroy — re-enabling is instant)
		for _, hl in ipairs(CollectionService:GetTagged(TAG_HIGHLIGHT)) do
			hl.FillTransparency = 1
			hl.OutlineTransparency = 1
		end
	end
end

function API.setFoliageEnhance(enabled)
	State.FoliageEnhance = enabled
	if enabled then
		Foliage.scan()
	else
		Foliage.cleanup()
	end
end

function API.setFireEnhance(enabled)
	State.FireEnhance = enabled
	if enabled then
		FireMod.scan()
	else
		FireMod.cleanup()
	end
end

function API.setSmokeEnhance(enabled)
	State.SmokeEnhance = enabled
	if enabled then SmokeMod.scan() else SmokeMod.cleanup() end
end

function API.setSparklesEnhance(enabled)
	State.SparklesEnhance = enabled
	if enabled then SparklesMod.scan() else SparklesMod.cleanup() end
end

function API.setWaterEnhance(enabled)
	State.WaterEnhance = enabled
	if enabled then WaterMod.apply() else WaterMod.restore() end
end

function API.setWeather(name)
	if not WEATHERS[name] then return end
	State.Weather = name
	if not State.Enabled then return end
	PostFX.applyIntensity(0.8)
end

function API.setPrecipitation(enabled)
	State.Precipitation = enabled
end

function API.setLightning(enabled)
	State.Lightning = enabled
end

function API.setAutoCycle(enabled)
	State.AutoCycle = enabled
end

function API.setCycleSpeed(secondsPerInGameDay)
	if type(secondsPerInGameDay) ~= "number" or secondsPerInGameDay < 30 then return end
	State.CycleSpeed = 24 / secondsPerInGameDay
end

function API.setUnderwater(enabled)
	State.Underwater = enabled
end

function API.setFreeCam(enabled)
	State.FreeCam = enabled
	if enabled then FreeCam.enable() else FreeCam.disable() end
end

function API.setTonemap(name)
	if not TONEMAPS[name] then return end
	State.Tonemap = name
	if not State.Enabled then return end
	PostFX.applyIntensity(0.6)
end

-- =========================================================================
-- ADVANCED REALISM SETTERS (RTX stack)
-- Every setter takes a value, clamps, stores in State, and pokes the module
-- to re-render. They all guard on State.Enabled so toggling the master
-- shader off freezes the realism stack in place.
-- =========================================================================

-- AdvancedColor sliders
function API.setWhiteBalance(K)
	State.WhiteBalance = math.clamp(K or 6500, 1500, 15000)
	AdvancedColor.apply(0.3)
end

function API.setWBTint(value)
	State.WBTint = math.clamp(value or 0, -100, 100)
	AdvancedColor.apply(0.3)
end

function API.setVibrance(value)
	State.Vibrance = math.clamp(value or 0, -100, 100)
	AdvancedColor.apply(0.3)
end

function API.setHueShift(value)
	-- Wrap to [-180, 180]
	local v = value or 0
	if v > 180 then v = v - 360 end
	if v < -180 then v = v + 360 end
	State.HueShift = v
	AdvancedColor.apply(0.3)
end

function API.setLift(value)
	State.Lift = math.clamp(value or 0, -1, 1)
	AdvancedColor.apply(0.3)
end

function API.setGamma(value)
	State.Gamma = math.clamp(value or 1, 0.2, 5)
	AdvancedColor.apply(0.3)
end

function API.setGain(value)
	State.Gain = math.clamp(value or 1, 0.2, 5)
	AdvancedColor.apply(0.3)
end

-- FilmGrain
function API.setFilmGrain(enabled)
	State.FilmGrain = enabled and true or false
	FilmGrain.setEnabled(State.FilmGrain and State.Enabled)
end

function API.setFilmGrainAmount(value)
	State.FilmGrainAmount = math.clamp(value or 0.18, 0, 1)
end

-- ChromaticAberration
function API.setChromaticAberration(enabled)
	State.ChromaticAberration = enabled and true or false
	ChromaticAberration.apply(0.25)
end

function API.setChromaticAmount(value)
	State.ChromaticAmount = math.clamp(value or 0.5, 0, 1)
	if State.ChromaticAberration then ChromaticAberration.apply(0.25) end
end

-- SunDisc
function API.setSunDisc(enabled)
	State.SunDisc = enabled and true or false
	SunDisc.setEnabled(State.SunDisc and State.Enabled)
end

-- Volumetric Fog
function API.setVolumetricFog(enabled)
	State.VolumetricFog = enabled and true or false
	VolFog.setEnabled(State.VolumetricFog and State.Enabled)
end

function API.setVolumetricDensity(value)
	State.VolumetricDensity = math.clamp(value or 1, 0, 2)
end

-- Caustics
function API.setCaustics(enabled)
	State.Caustics = enabled and true or false
	if State.Caustics and State.Enabled then
		Caustics.setEnabled(true)
	else
		Caustics.setEnabled(false)
	end
end

-- EnhancedGI
function API.setEnhancedGI(enabled)
	State.EnhancedGI = enabled and true or false
end

-- SSAO
function API.setSSAO(enabled)
	State.SSAO = enabled and true or false
end

function API.setSSAOIntensity(value)
	State.SSAOIntensity = math.clamp(value or 0.6, 0, 1)
end

-- Anisotropic metals
function API.setAnisotropicMetals(enabled)
	State.AnisotropicMetals = enabled and true or false
	if not enabled and State.Enabled then
		-- Snap metals back to isotropic baseline
		Materials.reapplyReflectance()
	end
end

-- =========================================================================
-- RTX MEGA-PRESET
-- One-tap activation of the full realism stack: every new module on,
-- Quality jumps to Max (with its own toast/warning), preset goes to
-- Photorealistic, tonemap to ACES, advanced color sliders set to
-- "photographic neutral" values. Showcase mode — designed to make the
-- scene look like a different engine.
-- =========================================================================
function API.activateRTX()
	-- One-shot showcase: jump to Max, which now auto-enables the entire
	-- realism stack with photographic-neutral grade. activateRTX exists as
	-- a friendlier entry point (single button in the UI / single function
	-- call from external scripts) — all the heavy lifting lives in setQuality.

	State.Enabled = true

	-- If we're already at Max, briefly bounce to Ultra so setQuality's
	-- "tier changed → re-engage realism stack" branch fires again. Otherwise
	-- calling activateRTX while already at Max would be a no-op.
	if State.Quality == "Max" then
		State.Quality = "Ultra"
	end
	API.setQuality("Max")

	-- Final refresh pass to make sure every module picks up the new state
	-- (some run on timers and might be in the middle of an idle cycle).
	if State.Enabled then
		LightingMod.applyProfile(0.8)
		PostFX.applyIntensity(0.8)
		AdvancedColor.apply(0.6)
		ChromaticAberration.apply(0.4)
		Materials.reapplyReflectance()
	end
end

-- ===== PRESET EXPORT / IMPORT =====
-- Save the current shader configuration as a JSON-ish string the user can
-- paste back later (or share with friends). Captures sliders + toggles +
-- preset names, NOT runtime state like queue contents.
local HttpService = game:GetService("HttpService")

function API.exportPreset()
	local snap = {
		v = 1,
		Intensity   = State.Intensity,
		Wetness     = State.Wetness,
		Bloom       = State.Bloom,
		Reflection  = State.Reflection,
		Quality     = State.Quality,
		ColorPreset = State.ColorPreset,
		Weather     = State.Weather,
		TimeMode    = State.TimeMode,
		Vignette    = State.Vignette,
		LensFlare   = State.LensFlare,
		AutoFocus   = State.AutoFocus,
		WeatherMood = State.WeatherMood,
		FresnelOverlays = State.FresnelOverlays,
		MotionBlur  = State.MotionBlur,
		EyeAdaptation = State.EyeAdaptation,
		LightEnhance = State.LightEnhance,
		SpeedFOV    = State.SpeedFOV,
		NightBeams  = State.NightBeams,
		RayTrace    = State.RayTrace,
		MultiBounceRT = State.MultiBounceRT,
		CameraFillLight = State.CameraFillLight,
		GForce      = State.GForce,
		PlayerHighlight = State.PlayerHighlight,
		FoliageEnhance = State.FoliageEnhance,
		FireEnhance = State.FireEnhance,
		SmokeEnhance = State.SmokeEnhance,
		SparklesEnhance = State.SparklesEnhance,
		WaterEnhance = State.WaterEnhance,
		Precipitation = State.Precipitation,
		Lightning = State.Lightning,
		AutoCycle = State.AutoCycle,
		CycleSpeed = State.CycleSpeed,
		Underwater = State.Underwater,
		Tonemap = State.Tonemap,
		CinematicMode = State.CinematicMode,
	}
	return HttpService:JSONEncode(snap)
end

function API.importPreset(jsonStr)
	local ok, data = pcall(function() return HttpService:JSONDecode(jsonStr) end)
	if not ok or type(data) ~= "table" then return false, "Invalid JSON" end

	-- Apply via existing setters so all the side-effects (rescans, tweens) happen
	if data.Intensity   then API.setIntensity(data.Intensity) end
	if data.Wetness     then API.setWetness(data.Wetness) end
	if data.Bloom       then API.setBloom(data.Bloom) end
	if data.Reflection  then API.setReflection(data.Reflection) end
	if data.Quality     then API.setQuality(data.Quality) end
	if data.ColorPreset then API.setColorPreset(data.ColorPreset) end
	if data.Weather     then API.setWeather(data.Weather) end
	if data.TimeMode    then API.setTimeMode(data.TimeMode) end
	if data.Vignette ~= nil then API.setVignette(data.Vignette) end
	if data.LensFlare ~= nil then API.setLensFlare(data.LensFlare) end
	if data.AutoFocus ~= nil then API.setAutoFocus(data.AutoFocus) end
	if data.WeatherMood ~= nil then API.setWeatherMood(data.WeatherMood) end
	if data.FresnelOverlays ~= nil then API.setFresnelOverlays(data.FresnelOverlays) end
	if data.MotionBlur ~= nil then API.setMotionBlur(data.MotionBlur) end
	if data.EyeAdaptation ~= nil then API.setEyeAdaptation(data.EyeAdaptation) end
	if data.LightEnhance ~= nil then API.setLightEnhance(data.LightEnhance) end
	if data.SpeedFOV ~= nil then API.setSpeedFOV(data.SpeedFOV) end
	if data.NightBeams ~= nil then API.setNightBeams(data.NightBeams) end
	if data.RayTrace ~= nil then API.setRayTrace(data.RayTrace) end
	if data.MultiBounceRT ~= nil then API.setMultiBounceRT(data.MultiBounceRT) end
	if data.CameraFillLight ~= nil then API.setCameraFillLight(data.CameraFillLight) end
	if data.GForce ~= nil then API.setGForce(data.GForce) end
	if data.PlayerHighlight ~= nil then API.setPlayerHighlight(data.PlayerHighlight) end
	if data.FoliageEnhance ~= nil then API.setFoliageEnhance(data.FoliageEnhance) end
	if data.FireEnhance ~= nil then API.setFireEnhance(data.FireEnhance) end
	if data.SmokeEnhance ~= nil then API.setSmokeEnhance(data.SmokeEnhance) end
	if data.SparklesEnhance ~= nil then API.setSparklesEnhance(data.SparklesEnhance) end
	if data.WaterEnhance ~= nil then API.setWaterEnhance(data.WaterEnhance) end
	if data.Precipitation ~= nil then API.setPrecipitation(data.Precipitation) end
	if data.Lightning ~= nil then API.setLightning(data.Lightning) end
	if data.AutoCycle ~= nil then API.setAutoCycle(data.AutoCycle) end
	if data.CycleSpeed then State.CycleSpeed = data.CycleSpeed end
	if data.Underwater ~= nil then API.setUnderwater(data.Underwater) end
	if data.Tonemap then API.setTonemap(data.Tonemap) end
	if data.CinematicMode ~= nil then API.setCinematicMode(data.CinematicMode) end
	return true
end

function API.setSpeedFOV(enabled)
	State.SpeedFOV = enabled
end

function API.setPerfHUD(enabled)
	State.PerfHUD = enabled
	PerfHUD.setVisible(enabled)
end

function API.setCinematicMode(enabled)
	State.CinematicMode = enabled
	CameraFX.applyCinematicFOV(enabled)
	if not State.Enabled then return end
	PostFX.applyIntensity(0.4)
end

function API.setEnabled(value)
	if value == State.Enabled and State.Initialized then return end
	State.Enabled = value

	if value then
		LightingMod.applyProfile()
		PostFX.applyIntensity()
		PostFX.setEnabled(true)
		VignetteMod.setVisible(State.Vignette)
		Detection.scan()
	else
		PostFX.setEnabled(false)
		VignetteMod.setVisible(false)
		LightingMod.restore()
		SkyMod.restore()
		WaterMod.restore()
		Lights.cleanup()
		NightBeams.cleanup()
		Foliage.cleanup()
		FireMod.cleanup()
		SmokeMod.cleanup()
		SparklesMod.cleanup()
		Precipitation.cleanup()
		FreeCam.disable()
		CameraFill.cleanup()
		PlayerHighlight.cleanup()
		task.spawn(function()
			Reflections.cleanup()
			local tagged = CollectionService:GetTagged(TAG_PROCESSED)
			for i, part in ipairs(tagged) do
				if part:IsA("BasePart") and part.Parent then
					Snap.restorePart(part)
				end
				if i % Profile.Performance.ScanBatch == 0 then task.wait() end
			end
			Detection.flush()
		end)
	end
end

-- =========================================================================
-- MODULE: UI — Rayfield with self-built fallback
-- =========================================================================

local UI = {}

function UI.tryRayfield()
	local Rayfield
	local ok = pcall(function()
		Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
	end)
	if not ok or not Rayfield then return false end

	local Window
	ok = pcall(function()
		Window = Rayfield:CreateWindow({
			Name = "Ultra Cinematic Shader",
			LoadingTitle = "Ultra Cinematic Shader",
			LoadingSubtitle = "Realism stack",
			ConfigurationSaving = { Enabled = false },
			KeySystem = false,
			Theme = "Default",
		})
	end)
	if not ok or not Window then return false end

	pcall(function()
		local Visuals = Window:CreateTab("Visuals", 4483362458)

		Visuals:CreateToggle({
			Name = "Enable Shader",
			CurrentValue = State.Enabled,
			Flag = "ucs_enabled",
			Callback = function(v) API.setEnabled(v) end,
		})

		Visuals:CreateSlider({
			Name = "Master Intensity",
			Range = { 0, 2 },
			Increment = 0.05,
			Suffix = "x",
			CurrentValue = State.Intensity,
			Flag = "ucs_intensity",
			Callback = function(v) API.setIntensity(v) end,
		})

		Visuals:CreateDropdown({
			Name = "Quality",
			Options = { "Low", "Medium", "High", "Ultra", "Max" },
			CurrentOption = State.Quality,
			Flag = "ucs_quality",
			Callback = function(v)
				local picked = type(v) == "table" and v[1] or v
				API.setQuality(picked)
			end,
		})

		Visuals:CreateDropdown({
			Name = "Color Preset",
			Options = { "Enhanced", "Cinematic", "Realistic", "Photorealistic", "GTA Day", "GTA Night", "Sunset", "Vintage", "Neutral" },
			CurrentOption = State.ColorPreset,
			Flag = "ucs_preset",
			Callback = function(v)
				local picked = type(v) == "table" and v[1] or v
				API.setColorPreset(picked)
			end,
		})

		Visuals:CreateDropdown({
			Name = "Tonemap Curve",
			Options = { "Linear", "Filmic", "ACES", "Punchy" },
			CurrentOption = State.Tonemap,
			Flag = "ucs_tone",
			Callback = function(v)
				local picked = type(v) == "table" and v[1] or v
				API.setTonemap(picked)
			end,
		})

		local Reflections_ = Window:CreateTab("Reflections", 4483345998)

		Reflections_:CreateSlider({
			Name = "Reflection Intensity",
			Range = { 0, 2 },
			Increment = 0.05,
			Suffix = "x",
			CurrentValue = State.Reflection,
			Flag = "ucs_refl",
			Callback = function(v) API.setReflection(v) end,
		})

		Reflections_:CreateSlider({
			Name = "Wetness",
			Range = { 0, 1 },
			Increment = 0.05,
			Suffix = "",
			CurrentValue = State.Wetness,
			Flag = "ucs_wet",
			Callback = function(v) API.setWetness(v) end,
		})

		Reflections_:CreateButton({
			Name = "Re-scan Workspace",
			Callback = function() if State.Enabled then Detection.scan() end end,
		})

		local Effects = Window:CreateTab("Effects", 4483362458)

		Effects:CreateSlider({
			Name = "Bloom",
			Range = { 0, 2 },
			Increment = 0.05,
			Suffix = "x",
			CurrentValue = State.Bloom,
			Flag = "ucs_bloom",
			Callback = function(v) API.setBloom(v) end,
		})

		Effects:CreateToggle({
			Name = "Vignette",
			CurrentValue = State.Vignette,
			Flag = "ucs_vignette",
			Callback = function(v) API.setVignette(v) end,
		})

		Effects:CreateToggle({
			Name = "Lens Flare",
			CurrentValue = State.LensFlare,
			Flag = "ucs_flare",
			Callback = function(v) API.setLensFlare(v) end,
		})

		Effects:CreateToggle({
			Name = "Weather Mood (time-aware FX)",
			CurrentValue = State.WeatherMood,
			Flag = "ucs_mood",
			Callback = function(v) API.setWeatherMood(v) end,
		})

		Effects:CreateToggle({
			Name = "Cinematic Mode (FOV + DoF)",
			CurrentValue = State.CinematicMode,
			Flag = "ucs_cine",
			Callback = function(v) API.setCinematicMode(v) end,
		})

		Effects:CreateToggle({
			Name = "Auto-Focus DoF",
			CurrentValue = State.AutoFocus,
			Flag = "ucs_af",
			Callback = function(v) API.setAutoFocus(v) end,
		})

		Effects:CreateToggle({
			Name = "Fresnel Reflections",
			CurrentValue = State.FresnelOverlays,
			Flag = "ucs_fr",
			Callback = function(v) API.setFresnelOverlays(v) end,
		})

		Effects:CreateToggle({
			Name = "Motion Blur (camera-velocity)",
			CurrentValue = State.MotionBlur,
			Flag = "ucs_mb",
			Callback = function(v) API.setMotionBlur(v) end,
		})

		Effects:CreateToggle({
			Name = "Eye Adaptation (auto-exposure)",
			CurrentValue = State.EyeAdaptation,
			Flag = "ucs_ea",
			Callback = function(v) API.setEyeAdaptation(v) end,
		})

		Effects:CreateToggle({
			Name = "Light Shadows (PointLight/SpotLight)",
			CurrentValue = State.LightEnhance,
			Flag = "ucs_le",
			Callback = function(v) API.setLightEnhance(v) end,
		})

		Effects:CreateToggle({
			Name = "Night Light Rays (volumetric beams)",
			CurrentValue = State.NightBeams,
			Flag = "ucs_nb",
			Callback = function(v) API.setNightBeams(v) end,
		})

		Effects:CreateToggle({
			Name = "Ray-Traced Reflections (raycast SSR)",
			CurrentValue = State.RayTrace,
			Flag = "ucs_rt",
			Callback = function(v) API.setRayTrace(v) end,
		})

		Effects:CreateToggle({
			Name = "Multi-Bounce RT (2-bounce path tracing)",
			CurrentValue = State.MultiBounceRT,
			Flag = "ucs_mbrt",
			Callback = function(v) API.setMultiBounceRT(v) end,
		})

		Effects:CreateToggle({
			Name = "Camera Fill Light (real-time)",
			CurrentValue = State.CameraFillLight,
			Flag = "ucs_cfl",
			Callback = function(v) API.setCameraFillLight(v) end,
		})

		Effects:CreateToggle({
			Name = "G-Force (vehicle acceleration FOV / blur)",
			CurrentValue = State.GForce,
			Flag = "ucs_gf",
			Callback = function(v) API.setGForce(v) end,
		})

		Effects:CreateToggle({
			Name = "Player Highlight (look-at glow)",
			CurrentValue = State.PlayerHighlight,
			Flag = "ucs_phl",
			Callback = function(v) API.setPlayerHighlight(v) end,
		})

		Effects:CreateToggle({
			Name = "Foliage Polish (richer leaves)",
			CurrentValue = State.FoliageEnhance,
			Flag = "ucs_fol",
			Callback = function(v) API.setFoliageEnhance(v) end,
		})

		Effects:CreateToggle({
			Name = "Fire Enhance (vivid flames)",
			CurrentValue = State.FireEnhance,
			Flag = "ucs_fire",
			Callback = function(v) API.setFireEnhance(v) end,
		})

		Effects:CreateToggle({
			Name = "Smoke Enhance (denser smoke)",
			CurrentValue = State.SmokeEnhance,
			Flag = "ucs_smoke",
			Callback = function(v) API.setSmokeEnhance(v) end,
		})

		Effects:CreateToggle({
			Name = "Sparkles Enhance",
			CurrentValue = State.SparklesEnhance,
			Flag = "ucs_spk",
			Callback = function(v) API.setSparklesEnhance(v) end,
		})

		Effects:CreateToggle({
			Name = "Water Enhance (cinematic terrain water)",
			CurrentValue = State.WaterEnhance,
			Flag = "ucs_water",
			Callback = function(v) API.setWaterEnhance(v) end,
		})

		Effects:CreateToggle({
			Name = "Precipitation (rain/snow follows weather)",
			CurrentValue = State.Precipitation,
			Flag = "ucs_precip",
			Callback = function(v) API.setPrecipitation(v) end,
		})

		Effects:CreateToggle({
			Name = "Lightning (during Stormy weather)",
			CurrentValue = State.Lightning,
			Flag = "ucs_lightning",
			Callback = function(v) API.setLightning(v) end,
		})

		Effects:CreateToggle({
			Name = "Underwater Effect (auto-detect)",
			CurrentValue = State.Underwater,
			Flag = "ucs_under",
			Callback = function(v) API.setUnderwater(v) end,
		})

		Effects:CreateToggle({
			Name = "Free Camera (WASD/QE/Mouse, Shift = sprint)",
			CurrentValue = State.FreeCam,
			Flag = "ucs_freecam",
			Callback = function(v) API.setFreeCam(v) end,
		})

		Effects:CreateToggle({
			Name = "Speed FOV (cinematic motion)",
			CurrentValue = State.SpeedFOV,
			Flag = "ucs_sf",
			Callback = function(v) API.setSpeedFOV(v) end,
		})

		Effects:CreateToggle({
			Name = "Performance HUD",
			CurrentValue = State.PerfHUD,
			Flag = "ucs_hud",
			Callback = function(v) API.setPerfHUD(v) end,
		})

		local Time = Window:CreateTab("Time", 4483362458)

		Time:CreateDropdown({
			Name = "Time Mode",
			Options = { "Auto", "Day", "Night" },
			CurrentOption = State.TimeMode,
			Flag = "ucs_time",
			Callback = function(v)
				local picked = type(v) == "table" and v[1] or v
				API.setTimeMode(picked)
			end,
		})

		Time:CreateDropdown({
			Name = "Weather",
			Options = { "Clear", "Cloudy", "Stormy", "Misty" },
			CurrentOption = State.Weather,
			Flag = "ucs_weather",
			Callback = function(v)
				local picked = type(v) == "table" and v[1] or v
				API.setWeather(picked)
			end,
		})

		-- Quick time-of-day previews (force ClockTime). Useful for screenshots.
		Time:CreateButton({
			Name = "Snap to Noon",
			Callback = function() pcall(function() Lighting.ClockTime = 14.0 end) end,
		})
		Time:CreateButton({
			Name = "Snap to Golden Hour",
			Callback = function() pcall(function() Lighting.ClockTime = 16.5 end) end,
		})
		Time:CreateButton({
			Name = "Snap to Sunset",
			Callback = function() pcall(function() Lighting.ClockTime = 18.0 end) end,
		})
		Time:CreateButton({
			Name = "Snap to Night",
			Callback = function() pcall(function() Lighting.ClockTime = 22.0 end) end,
		})

		Time:CreateToggle({
			Name = "Auto Day/Night Cycle (12-min full day)",
			CurrentValue = State.AutoCycle,
			Flag = "ucs_cycle",
			Callback = function(v) API.setAutoCycle(v) end,
		})

		Time:CreateSlider({
			Name = "Cycle Length (real seconds per in-game day)",
			Range = { 60, 1800 },
			Increment = 30,
			Suffix = "s",
			CurrentValue = math.floor(24 / State.CycleSpeed),
			Flag = "ucs_cyclelen",
			Callback = function(v) API.setCycleSpeed(v) end,
		})

		-- =================================================================
		-- RTX TAB — advanced realism stack. One-tap "Activate RTX" plus
		-- granular toggles + advanced-color sliders for users who want to
		-- tune the look themselves.
		-- =================================================================
		local RTX = Window:CreateTab("RTX", 4483362458)

		RTX:CreateButton({
			Name = "✨ ACTIVATE RTX MODE (Max Realism)",
			Callback = function() API.activateRTX() end,
		})

		RTX:CreateLabel("--- Realism Modules ---")

		RTX:CreateToggle({
			Name = "Enhanced GI (6-tap hemisphere bounce)",
			CurrentValue = State.EnhancedGI,
			Flag = "ucs_gi",
			Callback = function(v) API.setEnhancedGI(v) end,
		})

		RTX:CreateToggle({
			Name = "SSAO (ambient occlusion)",
			CurrentValue = State.SSAO,
			Flag = "ucs_ssao",
			Callback = function(v) API.setSSAO(v) end,
		})

		RTX:CreateSlider({
			Name = "SSAO Intensity",
			Range = { 0, 1 },
			Increment = 0.05,
			Suffix = "",
			CurrentValue = State.SSAOIntensity,
			Flag = "ucs_ssao_i",
			Callback = function(v) API.setSSAOIntensity(v) end,
		})

		RTX:CreateToggle({
			Name = "Anisotropic Metals (brushed-metal look)",
			CurrentValue = State.AnisotropicMetals,
			Flag = "ucs_aniso",
			Callback = function(v) API.setAnisotropicMetals(v) end,
		})

		RTX:CreateToggle({
			Name = "Volumetric Fog",
			CurrentValue = State.VolumetricFog,
			Flag = "ucs_volfog",
			Callback = function(v) API.setVolumetricFog(v) end,
		})

		RTX:CreateSlider({
			Name = "Volumetric Density",
			Range = { 0, 2 },
			Increment = 0.05,
			Suffix = "x",
			CurrentValue = State.VolumetricDensity,
			Flag = "ucs_voldense",
			Callback = function(v) API.setVolumetricDensity(v) end,
		})

		RTX:CreateToggle({
			Name = "Caustics (water patterns on wet floors)",
			CurrentValue = State.Caustics,
			Flag = "ucs_caustics",
			Callback = function(v) API.setCaustics(v) end,
		})

		RTX:CreateToggle({
			Name = "Sun Disc",
			CurrentValue = State.SunDisc,
			Flag = "ucs_sundisc",
			Callback = function(v) API.setSunDisc(v) end,
		})

		RTX:CreateToggle({
			Name = "Film Grain",
			CurrentValue = State.FilmGrain,
			Flag = "ucs_grain",
			Callback = function(v) API.setFilmGrain(v) end,
		})

		RTX:CreateSlider({
			Name = "Film Grain Amount",
			Range = { 0, 1 },
			Increment = 0.02,
			Suffix = "",
			CurrentValue = State.FilmGrainAmount,
			Flag = "ucs_grain_amt",
			Callback = function(v) API.setFilmGrainAmount(v) end,
		})

		RTX:CreateToggle({
			Name = "Chromatic Aberration",
			CurrentValue = State.ChromaticAberration,
			Flag = "ucs_chroma",
			Callback = function(v) API.setChromaticAberration(v) end,
		})

		RTX:CreateSlider({
			Name = "Chromatic Aberration Amount",
			Range = { 0, 1 },
			Increment = 0.05,
			Suffix = "",
			CurrentValue = State.ChromaticAmount,
			Flag = "ucs_chroma_amt",
			Callback = function(v) API.setChromaticAmount(v) end,
		})

		RTX:CreateLabel("--- Advanced Color ---")

		RTX:CreateSlider({
			Name = "White Balance (Kelvin)",
			Range = { 1500, 15000 },
			Increment = 100,
			Suffix = "K",
			CurrentValue = State.WhiteBalance,
			Flag = "ucs_wb",
			Callback = function(v) API.setWhiteBalance(v) end,
		})

		RTX:CreateSlider({
			Name = "WB Tint (magenta-green)",
			Range = { -100, 100 },
			Increment = 1,
			Suffix = "",
			CurrentValue = State.WBTint,
			Flag = "ucs_wbtint",
			Callback = function(v) API.setWBTint(v) end,
		})

		RTX:CreateSlider({
			Name = "Vibrance",
			Range = { -100, 100 },
			Increment = 1,
			Suffix = "",
			CurrentValue = State.Vibrance,
			Flag = "ucs_vib",
			Callback = function(v) API.setVibrance(v) end,
		})

		RTX:CreateSlider({
			Name = "Hue Shift",
			Range = { -180, 180 },
			Increment = 1,
			Suffix = "°",
			CurrentValue = State.HueShift,
			Flag = "ucs_hue",
			Callback = function(v) API.setHueShift(v) end,
		})

		RTX:CreateSlider({
			Name = "Lift (shadows)",
			Range = { -1, 1 },
			Increment = 0.05,
			Suffix = "",
			CurrentValue = State.Lift,
			Flag = "ucs_lift",
			Callback = function(v) API.setLift(v) end,
		})

		RTX:CreateSlider({
			Name = "Gamma (midtones)",
			Range = { 0.2, 5 },
			Increment = 0.05,
			Suffix = "",
			CurrentValue = State.Gamma,
			Flag = "ucs_gamma",
			Callback = function(v) API.setGamma(v) end,
		})

		RTX:CreateSlider({
			Name = "Gain (highlights)",
			Range = { 0.2, 5 },
			Increment = 0.05,
			Suffix = "",
			CurrentValue = State.Gain,
			Flag = "ucs_gain",
			Callback = function(v) API.setGain(v) end,
		})
	end)

	return true
end

function UI.buildFallback()
	-- =====================================================================
	-- Mobile + desktop fallback UI.
	--   • Auto-scales to the device's viewport (phones get a bigger, taller
	--     panel with chunkier hit targets; desktop keeps a compact layout).
	--   • Tabbed (Visuals / Reflections / Effects / Time) with scrollable
	--     content so every Rayfield option is reachable on mobile too.
	--   • Floating circular toggle button at the top-left (draggable) so
	--     touch devices without a keyboard can open / close the panel.
	--     Desktop also keeps the `]` keybind.
	-- =====================================================================

	local isTouch       = UserInputService.TouchEnabled
	local hasKeyboard   = UserInputService.KeyboardEnabled
	local isMobile      = isTouch and not hasKeyboard
	local cam           = workspace.CurrentCamera
	local viewport      = (cam and cam.ViewportSize) or Vector2.new(1280, 720)

	-- Touch-tuned sizing
	local fabSize       = isMobile and 52 or 40
	local rowH          = isMobile and 40 or 32
	local sliderH       = isMobile and 60 or 46
	local labelSize     = isMobile and 13 or 11
	local headerH       = isMobile and 46 or 36
	local tabH          = isMobile and 38 or 30

	local PANEL_W, PANEL_H
	if isMobile then
		PANEL_W = math.clamp(math.floor(viewport.X * 0.48), 320, 460)
		PANEL_H = math.clamp(math.floor(viewport.Y * 0.84), 380, 620)
	else
		PANEL_W = 340
		PANEL_H = 470
	end

	-- ===== FLOATING TOGGLE BUTTON (its own ScreenGui, always visible) =====
	local toggleGui = Instance.new("ScreenGui")
	toggleGui.Name = "Cinematic_FallbackToggle"
	toggleGui.ResetOnSpawn = false
	toggleGui.IgnoreGuiInset = true
	toggleGui.DisplayOrder = 5
	toggleGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	toggleGui.Parent = PlayerGui

	local fab = Instance.new("TextButton")
	fab.Name = "ToggleButton"
	fab.Size = UDim2.fromOffset(fabSize, fabSize)
	fab.Position = UDim2.new(0, 14, 0, 14)
	fab.BackgroundColor3 = Color3.fromRGB(20, 24, 36)
	fab.BackgroundTransparency = 0.08
	fab.BorderSizePixel = 0
	fab.Text = "\u{2630}"  -- ☰ hamburger glyph
	fab.TextColor3 = Color3.fromRGB(230, 240, 255)
	fab.Font = Enum.Font.GothamBold
	fab.TextSize = isMobile and 26 or 20
	fab.AutoButtonColor = false
	fab.Parent = toggleGui
	Instance.new("UICorner", fab).CornerRadius = UDim.new(1, 0)
	local fabStroke = Instance.new("UIStroke", fab)
	fabStroke.Color = Color3.fromRGB(80, 145, 255)
	fabStroke.Thickness = 1.4
	fabStroke.Transparency = 0.3

	-- ===== MAIN PANEL =====
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "Cinematic_FallbackUI"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 4
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Enabled = not isMobile  -- mobile starts collapsed so the button is the only UI footprint
	screenGui.Parent = PlayerGui

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
	frame.Position = UDim2.new(0, 14 + fabSize + 10, 0, 14)
	frame.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
	frame.BackgroundTransparency = 0.04
	frame.BorderSizePixel = 0
	frame.Parent = screenGui
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 12)
	local panelStroke = Instance.new("UIStroke", frame)
	panelStroke.Color = Color3.fromRGB(70, 130, 230)
	panelStroke.Thickness = 1
	panelStroke.Transparency = 0.4

	-- ===== HEADER: title (drag handle) + close button =====
	local header = Instance.new("Frame", frame)
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, headerH)
	header.BackgroundColor3 = Color3.fromRGB(24, 28, 40)
	header.BackgroundTransparency = 0.05
	header.BorderSizePixel = 0
	Instance.new("UICorner", header).CornerRadius = UDim.new(0, 12)

	local title = Instance.new("TextLabel", header)
	title.Size = UDim2.new(1, -64, 1, 0)
	title.Position = UDim2.fromOffset(14, 0)
	title.BackgroundTransparency = 1
	title.Text = "ULTRA CINEMATIC"
	title.TextColor3 = Color3.fromRGB(230, 240, 255)
	title.Font = Enum.Font.GothamBold
	title.TextSize = isMobile and 15 or 13
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Active = true

	local closeBtn = Instance.new("TextButton", header)
	closeBtn.Size = UDim2.fromOffset(headerH - 14, headerH - 14)
	closeBtn.AnchorPoint = Vector2.new(1, 0.5)
	closeBtn.Position = UDim2.new(1, -8, 0.5, 0)
	closeBtn.BackgroundColor3 = Color3.fromRGB(180, 70, 70)
	closeBtn.Text = "X"
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextSize = isMobile and 14 or 12
	closeBtn.AutoButtonColor = false
	Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
	closeBtn.Activated:Connect(function() screenGui.Enabled = false end)

	-- ===== TAB BAR =====
	local tabBar = Instance.new("Frame", frame)
	tabBar.Name = "TabBar"
	tabBar.Size = UDim2.new(1, -16, 0, tabH)
	tabBar.Position = UDim2.fromOffset(8, headerH + 6)
	tabBar.BackgroundTransparency = 1

	local tabLayout = Instance.new("UIListLayout", tabBar)
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 4)
	tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder

	local pages = Instance.new("Frame", frame)
	pages.Size = UDim2.new(1, -16, 1, -(headerH + tabH + 18))
	pages.Position = UDim2.fromOffset(8, headerH + tabH + 12)
	pages.BackgroundTransparency = 1
	pages.ClipsDescendants = true

	local tabNames = { "Visuals", "Reflections", "Effects", "Time", "RTX" }
	local tabBtns, tabPages = {}, {}

	local function selectTab(name)
		for k, btn in pairs(tabBtns) do
			if k == name then
				btn.BackgroundColor3 = Color3.fromRGB(60, 120, 220)
				btn.TextColor3 = Color3.fromRGB(255, 255, 255)
			else
				btn.BackgroundColor3 = Color3.fromRGB(35, 40, 55)
				btn.TextColor3 = Color3.fromRGB(170, 180, 200)
			end
		end
		for k, page in pairs(tabPages) do
			page.Visible = (k == name)
		end
	end

	-- Tabs fill the tab bar evenly: 1/N - small gap. Works for any tab count.
	local tabFraction = 1 / #tabNames
	for i, n in ipairs(tabNames) do
		local b = Instance.new("TextButton", tabBar)
		b.LayoutOrder = i
		b.Size = UDim2.new(tabFraction, -3, 1, 0)
		b.BackgroundColor3 = Color3.fromRGB(35, 40, 55)
		b.Text = n
		b.TextColor3 = Color3.fromRGB(170, 180, 200)
		b.Font = Enum.Font.GothamMedium
		b.TextSize = isMobile and 12 or 10  -- shrink slightly to fit 5 tabs
		b.AutoButtonColor = false
		b.BorderSizePixel = 0
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
		b.Activated:Connect(function() selectTab(n) end)
		tabBtns[n] = b

		local page = Instance.new("ScrollingFrame", pages)
		page.Name = n
		page.Size = UDim2.new(1, 0, 1, 0)
		page.BackgroundTransparency = 1
		page.BorderSizePixel = 0
		page.ScrollBarThickness = isMobile and 5 or 4
		page.ScrollBarImageColor3 = Color3.fromRGB(80, 145, 255)
		page.CanvasSize = UDim2.new(0, 0, 0, 0)
		page.AutomaticCanvasSize = Enum.AutomaticSize.Y
		page.ScrollingDirection = Enum.ScrollingDirection.Y
		page.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
		page.Visible = false

		local layout = Instance.new("UIListLayout", page)
		layout.Padding = UDim.new(0, 6)
		layout.SortOrder = Enum.SortOrder.LayoutOrder

		local pad = Instance.new("UIPadding", page)
		pad.PaddingLeft = UDim.new(0, 2)
		pad.PaddingRight = UDim.new(0, 8)
		pad.PaddingTop = UDim.new(0, 4)
		pad.PaddingBottom = UDim.new(0, 8)

		tabPages[n] = page
	end

	-- ===== WIDGET HELPERS =====
	local order = 0
	local function nextOrder() order = order + 1 return order end

	local function makeToggle(parent, label, initial, callback)
		local row = Instance.new("Frame", parent)
		row.LayoutOrder = nextOrder()
		row.Size = UDim2.new(1, 0, 0, rowH)
		row.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
		row.BackgroundTransparency = 0.05
		row.BorderSizePixel = 0
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

		local lab = Instance.new("TextLabel", row)
		lab.Size = UDim2.new(1, -72, 1, 0)
		lab.Position = UDim2.fromOffset(10, 0)
		lab.BackgroundTransparency = 1
		lab.Text = label
		lab.TextColor3 = Color3.fromRGB(210, 220, 240)
		lab.Font = Enum.Font.Gotham
		lab.TextSize = labelSize
		lab.TextXAlignment = Enum.TextXAlignment.Left
		lab.TextWrapped = true

		local trackW, trackHt = 44, 22
		local track = Instance.new("Frame", row)
		track.AnchorPoint = Vector2.new(1, 0.5)
		track.Position = UDim2.new(1, -10, 0.5, 0)
		track.Size = UDim2.fromOffset(trackW, trackHt)
		track.BorderSizePixel = 0
		Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

		local knob = Instance.new("Frame", track)
		knob.Size = UDim2.fromOffset(trackHt - 4, trackHt - 4)
		knob.AnchorPoint = Vector2.new(0, 0.5)
		knob.BackgroundColor3 = Color3.fromRGB(245, 245, 245)
		knob.BorderSizePixel = 0
		Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

		local state = not not initial
		local function render()
			if state then
				track.BackgroundColor3 = Color3.fromRGB(70, 145, 255)
				knob.Position = UDim2.new(1, -(trackHt - 2), 0.5, 0)
			else
				track.BackgroundColor3 = Color3.fromRGB(60, 65, 80)
				knob.Position = UDim2.new(0, 2, 0.5, 0)
			end
		end
		render()

		local btn = Instance.new("TextButton", row)
		btn.Size = UDim2.new(1, 0, 1, 0)
		btn.BackgroundTransparency = 1
		btn.Text = ""
		btn.AutoButtonColor = false
		btn.Activated:Connect(function()
			state = not state
			render()
			callback(state)
		end)

		return { setValue = function(v) state = not not v; render() end }
	end

	local function makeSlider(parent, label, range, initial, fmt, callback)
		local row = Instance.new("Frame", parent)
		row.LayoutOrder = nextOrder()
		row.Size = UDim2.new(1, 0, 0, sliderH)
		row.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
		row.BackgroundTransparency = 0.05
		row.BorderSizePixel = 0
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)

		local lab = Instance.new("TextLabel", row)
		lab.Size = UDim2.new(1, -16, 0, 18)
		lab.Position = UDim2.fromOffset(10, 7)
		lab.BackgroundTransparency = 1
		lab.TextColor3 = Color3.fromRGB(210, 220, 240)
		lab.Font = Enum.Font.Gotham
		lab.TextSize = labelSize
		lab.TextXAlignment = Enum.TextXAlignment.Left

		local val = initial
		local format = fmt or "%.2f"
		local function render()
			lab.Text = string.format("%s: %s", label, string.format(format, val))
		end
		render()

		-- Big invisible hit zone so a finger doesn't have to land on a 6px bar
		local hitH = isMobile and 28 or 18
		local hit = Instance.new("Frame", row)
		hit.Size = UDim2.new(1, -20, 0, hitH)
		hit.Position = UDim2.new(0, 10, 1, -(hitH + 6))
		hit.BackgroundTransparency = 1

		local track = Instance.new("Frame", hit)
		track.Size = UDim2.new(1, 0, 0, 6)
		track.AnchorPoint = Vector2.new(0, 0.5)
		track.Position = UDim2.new(0, 0, 0.5, 0)
		track.BackgroundColor3 = Color3.fromRGB(40, 45, 60)
		track.BorderSizePixel = 0
		Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

		local fill = Instance.new("Frame", track)
		local rel = (val - range[1]) / (range[2] - range[1])
		fill.Size = UDim2.new(math.clamp(rel, 0, 1), 0, 1, 0)
		fill.BackgroundColor3 = Color3.fromRGB(80, 145, 255)
		fill.BorderSizePixel = 0
		Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

		local dragging = false
		local function update(input)
			local r = math.clamp((input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
			fill.Size = UDim2.new(r, 0, 1, 0)
			val = range[1] + r * (range[2] - range[1])
			render()
			callback(val)
		end
		hit.InputBegan:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
				dragging = true; update(i)
			end
		end)
		hit.InputEnded:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end)
		UserInputService.InputChanged:Connect(function(i)
			if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
				update(i)
			end
		end)

		return {
			setValue = function(v)
				val = math.clamp(v, range[1], range[2])
				local rr = (val - range[1]) / (range[2] - range[1])
				fill.Size = UDim2.new(rr, 0, 1, 0)
				render()
			end
		}
	end

	local function makeCycle(parent, label, options, initial, color, callback)
		local idx = 1
		for i, opt in ipairs(options) do if opt == initial then idx = i end end

		local row = Instance.new("TextButton", parent)
		row.LayoutOrder = nextOrder()
		row.Size = UDim2.new(1, 0, 0, rowH)
		row.BackgroundColor3 = color or Color3.fromRGB(60, 50, 130)
		row.Text = string.format("%s: %s", label, options[idx])
		row.TextColor3 = Color3.fromRGB(235, 240, 255)
		row.Font = Enum.Font.GothamMedium
		row.TextSize = labelSize
		row.AutoButtonColor = false
		row.BorderSizePixel = 0
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)
		row.Activated:Connect(function()
			idx = (idx % #options) + 1
			row.Text = string.format("%s: %s", label, options[idx])
			callback(options[idx])
		end)
		return row
	end

	local function makeButton(parent, label, color, callback)
		local b = Instance.new("TextButton", parent)
		b.LayoutOrder = nextOrder()
		b.Size = UDim2.new(1, 0, 0, rowH)
		b.BackgroundColor3 = color or Color3.fromRGB(45, 105, 215)
		b.Text = label
		b.TextColor3 = Color3.fromRGB(255, 255, 255)
		b.Font = Enum.Font.GothamMedium
		b.TextSize = labelSize
		b.AutoButtonColor = false
		b.BorderSizePixel = 0
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
		b.Activated:Connect(callback)
		return b
	end

	-- ===== POPULATE TABS =====
	local v = tabPages.Visuals
	makeToggle(v, "Enable Shader",      State.Enabled,     function(s) API.setEnabled(s) end)
	makeSlider(v, "Master Intensity",   {0, 2},  State.Intensity,  "%.2fx", function(x) API.setIntensity(x) end)
	makeCycle (v, "Quality",            { "Low", "Medium", "High", "Ultra", "Max" },
	           State.Quality, Color3.fromRGB(40, 130, 90),
	           function(q) API.setQuality(q) end)
	makeCycle (v, "Preset",             { "Enhanced", "Cinematic", "Realistic", "Photorealistic", "GTA Day", "GTA Night", "Sunset", "Vintage", "Neutral" },
	           State.ColorPreset, Color3.fromRGB(80, 60, 150),
	           function(p) API.setColorPreset(p) end)
	makeCycle (v, "Tonemap",            { "Linear", "Filmic", "ACES", "Punchy", "Reinhard", "Cinematic" },
	           State.Tonemap, Color3.fromRGB(60, 95, 150),
	           function(t) API.setTonemap(t) end)

	local r = tabPages.Reflections
	makeSlider(r, "Reflection",         {0, 2},  State.Reflection, "%.2fx", function(x) API.setReflection(x) end)
	makeSlider(r, "Wetness",            {0, 1},  State.Wetness,    "%.2f",  function(x) API.setWetness(x) end)
	makeToggle(r, "Fresnel Reflections",   State.FresnelOverlays, function(s) API.setFresnelOverlays(s) end)
	makeToggle(r, "Ray-Traced Reflections",State.RayTrace,        function(s) API.setRayTrace(s) end)
	makeToggle(r, "Multi-Bounce RT",       State.MultiBounceRT,   function(s) API.setMultiBounceRT(s) end)
	makeToggle(r, "Water Enhance",         State.WaterEnhance,    function(s) API.setWaterEnhance(s) end)
	makeButton(r, "Re-scan Workspace",  Color3.fromRGB(40, 130, 90),
	           function() if State.Enabled then Detection.scan() end end)

	local e = tabPages.Effects
	makeSlider(e, "Bloom",              {0, 2},  State.Bloom,      "%.2fx", function(x) API.setBloom(x) end)
	makeToggle(e, "Vignette",              State.Vignette,        function(s) API.setVignette(s) end)
	makeToggle(e, "Lens Flare",            State.LensFlare,       function(s) API.setLensFlare(s) end)
	makeToggle(e, "Weather Mood",          State.WeatherMood,     function(s) API.setWeatherMood(s) end)
	makeToggle(e, "Cinematic Mode",        State.CinematicMode,   function(s) API.setCinematicMode(s) end)
	makeToggle(e, "Auto-Focus DoF",        State.AutoFocus,       function(s) API.setAutoFocus(s) end)
	makeToggle(e, "Motion Blur",           State.MotionBlur,      function(s) API.setMotionBlur(s) end)
	makeToggle(e, "Eye Adaptation",        State.EyeAdaptation,   function(s) API.setEyeAdaptation(s) end)
	makeToggle(e, "Light Shadows",         State.LightEnhance,    function(s) API.setLightEnhance(s) end)
	makeToggle(e, "Night Light Rays",      State.NightBeams,      function(s) API.setNightBeams(s) end)
	makeToggle(e, "Camera Fill Light",     State.CameraFillLight, function(s) API.setCameraFillLight(s) end)
	makeToggle(e, "Speed FOV",             State.SpeedFOV,        function(s) API.setSpeedFOV(s) end)
	makeToggle(e, "G-Force FOV",           State.GForce,          function(s) API.setGForce(s) end)
	makeToggle(e, "Player Highlight",      State.PlayerHighlight, function(s) API.setPlayerHighlight(s) end)
	makeToggle(e, "Foliage Polish",        State.FoliageEnhance,  function(s) API.setFoliageEnhance(s) end)
	makeToggle(e, "Fire Enhance",          State.FireEnhance,     function(s) API.setFireEnhance(s) end)
	makeToggle(e, "Smoke Enhance",         State.SmokeEnhance,    function(s) API.setSmokeEnhance(s) end)
	makeToggle(e, "Sparkles Enhance",      State.SparklesEnhance, function(s) API.setSparklesEnhance(s) end)
	makeToggle(e, "Underwater Effect",     State.Underwater,      function(s) API.setUnderwater(s) end)
	makeToggle(e, "Performance HUD",       State.PerfHUD,         function(s) API.setPerfHUD(s) end)
	-- Free Camera relies on WASD/QE/Mouse — only expose it where a keyboard exists.
	if hasKeyboard then
		makeToggle(e, "Free Camera (WASD)",State.FreeCam,         function(s) API.setFreeCam(s) end)
	end

	local t = tabPages.Time
	makeCycle (t, "Time",     { "Auto", "Day", "Night" },
	           State.TimeMode, Color3.fromRGB(60, 95, 150), function(m) API.setTimeMode(m) end)
	makeCycle (t, "Weather",  { "Clear", "Cloudy", "Stormy", "Misty" },
	           State.Weather, Color3.fromRGB(70, 80, 140), function(w) API.setWeather(w) end)
	makeButton(t, "Snap to Noon",        Color3.fromRGB(60, 110, 180), function() pcall(function() Lighting.ClockTime = 14.0 end) end)
	makeButton(t, "Snap to Golden Hour", Color3.fromRGB(180, 130, 60), function() pcall(function() Lighting.ClockTime = 16.5 end) end)
	makeButton(t, "Snap to Sunset",      Color3.fromRGB(190, 100, 60), function() pcall(function() Lighting.ClockTime = 18.0 end) end)
	makeButton(t, "Snap to Night",       Color3.fromRGB(50, 70, 130),  function() pcall(function() Lighting.ClockTime = 22.0 end) end)
	makeToggle(t, "Auto Day/Night Cycle",   State.AutoCycle,      function(s) API.setAutoCycle(s) end)
	makeSlider(t, "Cycle Length",       {60, 1800}, math.floor(24 / State.CycleSpeed), "%.0fs", function(x) API.setCycleSpeed(x) end)
	makeToggle(t, "Precipitation",          State.Precipitation,  function(s) API.setPrecipitation(s) end)
	makeToggle(t, "Lightning",              State.Lightning,      function(s) API.setLightning(s) end)

	-- ===== RTX TAB — advanced realism stack =====
	local rt = tabPages.RTX
	makeButton(rt, "* ACTIVATE RTX MODE *",      Color3.fromRGB(180, 60, 200), function() API.activateRTX() end)
	makeToggle(rt, "Enhanced GI",                State.EnhancedGI,         function(s) API.setEnhancedGI(s) end)
	makeToggle(rt, "SSAO",                       State.SSAO,               function(s) API.setSSAO(s) end)
	makeSlider(rt, "SSAO Intensity",       {0, 1},  State.SSAOIntensity,  "%.2f",  function(x) API.setSSAOIntensity(x) end)
	makeToggle(rt, "Anisotropic Metals",         State.AnisotropicMetals,  function(s) API.setAnisotropicMetals(s) end)
	makeToggle(rt, "Volumetric Fog",             State.VolumetricFog,      function(s) API.setVolumetricFog(s) end)
	makeSlider(rt, "Volumetric Density",   {0, 2},  State.VolumetricDensity, "%.2fx", function(x) API.setVolumetricDensity(x) end)
	makeToggle(rt, "Caustics",                   State.Caustics,           function(s) API.setCaustics(s) end)
	makeToggle(rt, "Sun Disc",                   State.SunDisc,            function(s) API.setSunDisc(s) end)
	makeToggle(rt, "Film Grain",                 State.FilmGrain,          function(s) API.setFilmGrain(s) end)
	makeSlider(rt, "Film Grain Amount",    {0, 1},  State.FilmGrainAmount, "%.2f",  function(x) API.setFilmGrainAmount(x) end)
	makeToggle(rt, "Chromatic Aberration",       State.ChromaticAberration, function(s) API.setChromaticAberration(s) end)
	makeSlider(rt, "Chroma Amount",        {0, 1},  State.ChromaticAmount, "%.2f",  function(x) API.setChromaticAmount(x) end)
	-- Advanced color grading
	makeSlider(rt, "White Balance",  {1500, 15000}, State.WhiteBalance,    "%.0fK", function(x) API.setWhiteBalance(x) end)
	makeSlider(rt, "WB Tint",        {-100, 100},   State.WBTint,          "%.0f",  function(x) API.setWBTint(x) end)
	makeSlider(rt, "Vibrance",       {-100, 100},   State.Vibrance,        "%.0f",  function(x) API.setVibrance(x) end)
	makeSlider(rt, "Hue Shift",      {-180, 180},   State.HueShift,        "%.0f",  function(x) API.setHueShift(x) end)
	makeSlider(rt, "Lift (shadows)", {-1, 1},       State.Lift,            "%.2f",  function(x) API.setLift(x) end)
	makeSlider(rt, "Gamma (mids)",   {0.2, 5},      State.Gamma,           "%.2f",  function(x) API.setGamma(x) end)
	makeSlider(rt, "Gain (highs)",   {0.2, 5},      State.Gain,            "%.2f",  function(x) API.setGain(x) end)

	selectTab("Visuals")

	-- ===== FLOATING TOGGLE — tap to open/close, drag to reposition =====
	local fabMoved = false
	local fabDragging = false
	local fabDragStart, fabPosStart
	fab.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			fabDragging = true
			fabDragStart = i.Position
			fabPosStart  = fab.Position
			fabMoved = false
		end
	end)
	fab.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			fabDragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(i)
		if fabDragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - fabDragStart
			if d.Magnitude > 8 then fabMoved = true end
			fab.Position = UDim2.new(
				fabPosStart.X.Scale, fabPosStart.X.Offset + d.X,
				fabPosStart.Y.Scale, fabPosStart.Y.Offset + d.Y
			)
		end
	end)
	fab.Activated:Connect(function()
		-- Only toggle if the user didn't drag the button somewhere
		if not fabMoved then
			screenGui.Enabled = not screenGui.Enabled
		end
	end)

	-- ===== PANEL DRAG (header is the drag handle) =====
	local panelDragging = false
	local panelDragStart, panelPosStart
	header.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			panelDragging = true
			panelDragStart = i.Position
			panelPosStart  = frame.Position
		end
	end)
	header.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			panelDragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(i)
		if panelDragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - panelDragStart
			frame.Position = UDim2.new(
				panelPosStart.X.Scale, panelPosStart.X.Offset + d.X,
				panelPosStart.Y.Scale, panelPosStart.Y.Offset + d.Y
			)
		end
	end)

	-- ===== KEYBOARD SHORTCUT (desktop only) =====
	if hasKeyboard then
		UserInputService.InputBegan:Connect(function(i, gp)
			if gp then return end
			if i.KeyCode == Enum.KeyCode.RightBracket then
				screenGui.Enabled = not screenGui.Enabled
			end
		end)
	end
end

-- =========================================================================
-- INITIALIZATION
-- =========================================================================

-- Check if the place was baked by StudioCinematicPlugin. If so, inherit
-- the wetness slider and color preset the plugin author chose, so the
-- runtime layer matches what's already baked into the place.
local function detectBakedPlace()
	local baked = Lighting:GetAttribute(ATTR_BAKED)
	if not baked then return false end

	local wet = Lighting:GetAttribute(ATTR_BAKE_WETNESS)
	if type(wet) == "number" then
		State.Wetness = math.clamp(wet, 0, 1)
	end

	local preset = Lighting:GetAttribute(ATTR_BAKE_PRESET)
	if type(preset) == "string" and ColorPresets[preset] then
		State.ColorPreset = preset
	end

	local stamp = Lighting:GetAttribute(ATTR_BAKE_TIME)
	print(string.format(
		"[UltraShader] Plugin-baked place detected (bake time=%s). Inherited wetness=%.2f, preset=%s.",
		tostring(stamp), State.Wetness, State.ColorPreset
	))
	return true
end

local function init()
	if State.Initialized then return end

	print("[UltraShader] init() started")
	detectBakedPlace()

	OriginalLighting = LightingMod.snapshot()
	print("[UltraShader] - lighting snapshotted")
	PostFX.build()
	print("[UltraShader] - FX nodes built")
	VignetteMod.build()
	LensFlare.build()
	PerfHUD.build()
	print("[UltraShader] - GUIs built")

	LightingMod.applyProfile()
	PostFX.applyIntensity()
	PostFX.setEnabled(true)
	VignetteMod.setVisible(State.Vignette)
	SkyMod.apply()
	print("[UltraShader] - lighting + FX applied")

	Detection.bindAdded()
	Detection.scan()
	Lights.scan()
	NightBeams.scan()
	Foliage.scan()
	FireMod.scan()
	SmokeMod.scan()
	SparklesMod.scan()
	WaterMod.apply()
	Precipitation.build()
	CameraFill.build()
	PlayerHighlight.bindAll()
	CameraFX.bindCharacter()
	Adaptive.start()

	-- Streaming-aware re-scan: places with Workspace.StreamingEnabled=true
	-- swap chunks in/out as the player moves. DescendantAdded fires for new
	-- chunks but it can miss bursts during heavy traversal. Periodic rescan
	-- ensures we catch everything that streamed in. Loop self-terminates when
	-- State.Initialized goes false (kill() sets that).
	if Workspace.StreamingEnabled then
		task.spawn(function()
			while task.wait(12) do
				if not State.Initialized then break end
				if State.Enabled then
					Detection.scan()
					Lights.scan()
					NightBeams.scan()
					Foliage.scan()
					FireMod.scan()
					SmokeMod.scan()
					SparklesMod.scan()
				end
			end
		end)
	end
	print("[UltraShader] - scanners running")

	-- Build advanced realism modules. These create their own ScreenGuis/Folders
	-- but stay disabled until the user (or RTX preset) flips them on.
	FilmGrain.build()
	SunDisc.build()
	VolFog.build()
	print("[UltraShader] - RTX stack built")

	-- Bind the main per-frame loop now that every module is defined.
	track(RunService.RenderStepped:Connect(function(dt)
		AdaptiveQuality.sample(dt)   -- still tracked for the PerfHUD readout
		CameraFX.updateSunRays(dt)
		CameraFX.updateAutoFocus()
		CameraFX.updateSpeedFOV(dt)
		CameraFX.updateImpactShake(dt)
		CameraFX.updateMotionBlur(dt)
		CameraFX.updateEyeAdaptation()
		CameraFX.updateFresnelOverlays()
		NightBeams.update()
		NightBeams.updateRealtime()
		RayTrace.update()
		CameraFill.update(dt)
		PlayerHighlight.update()
		Precipitation.update()
		Lightning.update()
		CycleMod.update(dt)
		UnderwaterMod.update()
		LensFlare.update()
		PerfHUD.update()
		-- ===== ADVANCED REALISM PER-FRAME =====
		SunDisc.update()
		VolFog.update(dt)
		FilmGrain.update()
		Caustics.update()
		SSAO.update()
		AnisotropicMetals.update()
	end))
	print("[UltraShader] - RenderStepped bound")

	-- UI: try Rayfield first (HTTP), fall back to built-in custom panel.
	local rayfieldOk = false
	pcall(function() rayfieldOk = UI.tryRayfield() end)
	if rayfieldOk then
		print("[UltraShader] - Rayfield UI loaded")
	else
		local fbOk, fbErr = pcall(UI.buildFallback)
		if fbOk then
			print("[UltraShader] - fallback UI built")
		else
			warn("[UltraShader] Fallback UI failed: " .. tostring(fbErr))
		end
	end

	State.Initialized = true
	print(string.rep("=", 60))
	print("[UltraShader] READY — preset: " .. State.ColorPreset .. ", quality: " .. State.Quality)
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		print("[UltraShader] Tap the floating ≡ button (top-left) to open the panel.")
	else
		print("[UltraShader] Press ]  (or tap the ≡ button) to toggle the panel.")
	end
	print(string.rep("=", 60))

	task.delay(2, function()
		pcall(checkRobloxQuality)
	end)
end

-- =========================================================================
-- GLOBAL HANDLE — exposes the API and a clean kill() for external control.
-- Lets you do `_G.CinematicShader.api.setIntensity(1.5)` from any other
-- script / executor / admin panel, or fully tear down with `.kill()`.
-- =========================================================================

local function kill()
	-- Disable all visual systems and restore originals
	pcall(function() API.setEnabled(false) end)

	-- Disconnect every tracked connection (RenderStepped/Heartbeat/CharacterAdded/etc.)
	for _, conn in ipairs(Connections) do
		pcall(function() conn:Disconnect() end)
	end
	table.clear(Connections)
	disconnectImpactShake()
	pcall(function() CameraFill.cleanup() end)
	-- Realism stack tear-down
	pcall(function() FilmGrain.cleanup() end)
	pcall(function() SunDisc.cleanup() end)
	pcall(function() VolFog.cleanup() end)
	pcall(function() Caustics.cleanup() end)

	-- Destroy plugin-created FX nodes that aren't the place's own
	for _, name in ipairs({
		"Cinematic_Atmosphere", "Cinematic_Bloom", "Cinematic_SunRays",
		"Cinematic_CC_Main", "Cinematic_CC_Grade", "Cinematic_CC_Tone",
		"Cinematic_CC_WhiteBal", "Cinematic_CC_LiftGammaGain",
		"Cinematic_CC_Vibrance", "Cinematic_CC_Hue",
		"Cinematic_CC_ChromaR", "Cinematic_CC_ChromaB",
		"Cinematic_Blur", "Cinematic_DOF",
	}) do
		local fx = Lighting:FindFirstChild(name)
		if fx then fx:Destroy() end
	end

	-- Destroy our ScreenGuis
	for _, name in ipairs({
		"Cinematic_Vignette", "Cinematic_LensFlare", "Cinematic_PerfHUD",
		"Cinematic_FallbackUI", "Cinematic_FallbackToggle", "Cinematic_Toast",
		"Cinematic_FilmGrain", "Cinematic_SunDisc",
	}) do
		local g = PlayerGui:FindFirstChild(name)
		if g then g:Destroy() end
	end

	-- Destroy workspace folders we created
	local volFog = Workspace:FindFirstChild("Cinematic_VolFog")
	if volFog then volFog:Destroy() end

	-- Restore camera FOV
	if OriginalFOV and workspace.CurrentCamera then
		workspace.CurrentCamera.FieldOfView = OriginalFOV
	end

	State.Initialized = false   -- breaks the streaming-rescan loop
	_G.CinematicShader = nil
	print("[UltraShader] Fully torn down. Re-paste the script to reinitialize.")
end

local function info()
	return {
		Enabled       = State.Enabled,
		Quality       = State.Quality,
		ColorPreset   = State.ColorPreset,
		Intensity     = State.Intensity,
		Wetness       = State.Wetness,
		AvgFPS        = AdaptiveQuality.average(),
		Overlays      = #CollectionService:GetTagged(TAG_OVERLAY),
		EnhancedParts = #CollectionService:GetTagged(TAG_PROCESSED),
		ShadowLights  = #CollectionService:GetTagged(TAG_LIGHT),
		Mood          = State.WeatherMood and State.TimeMode == "Auto"
			and (function()
				local t = Lighting.ClockTime
				if t < 5 then return "Night"
				elseif t < 6.5 then return "Dawn"
				elseif t < 9 then return "Morning"
				elseif t < 15 then return "Midday"
				elseif t < 17 then return "Golden"
				elseif t < 18.5 then return "Sunset"
				elseif t < 20 then return "Dusk"
				else return "Night" end
			end)()
			or State.TimeMode,
	}
end

_G.CinematicShader = {
	api       = API,
	state     = State,
	profile   = Profile,
	presets   = ColorPresets,
	qualities = QualityProfiles,
	weathers  = WEATHERS,
	moods     = MOODS,
	tonemaps  = TONEMAPS,
	kill      = kill,
	info      = info,
	export    = function() return API.exportPreset() end,
	import    = function(s) return API.importPreset(s) end,
	activateRTX = function() return API.activateRTX() end,
	version   = "Cinematic-4.0-RTX",
}

init()
