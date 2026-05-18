--[[
	CINEMATIC MAP ENHANCER — Roblox Studio Plugin

	Bakes premium cinematic visuals into a place you own. Unlike the runtime
	LocalScript, this plugin operates inside Studio and the changes save with
	the place — every player who joins gets the enhanced visuals automatically.

	Installation:
	  1. Save this file as a .lua / .rbxm and place it in your Roblox Studio
	     Plugins folder, OR open a Script in Studio, paste this, right-click
	     the script in Explorer, choose "Save as Local Plugin".
	  2. Studio → Plugins tab → "Cinematic Map Enhancer" button.

	What it does (each step undoable via Ctrl+Z):
	  • Apply Cinematic Lighting — Future tech, tuned Ambient/Brightness/Exposure,
	    creates Atmosphere + Bloom + ColorCorrection + SunRays + DoF.
	  • Enhance Materials — iterates Workspace, applies per-material reflectance
	    to floors/glass/metal, preserves textures, skips PBR (SurfaceAppearance).
	  • Generate Wet Road Overlays — places thin Glass parts above large
	    horizontal floor parts for real wet-pavement reflections.
	  • Optimize — disables CastShadow on tiny parts that don't need it, sets
	    Locked on overlays so they don't get accidentally edited.
	  • Restore — reverts each layer using snapshots stored as attributes.
--]]

if not plugin then
	warn("[CinematicMapEnhancer] Open this in Studio and use 'Save as Local Plugin'.")
	return
end

local Lighting           = game:GetService("Lighting")
local Workspace          = game:GetService("Workspace")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService  = game:GetService("CollectionService")
local Selection          = game:GetService("Selection")

local PLUGIN_NAME = "Cinematic Map Enhancer"

-- Shared namespace with CinematicShader.client.lua runtime so a baked place
-- is automatically detected by the runtime on join and the two systems
-- share overlays / tags / FX nodes instead of duplicating them.
local TAG_OVERLAY    = "Cinematic_Overlay"
local TAG_PROCESSED  = "Cinematic_Processed"
local TAG_LIGHT      = "Cinematic_LightProc"
local OVERLAY_NAME   = "Cinematic_WetOverlay"
local ATTR_ORIG_MAT  = "Cinematic_OrigMat"
local ATTR_ORIG_REF  = "Cinematic_OrigRef"
local ATTR_ORIG_CST  = "Cinematic_OrigCast"
local ATTR_CLASS     = "Cinematic_Class"

-- Bake metadata written to Lighting so the runtime can detect bakes
local ATTR_BAKED        = "Cinematic_Baked"
local ATTR_BAKE_WETNESS = "Cinematic_BakeWetness"
local ATTR_BAKE_PRESET  = "Cinematic_BakePreset"
local ATTR_BAKE_TIME    = "Cinematic_BakeTime"

-- =========================================================================
-- PROFILE
-- =========================================================================

local LightingProfile = {
	Technology               = Enum.Technology.Future,
	Ambient                  = Color3.fromRGB(62, 62, 62),
	OutdoorAmbient           = Color3.fromRGB(140, 140, 140),
	Brightness               = 2.0,
	ClockTime                = 14.5,
	ColorShift_Top           = Color3.fromRGB(14, 12, 10),
	ColorShift_Bottom        = Color3.fromRGB(218, 210, 192),
	EnvironmentDiffuseScale  = 0.5,
	EnvironmentSpecularScale = 0.95,
	ExposureCompensation     = 0.08,
	FogColor                 = Color3.fromRGB(205, 205, 205),
	FogEnd                   = 100000,
	FogStart                 = 2500,
	GeographicLatitude       = 41.7,
	GlobalShadows            = true,
	ShadowSoftness           = 0.14,
}

local AtmosphereProfile = {
	Density = 0.18,
	Offset  = 0.25,
	Color   = Color3.fromRGB(212, 212, 212),
	Decay   = Color3.fromRGB(115, 115, 115),
	Glare   = 0.12,
	Haze    = 1.4,
}

local BloomProfile = {
	Intensity = 0.4,
	Size      = 16,
	Threshold = 2.1,
}

local SunRaysProfile = {
	Intensity = 0.22,
	Spread    = 0.92,
}

local CCMainProfile = {
	Brightness = -0.02,
	Contrast   = 0.28,
	Saturation = 0.05,
	TintColor  = Color3.fromRGB(252, 248, 244),
}

