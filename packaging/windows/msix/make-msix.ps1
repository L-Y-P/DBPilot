#Requires -Version 5.1
<#
.SYNOPSIS
    Package the Flutter Windows build of DBPilot into a Microsoft Store (MSIX) package.

.DESCRIPTION
    Produces a submission-ready .msix from build\windows\x64\runner\Release:

      1. renders packaging/windows/msix/AppxManifest.template.xml with the identity
         (Name / Publisher / Version / Architecture) given on the command line;
      2. generates every tile logo the manifest references from the app icon;
      3. calls makeappx.exe pack from the Windows SDK;
      4. unpacks the result again as a self-check (a broken manifest then fails here,
         not in Partner Center);
      5. optionally signs with a self-signed certificate - that is only needed to
         INSTALL the package locally. The Microsoft Store re-signs every submission,
         so an unsigned package is the normal output.

    NOTE: this file must stay pure ASCII. Windows PowerShell 5.1 reads BOM-less .ps1
    files in the ANSI code page, so a single Chinese character in a comment or a
    string corrupts the whole script on a zh-CN box ("Unexpected token").

.PARAMETER SourceDir
    Flutter release output, e.g. build\windows\x64\runner\Release.

.PARAMETER Version
    Store version. Accepts 1.1.3 (three segments, the app version) or 1.1.3.0;
    MSIX requires four numeric segments, so a missing fourth becomes 0.

.PARAMETER Publisher
    Publisher string from Partner Center (Package/Identity/Publisher), e.g.
    CN=1A2B3C4D-1234-5678-9ABC-DEF012345678. Leave empty only for a local layout
    test: the placeholder then makes the package unsubmittable.

.PARAMETER IdentityName
    Partner Center Package/Identity/Name, e.g. 1234ABCD.DBPilot.

.PARAMETER OutFile
    Destination .msix.

.PARAMETER Arch
    x64 (default), x86 or arm64. The manifest and makeappx follow it.

.PARAMETER CertPath
    Optional .pfx for LOCAL test signing (the Store re-signs submissions).

.PARAMETER CertPassword
    Password of -CertPath.

.PARAMETER PublisherDisplayName
    Name shown under the app icon in the Store / Start menu.

.PARAMETER DisplayName
    Package display name.

.PARAMETER AppIconPng
    Icon to derive the tiles from. Defaults to windows\runner\resources\app_icon.ico
    (which already carries 256/128/64/48/32/24/16 variants), then
    assets\images\dbpilot.png.

.PARAMETER MakeAppxPath
    Explicit makeappx.exe. Defaults to the newest one found under the Windows SDK.

.PARAMETER KeepLayout
    Keep the rendered staging folder for inspection instead of deleting it.

.EXAMPLE
    # Local smoke test: unsigned package, placeholder identity.
    # (Backtick at end of line = PowerShell line continuation.)
    .\make-msix.ps1 -SourceDir build\windows\x64\runner\Release `
        -Version 1.1.3 -OutFile DBPilot-1.1.3-x64.msix

.EXAMPLE
    # What CI does: real identity, unsigned package.
    .\make-msix.ps1 -SourceDir build\windows\x64\runner\Release `
        -Version 1.1.3 -IdentityName 1234ABCD.DBPilot `
        -Publisher "CN=1A2B3C4D-1234-5678-9ABC-DEF012345678" `
        -OutFile DBPilot-1.1.3-x64.msix

