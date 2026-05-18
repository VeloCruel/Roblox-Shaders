# ApplyRobloxSettings.ps1
#
# One-time helper to set Roblox's saved graphics quality to maximum.
# Safe: only modifies the user-editable GlobalBasicSettings XML file inside
# %LocalAppData%\Roblox\. Does NOT touch the Roblox executable, does NOT
# inject anything, does NOT change running processes. Hyperion has no
# reason to flag this — it's the same file Roblox writes itself when you
# change the slider in the in-game settings menu.
#
# Run once:   powershell -ExecutionPolicy Bypass -File .\ApplyRobloxSettings.ps1
#
# Roblox should be CLOSED when you run this so it doesn't overwrite the
# settings on exit.

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "===========================================" -ForegroundColor Cyan
Write-Host " Cinematic Shader — Roblox Settings Helper " -ForegroundColor Cyan
Write-Host "===========================================" -ForegroundColor Cyan
Write-Host ""

# --- locate Roblox app data ---------------------------------------------
$robloxRoot = Join-Path $env:LOCALAPPDATA "Roblox"
if (-not (Test-Path $robloxRoot)) {
	Write-Host "  Roblox install not found at $robloxRoot" -ForegroundColor Red
	Write-Host "  Install Roblox and launch it at least once, then re-run." -ForegroundColor Yellow
	exit 1
}

# --- ensure Roblox isn't running ----------------------------------------
$running = Get-Process -Name "RobloxPlayerBeta", "RobloxStudioBeta" -ErrorAction SilentlyContinue
if ($running) {
	Write-Host "  Roblox is currently running. Close it before applying settings." -ForegroundColor Yellow
	Write-Host "  (Roblox writes settings on exit and will overwrite these changes.)"
	exit 1
}

# --- find the latest GlobalBasicSettings file ---------------------------
$settingsFiles = Get-ChildItem $robloxRoot -Filter "GlobalBasicSettings_*.xml" -ErrorAction SilentlyContinue |
	Sort-Object Name -Descending
if (-not $settingsFiles) {
	Write-Host "  No GlobalBasicSettings_*.xml found in $robloxRoot" -ForegroundColor Red
	Write-Host "  Launch Roblox once (so it writes the file), close it, then re-run." -ForegroundColor Yellow
	exit 1
}

$settingsFile = $settingsFiles[0].FullName
Write-Host "  Found settings file:" -ForegroundColor Green
Write-Host "    $settingsFile"
Write-Host ""

# --- back up -------------------------------------------------------------
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupFile = "$settingsFile.bak-$timestamp"
Copy-Item $settingsFile $backupFile -Force
Write-Host "  Backup saved:" -ForegroundColor Green
Write-Host "    $backupFile"
Write-Host ""

# --- load XML ------------------------------------------------------------
try {
	[xml]$xml = Get-Content $settingsFile -Raw
} catch {
	Write-Host "  Failed to parse XML: $_" -ForegroundColor Red
	exit 1
}

# --- helper: set or insert a typed setting -------------------------------
function Set-OrAdd($parent, $tag, $attrName, $value) {
	# Look for an existing element with matching name attribute (any tag type)
	$existing = $parent.SelectSingleNode("./*[@name='$attrName']")
	if ($existing) {
		if ($existing.Name -ne $tag) {
			# Replace with the correct typed tag
			$new = $parent.OwnerDocument.CreateElement($tag)
			$new.SetAttribute("name", $attrName)
			$new.InnerText = "$value"
			[void]$parent.ReplaceChild($new, $existing)
			Write-Host ("  Retyped {0,-26} -> <{1}> = {2}" -f $attrName, $tag, $value)
		} else {
			$existing.InnerText = "$value"
			Write-Host ("  Updated  {0,-26} = {1}" -f $attrName, $value)
		}
	} else {
		$new = $parent.OwnerDocument.CreateElement($tag)
		$new.SetAttribute("name", $attrName)
		$new.InnerText = "$value"
		[void]$parent.AppendChild($new)
		Write-Host ("  Added    {0,-26} = {1}" -f $attrName, $value)
	}
}

# Roblox XML root is either <roblox> or <roblox xmlns:...>
$root = $xml.DocumentElement

# --- apply graphics settings --------------------------------------------
Write-Host "  Applying high-quality defaults:" -ForegroundColor Cyan
Set-OrAdd $root "token" "GraphicsQualityLevel"   10
Set-OrAdd $root "token" "SavedQualityLevel"      "QualityLevel10"
Set-OrAdd $root "token" "GraphicsMode"           "NoGraphics"  # Manual mode flag set below
Set-OrAdd $root "bool"  "IsUsingCameraYInvert"   "false"
Set-OrAdd $root "int"   "FrameRateManager"       1              # Unlimited / max
Set-OrAdd $root "token" "SavedFrameRateLevel"    "FrameRate240"

# Save back ---------------------------------------------------------------
$xml.Save($settingsFile)

Write-Host ""
Write-Host "  Done. Launch Roblox and visuals will boot at maximum quality." -ForegroundColor Green
Write-Host "  To revert: delete $settingsFile and rename the .bak file back," -ForegroundColor Gray
Write-Host "  or simply change Graphics Quality in Roblox's Settings menu." -ForegroundColor Gray
Write-Host ""