local CCGradeProfile = {
	Brightness = 0.0,
	Contrast   = 0.08,
	Saturation = 0.0,
	TintColor  = Color3.fromRGB(252, 246, 240),
}

local DOFProfile = {
	FarIntensity   = 0.0,
	FocusDistance  = 80,
	InFocusRadius  = 50,
	NearIntensity  = 0.0,
}

local Reflectance = {
	Floor   = 0.20,
	Glass   = 0.55,
	Metal   = 0.32,
	Surface = 0.03,
}

local Detection = {
	FloorMinArea     = 80,
	FloorNormalDot   = 0.9,
	SmallPartCutoff  = 0.5,
	OverlayMinArea   = 100,
	OverlayMaxCount  = 800,
	TinyShadowSize   = 1.0,
}

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
	[Enum.Material.Asphalt]       = 0.75,
	[Enum.Material.Limestone]     = 0.5,
	[Enum.Material.Brick]         = 0.4,
	[Enum.Material.Cobblestone]   = 0.45,
	[Enum.Material.Pebble]        = 0.3,
	[Enum.Material.Wood]          = 0.5,
	[Enum.Material.WoodPlanks]    = 0.55,
	[Enum.Material.Basalt]        = 0.5,
}

-- =========================================================================
-- HELPERS
-- =========================================================================

local function getColorLuminance(c)
	return c.R * 0.2126 + c.G * 0.7152 + c.B * 0.0722
end

local function albedoScale(part)
	local b = getColorLuminance(part.Color)
	return math.clamp(b * 1.5 + 0.05, 0.1, 1.15)
end

local function overlayAlbedoScale(part)
	local b = getColorLuminance(part.Color)
	return math.clamp(b * 0.7 + 0.3, 0.3, 1.05)
end

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
	local c = Detection.SmallPartCutoff
	return s.X < c and s.Y < c and s.Z < c
end

local function classify(part)
	if not part:IsA("BasePart") then return nil end
	if part.Name == OVERLAY_NAME then return nil end
	if CollectionService:HasTag(part, TAG_OVERLAY) then return nil end
	if part:IsDescendantOf(Lighting) then return nil end
	if isCharacterPart(part) then return nil end
	if hasSurfaceAppearance(part) then return nil end
	if isTooSmall(part) then return nil end
	if part.Transparency >= 0.97 then return nil end

	local m = part.Material
	if m == Enum.Material.Neon then return "neon" end
	if m == Enum.Material.Glass then return "glass" end
	if METAL_MATERIALS[m] then return "metal" end

	if FLOOR_MATERIALS[m] then
		local up = part.CFrame.UpVector
		local size = part.Size
		local area = size.X * size.Z
		local longestH = math.max(size.X, size.Z)
		if up.Y >= Detection.FloorNormalDot
			and area >= Detection.FloorMinArea
			and size.Y <= longestH * 0.85 then
			return "floor"
		end
		return "surface"
	end
	return nil
end

local function canHaveOverlay(part)
	if not part:IsA("Part") then return false end
	if part.Shape ~= Enum.PartType.Block then return false end
	local s = part.Size
	if s.X * s.Z < Detection.OverlayMinArea then return false end
	if s.Y > math.max(s.X, s.Z) * 0.8 then return false end
	return true
end

local function snapshotPart(part)
	if part:GetAttribute(ATTR_ORIG_MAT) ~= nil then return end
	part:SetAttribute(ATTR_ORIG_MAT, part.Material.Name)
	part:SetAttribute(ATTR_ORIG_REF, part.Reflectance)
	part:SetAttribute(ATTR_ORIG_CST, part.CastShadow)
end

local function restorePart(part)
	local mat = part:GetAttribute(ATTR_ORIG_MAT)
	if mat then
		local m = Enum.Material[mat]
		if m then part.Material = m end
	end
	local r = part:GetAttribute(ATTR_ORIG_REF)
	if r ~= nil then part.Reflectance = r end
	local c = part:GetAttribute(ATTR_ORIG_CST)
	if c ~= nil then part.CastShadow = c end
	part:SetAttribute(ATTR_ORIG_MAT, nil)
	part:SetAttribute(ATTR_ORIG_REF, nil)
	part:SetAttribute(ATTR_ORIG_CST, nil)
	part:SetAttribute(ATTR_CLASS, nil)
	CollectionService:RemoveTag(part, TAG_PROCESSED)
end