.EXAMPLE
    # Local install test: sign with a throwaway certificate.
    .\make-msix.ps1 ... -CertPath C:\verify\test.pfx -CertPassword test123
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Publisher = '',
    [string]$IdentityName = '',
    [Parameter(Mandatory = $true)][string]$OutFile,
    [ValidateSet('x64', 'x86', 'arm64')][string]$Arch = 'x64',
    [string]$CertPath = '',
    [string]$CertPassword = '',
    [string]$PublisherDisplayName = 'DBPilot',
    [string]$DisplayName = 'DBPilot',
    [string]$AppIconPng = '',
    [string]$MakeAppxPath = '',
    [switch]$KeepLayout
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# ------------------------------------------------------------------ paths
# Absolute paths up front: makeappx resolves relative paths from the current
# directory, and callers invoke this from the repo root.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$templatePath = Join-Path $scriptDir 'AppxManifest.template.xml'
if (-not (Test-Path $templatePath)) { throw "Manifest template not found: $templatePath" }

if (-not (Test-Path $SourceDir)) {
    throw "Build output not found: $SourceDir (run: flutter build windows --release)"
}
$sourceFull = (Resolve-Path $SourceDir).Path
# Absolute output path. $OutFile may be absolute already (CI always passes one);
# Join-Path would turn 'C:\verify\out\x.msix' into a bogus 'C:\verify\C:\...'.
if ([IO.Path]::IsPathRooted($OutFile)) {
    $outFull = [IO.Path]::GetFullPath($OutFile)
}
else {
    $outFull = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutFile))
}
$outDir = Split-Path -Parent $outFull
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$ExeName = 'DBPilot.exe'
if (-not (Test-Path (Join-Path $sourceFull $ExeName))) {
    throw "No $ExeName in $sourceFull - SourceDir must be the runner Release folder"
}

# ---------------------------------------------------------------- version
# MSIX versions are four numeric segments, each 0..65535. 1.1.3 and 1.1.3.0 are
# both accepted so the caller can pass the app version verbatim.
function ConvertTo-MsixVersion([string]$raw) {
    $text = ($raw.Trim() -replace '^[vV]', '')
    if ($text.Contains('+')) { $text = $text.Split('+')[0] }
    if ($text.Contains('-')) { $text = $text.Split('-')[0] }
    $parts = @($text.Split('.') | ForEach-Object { $_.Trim() })
    if ($parts.Count -lt 1 -or $parts.Count -gt 4) {
        throw ("Version must have 1 to 4 segments: '$raw'")
    }
    while ($parts.Count -lt 4) { $parts += '0' }
    $nums = @()
    foreach ($p in $parts) {
        if ($p -notmatch '^[0-9]+$') {
            throw ("Version has a non-numeric segment: '$raw' (segment='$p')")
        }
        $n = [int]$p
        if ($n -lt 0 -or $n -gt 65535) {
            throw ("MSIX version segments must be 0..65535: '$raw'")
        }
        $nums += $n
    }
    # The Store rejects packages whose major version is 0.
    if ($nums[0] -lt 1) { throw ("MSIX major version must be >= 1: '$raw'") }
    return ($nums -join '.')
}

$msixVersion = ConvertTo-MsixVersion $Version
Write-Step "Version $Version -> MSIX $msixVersion"

# --------------------------------------------------------------- identity
if ([string]::IsNullOrWhiteSpace($IdentityName)) {
    # Partner Center identity names look like <PublisherId>.<Name>. The local
    # placeholder is deliberately obvious so nobody uploads the result.
    $IdentityName = 'DBPilot.Placeholder'
    Write-Warning '-IdentityName not supplied: placeholder DBPilot.Placeholder (NOT submittable)'
}
if ([string]::IsNullOrWhiteSpace($Publisher)) {
    # Publisher must equal the signing certificate subject; the placeholder is
    # only usable for an unsigned, layout-only local package.
    $Publisher = 'CN=DBPilot-Local-Test'
    Write-Warning '-Publisher not supplied: placeholder CN=DBPilot-Local-Test (NOT submittable)'
}
# The package family name only becomes final after the Store claims the app;
# a derived value keeps local test machines free of odd package names.
$packageFamilyName = ($IdentityName -replace '[^A-Za-z0-9.-]', '') + '_placeholder'
Write-Step "Identity  $IdentityName"
Write-Step "Publisher $Publisher"

# --------------------------------------------------------------- makeappx
function Find-MakeAppx {
    if ($MakeAppxPath) {
        if (-not (Test-Path $MakeAppxPath)) { throw "makeappx not found: $MakeAppxPath" }
        return (Resolve-Path $MakeAppxPath).Path
    }
    $onPath = @(Get-Command makeappx.exe -ErrorAction SilentlyContinue)
    if ($onPath.Count -gt 0) { return $onPath[0].Source }
    $roots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
        "$env:ProgramFiles\Windows Kits\10\bin"
    )
    $found = @()
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $found += Get-ChildItem -Path $root -Filter 'makeappx.exe' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\makeappx\.exe$' }
    }
    if ($found.Count -gt 0) {
        return ($found | Sort-Object -Property FullName -Descending | Select-Object -First 1).FullName
    }
    throw 'makeappx.exe not found. Install the Windows SDK (MakeAppx) or pass -MakeAppxPath.'
}

function Find-SignTool {
    $onPath = @(Get-Command signtool.exe -ErrorAction SilentlyContinue)
    if ($onPath.Count -gt 0) { return $onPath[0].Source }
    $roots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
        "$env:ProgramFiles\Windows Kits\10\bin"
    )
    $found = @()
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $found += Get-ChildItem -Path $root -Filter 'signtool.exe' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' }
    }
    if ($found.Count -gt 0) {
        return ($found | Sort-Object -Property FullName -Descending | Select-Object -First 1).FullName
    }
    return $null
}

$makeappx = Find-MakeAppx
Write-Step "makeappx: $makeappx"

# --------------------------------------------------------------- staging
$staging = Join-Path ([IO.Path]::GetTempPath()) ("dbpilot-msix-" + [Guid]::NewGuid().ToString('N'))
$layout = Join-Path $staging 'layout'
Write-Step "staging: $layout"
New-Item -ItemType Directory -Path $layout -Force | Out-Null