-- =========================================================================
-- ACTIONS
-- =========================================================================

local function getRootInstances()
	local sel = Selection:Get()
	if #sel > 0 then return sel end
	return { Workspace }
end

local function iterateBaseParts(root, callback)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") then
			callback(descendant)
		end
	end
	if root:IsA("BasePart") then callback(root) end
end

local function setOrClearChild(parent, className, name, props)
	local existing = parent:FindFirstChild(name)
	if existing and not existing:IsA(className) then
		existing:Destroy()
		existing = nil
	end
	if not existing then
		existing = Instance.new(className)
		existing.Name = name
		existing.Parent = parent
	end
	for k, v in pairs(props) do
		existing[k] = v
	end
	return existing
end

local function applyCinematicLighting()
	ChangeHistoryService:SetWaypoint("Cinematic: Apply Lighting")
	for k, v in pairs(LightingProfile) do
		pcall(function() Lighting[k] = v end)
	end
	-- Remove any non-plugin Atmospheres so ours is the only one
	for _, c in ipairs(Lighting:GetChildren()) do
		if c:IsA("Atmosphere") and c.Name ~= "Cinematic_Atmosphere" then
			c:Destroy()
		end
	end
	setOrClearChild(Lighting, "Atmosphere",            "Cinematic_Atmosphere", AtmosphereProfile)
	setOrClearChild(Lighting, "BloomEffect",           "Cinematic_Bloom",      BloomProfile)
	setOrClearChild(Lighting, "SunRaysEffect",         "Cinematic_SunRays",    SunRaysProfile)
	setOrClearChild(Lighting, "ColorCorrectionEffect", "Cinematic_CC_Main",    CCMainProfile)
	setOrClearChild(Lighting, "ColorCorrectionEffect", "Cinematic_CC_Grade",   CCGradeProfile)
	setOrClearChild(Lighting, "DepthOfFieldEffect",    "Cinematic_DOF",        DOFProfile)
	ChangeHistoryService:SetWaypoint("Cinematic: Lighting Applied")
	print("[Cinematic] Lighting applied — Future tech + 6 FX nodes.")
end

local function restoreLighting()
	ChangeHistoryService:SetWaypoint("Cinematic: Before Lighting Restore")
	for _, name in ipairs({
		"Cinematic_Atmosphere", "Cinematic_Bloom", "Cinematic_SunRays",
		"Cinematic_CC_Main", "Cinematic_CC_Grade", "Cinematic_DOF",
	}) do
		local inst = Lighting:FindFirstChild(name)
		if inst then inst:Destroy() end
	end
	-- Clear bake metadata so the runtime no longer thinks the place is baked
	Lighting:SetAttribute(ATTR_BAKED, nil)
	Lighting:SetAttribute(ATTR_BAKE_WETNESS, nil)
	Lighting:SetAttribute(ATTR_BAKE_PRESET, nil)
	Lighting:SetAttribute(ATTR_BAKE_TIME, nil)
	ChangeHistoryService:SetWaypoint("Cinematic: Lighting Restored")
	print("[Cinematic] Plugin lighting nodes + bake metadata removed.")
end

local function enhanceMaterials()
	ChangeHistoryService:SetWaypoint("Cinematic: Before Material Enhance")
	local roots = getRootInstances()
	local count = { floor = 0, glass = 0, metal = 0, neon = 0, surface = 0 }
	for _, root in ipairs(roots) do
		iterateBaseParts(root, function(part)
			if CollectionService:HasTag(part, TAG_PROCESSED) then return end
			local class = classify(part)
			if not class then return end
			snapshotPart(part)
			local albedo = albedoScale(part)
			if class == "floor" then
				if part.Material == Enum.Material.Plastic then
					part.Material = Enum.Material.SmoothPlastic
				end
				local mult = FLOOR_REFLECTIVITY[part.Material] or 1.0
				part.Reflectance = math.clamp(Reflectance.Floor * mult * albedo, 0, 0.35)
				part.CastShadow = true
				count.floor = count.floor + 1
			elseif class == "glass" then
				part.Material = Enum.Material.Glass
				local a = math.max(0.55, albedo)
				part.Reflectance = math.clamp(Reflectance.Glass * a, 0, 0.85)
				count.glass = count.glass + 1
			elseif class == "metal" then
				local a = math.max(0.4, albedo)
				part.Reflectance = math.clamp(Reflectance.Metal * a, 0, 0.6)
				count.metal = count.metal + 1
			elseif class == "neon" then
				part.CastShadow = false
				count.neon = count.neon + 1
			elseif class == "surface" then
				local target = math.clamp(Reflectance.Surface * albedo, 0, 0.08)
				if part.Reflectance < target then
					part.Reflectance = target
				end
				count.surface = count.surface + 1
			end
			part:SetAttribute(ATTR_CLASS, class)
			CollectionService:AddTag(part, TAG_PROCESSED)
		end)
	end
	ChangeHistoryService:SetWaypoint("Cinematic: Materials Enhanced")
	print(string.format(
		"[Cinematic] Materials enhanced — floor:%d glass:%d metal:%d neon:%d surface:%d",
		count.floor, count.glass, count.metal, count.neon, count.surface
	))
end

local function restoreMaterials()
	ChangeHistoryService:SetWaypoint("Cinematic: Before Material Restore")
	local restored = 0
	for _, part in ipairs(CollectionService:GetTagged(TAG_PROCESSED)) do
		if part:IsA("BasePart") and part.Parent then
			restorePart(part)
			restored = restored + 1
		end
	end
	ChangeHistoryService:SetWaypoint("Cinematic: Materials Restored")
	print(string.format("[Cinematic] Restored %d parts.", restored))
end

local function generateWetOverlays(wetness)
	wetness = wetness or 0.55
	ChangeHistoryService:SetWaypoint("Cinematic: Before Wet Overlays")
	local roots = getRootInstances()
	local made = 0
	for _, root in ipairs(roots) do
		iterateBaseParts(root, function(part)
			if part:FindFirstChild(OVERLAY_NAME) then return end
			if part:GetAttribute(ATTR_CLASS) ~= "floor" then return end
			if not canHaveOverlay(part) then return end
			if #CollectionService:GetTagged(TAG_OVERLAY) >= Detection.OverlayMaxCount then return end

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
			overlay.Color = Color3.new(
				math.clamp(c.R * 0.4 + 0.55, 0, 1),
				math.clamp(c.G * 0.4 + 0.55, 0, 1),
				math.clamp(c.B * 0.4 + 0.55, 0, 1)
			)
			overlay.Size = Vector3.new(size.X * 0.997, 0.04, size.Z * 0.997)
			overlay.CFrame = part.CFrame * CFrame.new(0, size.Y * 0.5 + 0.022, 0)
			local oa = overlayAlbedoScale(part)
			overlay.Transparency = math.clamp(1 - (wetness * 0.55), 0.4, 1)
			overlay.Reflectance = math.clamp(wetness * wetness * 0.95 * oa, 0, 0.95)
			overlay.Parent = part
			CollectionService:AddTag(overlay, TAG_OVERLAY)
			made = made + 1
		end)
	end
	ChangeHistoryService:SetWaypoint("Cinematic: Wet Overlays Created")
	print(string.format("[Cinematic] Created %d wet overlays.", made))
end

local function removeWetOverlays()
	ChangeHistoryService:SetWaypoint("Cinematic: Before Overlay Removal")
	local removed = 0
	for _, overlay in ipairs(CollectionService:GetTagged(TAG_OVERLAY)) do
		overlay:Destroy()
		removed = removed + 1
	end
	ChangeHistoryService:SetWaypoint("Cinematic: Overlays Removed")
	print(string.format("[Cinematic] Removed %d overlays.", removed))
end

local function optimizeShadows()
	ChangeHistoryService:SetWaypoint("Cinematic: Before Shadow Optimize")
	local roots = getRootInstances()
	local off = 0
	for _, root in ipairs(roots) do
		iterateBaseParts(root, function(part)
			if part.Name == OVERLAY_NAME then return end
			local s = part.Size
			local cutoff = Detection.TinyShadowSize
			if s.X < cutoff and s.Y < cutoff and s.Z < cutoff and part.CastShadow then
				part.CastShadow = false
				off = off + 1
			end
		end)
	end
	ChangeHistoryService:SetWaypoint("Cinematic: Shadows Optimized")
	print(string.format("[Cinematic] Disabled shadows on %d tiny parts.", off))
end

-- Used by Full Enhance to stamp metadata that the runtime shader detects on join
local function writeBakeMetadata(wetness, preset)
	Lighting:SetAttribute(ATTR_BAKED, true)
	Lighting:SetAttribute(ATTR_BAKE_WETNESS, wetness or 0.55)
	Lighting:SetAttribute(ATTR_BAKE_PRESET, preset or "Enhanced")
	Lighting:SetAttribute(ATTR_BAKE_TIME, os.time())