try {
    # ---- 1. app payload
    # The whole runner Release folder: DBPilot.exe, flutter_windows.dll,
    # data\ (icudtl.dat + flutter_assets), the Rust cdylib and plugin DLLs.
    Copy-Item -Path (Join-Path $sourceFull '*') -Destination $layout -Recurse -Force
    $copiedExe = Join-Path $layout $ExeName
    if (-not (Test-Path $copiedExe)) {
        throw "After the copy $ExeName is still missing - wrong SourceDir?"
    }

    # ---- 2. manifest
    $manifest = Get-Content -Path $templatePath -Raw
    $manifest = $manifest.Replace('__IDENTITY_NAME__', $IdentityName)
    $manifest = $manifest.Replace('__PUBLISHER_ID__', $Publisher)
    $manifest = $manifest.Replace('__PACKAGE_FAMILY_NAME__', $packageFamilyName)
    $manifest = $manifest.Replace('__DISPLAY_NAME__', $DisplayName)
    $manifest = $manifest.Replace('__PUBLISHER_DISPLAY_NAME__', $PublisherDisplayName)
    $manifest = $manifest.Replace('__VERSION__', $msixVersion)
    $manifest = $manifest.Replace('__ARCH__', $Arch)
    $manifest = $manifest.Replace('__EXE_NAME__', $ExeName)
    # An unreplaced __XXX__ means the template gained a placeholder this script
    # does not know: fail instead of shipping double underscores to the Store.
    $leftover = [regex]::Matches($manifest, '__[A-Z0-9_]+__')
    if ($leftover.Count -gt 0) {
        $names = ($leftover | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ', '
        throw "Unreplaced placeholders left in the manifest: $names"
    }
    # UTF-8 without BOM: a BOM would land in front of the XML declaration.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'), $manifest, $utf8NoBom)

    # ---- 3. assets
    $assetsDir = Join-Path $layout 'Assets'
    New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null
    # Icon lookup order: explicit -AppIconPng, then the Flutter Windows app
    # icon (an .ico that already carries 256/128/64/48/32/24/16), then the
    # Flutter asset (128x128 only, noticeably softer at 310x310). Candidates are
    # searched relative to the script (packaging\windows\msix) and to the
    # caller's directory (repo root in CI), so the script works no matter where
    # it is invoked from.
    if ([string]::IsNullOrWhiteSpace($AppIconPng)) {
        $candidateRoots = @(
            (Split-Path -Parent (Split-Path -Parent $scriptDir)),
            (Get-Location).Path
        )
        $candidates = @()
        foreach ($r in $candidateRoots) {
            $candidates += (Join-Path $r 'windows\runner\resources\app_icon.ico')
        }
        foreach ($r in $candidateRoots) {
            $candidates += (Join-Path $r 'assets\images\dbpilot.png')
        }
        foreach ($c in $candidates) {
            if (Test-Path $c) { $AppIconPng = $c; break }
        }
    }
    if ([string]::IsNullOrWhiteSpace($AppIconPng) -or -not (Test-Path $AppIconPng)) {
        throw 'App icon not found: pass -AppIconPng pointing at an .ico or .png'
    }
    $AppIconPng = (Resolve-Path $AppIconPng).Path
    Write-Step "icon source: $AppIconPng"

    Add-Type -AssemblyName System.Drawing

    # Read the whole image into memory once: an .ico keeps the source stream
    # locked while its Bitmap is alive.
    function Load-SourceBitmap([string]$p) {
        if ($p.ToLowerInvariant().EndsWith('.ico')) {
            $icon = New-Object System.Drawing.Icon($p, 256, 256)
            return $icon.ToBitmap()
        }
        $bytes = [IO.File]::ReadAllBytes($p)
        $ms = New-Object System.IO.MemoryStream(, $bytes)
        return [System.Drawing.Image]::FromStream($ms)
    }

    # Aspect-preserving scale, centred: the icon is square while tiles are not,
    # so the extra width stays transparent (the tile background colour shows).
    function Save-Tile([System.Drawing.Image]$src, [string]$dest, [int]$w, [int]$h) {
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $scale = [Math]::Min($w / $src.Width, $h / $src.Height)
            $dw = [int][Math]::Round($src.Width * $scale)
            $dh = [int][Math]::Round($src.Height * $scale)
            $dx = [int](($w - $dw) / 2)
            $dy = [int](($h - $dh) / 2)
            $rect = New-Object System.Drawing.Rectangle($dx, $dy, $dw, $dh)
            $g.DrawImage($src, $rect)
        }
        finally { $g.Dispose() }
        try { $bmp.Save($dest, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
    }

    $source = Load-SourceBitmap $AppIconPng
    try {
        # Every file referenced by the manifest must exist or makeappx pack
        # fails with 0x80080204. Sizes follow the Microsoft tile guidance.
        $tiles = @(
            @{ Name = 'Square44x44Logo.png'; W = 44; H = 44 },
            @{ Name = 'Square71x71Logo.png'; W = 71; H = 71 },
            @{ Name = 'Square150x150Logo.png'; W = 150; H = 150 },
            @{ Name = 'LargeTile.png'; W = 310; H = 310 },
            @{ Name = 'Wide310x150Logo.png'; W = 310; H = 150 },
            @{ Name = 'StoreLogo.png'; W = 50; H = 50 },
            @{ Name = 'Square44x44Logo.targetsize-44_altform-unplated.png'; W = 44; H = 44 },
            @{ Name = 'Square44x44Logo.targetsize-24_altform-unplated.png'; W = 24; H = 24 },
            @{ Name = 'Square150x150Logo.scale-100.png'; W = 150; H = 150 },
            @{ Name = 'Square150x150Logo.scale-200.png'; W = 300; H = 300 }
        )
        foreach ($t in $tiles) {
            Save-Tile $source (Join-Path $assetsDir $t.Name) $t.W $t.H
        }
    }
    finally { $source.Dispose() }
    $assetCount = @(Get-ChildItem $assetsDir -Filter *.png).Count
    Write-Step "generated $assetCount tile images"

    # ---- 4. pack
    if (Test-Path $outFull) { Remove-Item $outFull -Force }
    Write-Step "makeappx pack -> $outFull"
    & $makeappx pack /p $outFull /d $layout /o /v
    if ($LASTEXITCODE -ne 0) { throw "makeappx pack failed (exit $LASTEXITCODE)" }
    if (-not (Test-Path $outFull)) { throw "makeappx exited 0 but produced no $outFull" }
    $size = (Get-Item $outFull).Length
    Write-Step ("package written: $outFull ({0:N1} MB)" -f ($size / 1MB))

    # ---- 5. verify
    # Always unpack again, signed or not: makeappx only really validates the
    # manifest/asset references on unpack.
    $verifyDir = Join-Path $staging 'verify'
    & $makeappx unpack /p $outFull /d $verifyDir /o
    if ($LASTEXITCODE -ne 0) { throw "makeappx unpack verification failed (exit $LASTEXITCODE)" }
    foreach ($required in @('AppxManifest.xml', 'Assets\StoreLogo.png', 'Assets\Square44x44Logo.png', $ExeName)) {
        if (-not (Test-Path (Join-Path $verifyDir $required))) {
            throw "Unpack verification: missing $required"
        }
    }
    $repackedManifest = Get-Content (Join-Path $verifyDir 'AppxManifest.xml') -Raw
    if ($repackedManifest -notmatch [regex]::Escape($msixVersion)) {
        throw 'Unpack verification: manifest has no version'
    }
    if ($repackedManifest -notmatch 'Windows.FullTrustApplication') {
        throw 'Unpack verification: EntryPoint is not FullTrustApplication'
    }
    Write-Step 'unpack verification passed (manifest / assets / entry exe)'

    # ---- 6. optional signing (local install test only)
    if ($CertPath) {
        if (-not (Test-Path $CertPath)) { throw "Certificate not found: $CertPath" }
        $signtool = Find-SignTool
        if (-not $signtool) { throw 'signtool.exe not found (Windows SDK required); cannot sign' }

        # The certificate subject must equal the manifest Publisher, otherwise
        # installing fails with 0x800B0109 (publisher/signature mismatch).
        $certPathFull = (Resolve-Path $CertPath).Path
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certPathFull, $CertPassword)
        if ($cert.Subject -ne $Publisher) {
            $msg = "Certificate subject does not match -Publisher: cert='$($cert.Subject)' publisher='$Publisher'. " +
                   'Create the self-signed cert with: New-SelfSignedCertificate -Type Custom -Subject "<same Publisher>"'
            throw $msg
        }
        Write-Step "signing with $signtool (subject=$($cert.Subject))"
        & $signtool sign /fd SHA256 /f $certPathFull /p $CertPassword $outFull
        if ($LASTEXITCODE -ne 0) { throw "signtool sign failed (exit $LASTEXITCODE)" }
        & $signtool verify /pa /v $outFull
        # A self-signed chain only passes /pa after the certificate is imported
        # into the local trust store; the Store re-signs, so this is expected.
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'signtool verify /pa failed for the self-signed cert (import it locally to install; the Store re-signs)'
        }
    }
    else {
        Write-Host ''
        Write-Host 'NOTE: unsigned package. The Store re-signs every submission, so this' -ForegroundColor Yellow
        Write-Host '      is the normal output; -CertPath/-CertPassword are for a local' -ForegroundColor Yellow
        Write-Host '      install test only.' -ForegroundColor Yellow
    }

    Write-Step 'DONE'
}
finally {
    if ($KeepLayout) {
        Write-Host "staging kept at $staging"
    }
    elseif (Test-Path $staging) {
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}