end

local function fullEnhance()
	applyCinematicLighting()
	enhanceMaterials()
	generateWetOverlays(0.55)
	optimizeShadows()
	writeBakeMetadata(0.55, "Enhanced")
	print("[Cinematic] Bake metadata stamped on Lighting — runtime will detect this place.")
end

local function fullRestore()
	restoreLighting()
	removeWetOverlays()
	restoreMaterials()
end

-- =========================================================================
-- UI
-- =========================================================================

local toolbar = plugin:CreateToolbar(PLUGIN_NAME)
local panelBtn = toolbar:CreateButton("Cinematic", "Toggle Cinematic Map Enhancer panel", "rbxasset://textures/AnimationEditor/button_settings.png")
local quickBtn = toolbar:CreateButton("Full Enhance", "One-click cinematic enhancement of Workspace", "rbxasset://textures/loading/robloxTilt.png")
local restoreBtn = toolbar:CreateButton("Restore", "Remove all plugin enhancements", "rbxasset://textures/AnimationEditor/button_undo.png")

quickBtn.Click:Connect(fullEnhance)
restoreBtn.Click:Connect(fullRestore)

local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Right,
	false, false,
	320, 700,
	280, 500
)
local widget = plugin:CreateDockWidgetPluginGui(PLUGIN_NAME, widgetInfo)
widget.Title = PLUGIN_NAME
widget.Name = "CinematicEnhancerWidget"

panelBtn.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

local root = Instance.new("Frame")
root.Size = UDim2.fromScale(1, 1)
root.BackgroundColor3 = Color3.fromRGB(26, 28, 36)
root.BorderSizePixel = 0
root.Parent = widget

local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.fromScale(1, 1)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 4
scroll.ScrollBarImageColor3 = Color3.fromRGB(80, 100, 160)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.Parent = root

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = scroll

local pad = Instance.new("UIPadding")
pad.PaddingTop = UDim.new(0, 12)
pad.PaddingBottom = UDim.new(0, 12)
pad.PaddingLeft = UDim.new(0, 12)
pad.PaddingRight = UDim.new(0, 12)
pad.Parent = scroll

local order = 0
local function nextOrder()
	order = order + 1
	return order
end

local function makeHeader(text)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 22)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(170, 195, 245)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.Text = text
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.LayoutOrder = nextOrder()
	label.Parent = scroll
	return label
end

local function makeBody(text)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 32)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(155, 165, 180)
	label.Font = Enum.Font.Gotham
	label.TextSize = 11
	label.Text = text
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = true
	label.LayoutOrder = nextOrder()
	label.Parent = scroll
	return label
end

local function makeButton(text, callback, color)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 0, 34)
	btn.BackgroundColor3 = color or Color3.fromRGB(58, 110, 215)
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.Font = Enum.Font.GothamMedium
	btn.TextSize = 13
	btn.Text = text
	btn.AutoButtonColor = true
	btn.LayoutOrder = nextOrder()
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
	btn.MouseButton1Click:Connect(callback)
	btn.Parent = scroll
	return btn
end

local function makeSpacer(height)
	local f = Instance.new("Frame")
	f.Size = UDim2.new(1, 0, 0, height or 4)
	f.BackgroundTransparency = 1
	f.LayoutOrder = nextOrder()
	f.Parent = scroll
end

local function makeSlider(text, min, max, default, increment, callback)
	local container = Instance.new("Frame")
	container.Size = UDim2.new(1, 0, 0, 44)
	container.BackgroundTransparency = 1
	container.LayoutOrder = nextOrder()
	container.Parent = scroll

	local label = Instance.new("TextLabel", container)
	label.Size = UDim2.new(1, 0, 0, 16)
	label.BackgroundTransparency = 1
	label.Text = string.format("%s: %.2f", text, default)
	label.TextColor3 = Color3.fromRGB(190, 200, 220)
	label.Font = Enum.Font.Gotham
	label.TextSize = 11
	label.TextXAlignment = Enum.TextXAlignment.Left

	local track = Instance.new("Frame", container)
	track.Size = UDim2.new(1, 0, 0, 6)
	track.Position = UDim2.fromOffset(0, 22)
	track.BackgroundColor3 = Color3.fromRGB(40, 45, 60)
	track.BorderSizePixel = 0
	Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

	local fill = Instance.new("Frame", track)
	local rel = (default - min) / (max - min)
	fill.Size = UDim2.new(rel, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(80, 145, 255)
	fill.BorderSizePixel = 0
	Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

	local current = default
	local dragging = false
	local function update(inputX)
		local r = math.clamp((inputX - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
		local raw = min + r * (max - min)
		local stepped = math.floor(raw / increment + 0.5) * increment
		current = math.clamp(stepped, min, max)
		fill.Size = UDim2.new((current - min) / (max - min), 0, 1, 0)
		label.Text = string.format("%s: %.2f", text, current)
		callback(current)
	end

	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			update(input.Position.X)
		end
	end)
	track.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)
	scroll.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			update(input.Position.X)
		end
	end)

	return container
end

-- ==== Build the panel ====

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 24)
title.BackgroundTransparency = 1
title.TextColor3 = Color3.fromRGB(235, 240, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 16
title.Text = "Cinematic Map Enhancer"
title.TextXAlignment = Enum.TextXAlignment.Left
title.LayoutOrder = nextOrder()
title.Parent = scroll

local subtitle = Instance.new("TextLabel")
subtitle.Size = UDim2.new(1, 0, 0, 16)
subtitle.BackgroundTransparency = 1
subtitle.TextColor3 = Color3.fromRGB(130, 140, 160)
subtitle.Font = Enum.Font.Gotham
subtitle.TextSize = 11
subtitle.Text = "Bake AAA visuals into a place you own. Ctrl+Z works."
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.LayoutOrder = nextOrder()
subtitle.Parent = scroll

makeSpacer(6)
makeHeader("Quick Actions")
makeButton("✦ Full Cinematic Enhance", fullEnhance, Color3.fromRGB(76, 130, 230))
makeBody("Applies lighting + materials + wet overlays + shadow optimization. Operates on Selection if anything is selected; otherwise on Workspace.")

makeSpacer(4)
makeHeader("Lighting")
makeButton("Apply Cinematic Lighting", applyCinematicLighting)
makeButton("Restore Lighting", restoreLighting, Color3.fromRGB(120, 60, 60))

makeSpacer(4)
makeHeader("Materials")
makeButton("Enhance Materials", enhanceMaterials)
makeButton("Restore Materials", restoreMaterials, Color3.fromRGB(120, 60, 60))
makeBody("Adds per-material reflectance to floors / glass / metal. Skips parts with SurfaceAppearance to preserve PBR textures.")

makeSpacer(4)
makeHeader("Wet Roads")
local wetnessValue = 0.55
makeSlider("Wetness", 0.1, 1.0, 0.55, 0.05, function(v) wetnessValue = v end)
makeButton("Generate Wet Overlays", function()
	generateWetOverlays(wetnessValue)
	if Lighting:GetAttribute(ATTR_BAKED) then
		Lighting:SetAttribute(ATTR_BAKE_WETNESS, wetnessValue)
	end
end)
makeButton("Remove Wet Overlays", removeWetOverlays, Color3.fromRGB(120, 60, 60))
makeBody("Places a thin Glass plane 0.02 studs above each detected floor. Future tech reflects neighboring parts onto the overlay → believable wet pavement.")

makeSpacer(4)
makeHeader("Optimization")
makeButton("Disable Shadows on Tiny Parts", optimizeShadows)
makeBody("Turns CastShadow off for parts < 1×1×1 studs. Big FPS win on detail-heavy maps.")

makeSpacer(4)
makeHeader("Danger Zone")
makeButton("◐ Remove ALL Plugin Enhancements", fullRestore, Color3.fromRGB(160, 50, 50))

makeSpacer(12)
local footer = Instance.new("TextLabel")
footer.Size = UDim2.new(1, 0, 0, 32)
footer.BackgroundTransparency = 1
footer.TextColor3 = Color3.fromRGB(110, 120, 140)
footer.Font = Enum.Font.Gotham
footer.TextSize = 10
footer.Text = "Tip: Select a Folder / Model first to limit scope, otherwise the whole Workspace is processed."
footer.TextXAlignment = Enum.TextXAlignment.Left
footer.TextWrapped = true
footer.LayoutOrder = nextOrder()
footer.Parent = scroll

print("[CinematicMapEnhancer] Loaded. Use the toolbar buttons.")
