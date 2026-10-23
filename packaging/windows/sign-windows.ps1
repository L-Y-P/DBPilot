<#
.SYNOPSIS
    DBPilot Windows 代码签名脚本。

.DESCRIPTION
    用 signtool.exe 给 exe / dll / 安装包签名，带 RFC3161 时间戳。

    没有证书时本脚本不做任何事并返回 0 —— CI 里未配置 secrets 的构建
    仍然能出包，只是产物未签名。

.PARAMETER Path
    要签名的文件或目录（目录会递归签 *.exe / *.dll）。

.PARAMETER PfxPath
    .pfx 证书路径。CI 里由 secrets.WINDOWS_CERT_PFX_BASE64 解码得到。

.PARAMETER PfxPassword
    .pfx 密码。

.PARAMETER Thumbprint
    已装在证书存储里的证书指纹（与 PfxPath 二选一）。

.PARAMETER TimestampUrl
    RFC3161 时间戳服务，默认 DigiCert。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$PfxPath,
    [string]$PfxPassword,
    [string]$Thumbprint,
    [string]$TimestampUrl = "http://timestamp.digicert.com"
)

$ErrorActionPreference = "Stop"
$NL = [Environment]::NewLine

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 找 signtool
# Windows SDK 路径随版本变化，用通配找最新的 x64 signtool。
function Find-SignTool {
    $candidates = @()
    $roots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
        "${env:ProgramFiles}\Windows Kits\10\bin"
    )
    foreach ($root in $roots) {
        if (Test-Path $root) {
            $candidates += Get-ChildItem -Path $root -Filter "signtool.exe" -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match "\\x64\\" } |
                Sort-Object FullName -Descending
        }
    }
    if ($candidates.Count -eq 0) {
        $onPath = Get-Command signtool.exe -ErrorAction SilentlyContinue
        if ($onPath) { return $onPath.Source }
        return $null
    }
    return $candidates[0].FullName
}

$signTool = Find-SignTool
if (-not $signTool) {
    Write-Warning "未找到 signtool.exe（需要 Windows SDK）。跳过签名。"
    exit 0
}
Write-Step "signtool: $signTool"

# ---------------------------------------------------------------- 证书准备
$certArgs = @()
if ($PfxPath) {
    if (-not (Test-Path $PfxPath)) {
        Write-Warning "证书文件不存在：$PfxPath。跳过签名。"
        exit 0
    }
    Write-Step "使用 PFX 证书：$PfxPath"
    $certArgs = @("/f", $PfxPath)
    if ($PfxPassword) { $certArgs += @("/p", $PfxPassword) }
}
elseif ($Thumbprint) {
    Write-Step "使用证书存储中的指纹：$Thumbprint"
    $certArgs = @("/sha1", $Thumbprint)
}
else {
    Write-Warning "未提供证书（-PfxPath 或 -Thumbprint）。跳过签名。"
    exit 0
}

# ---------------------------------------------------------------- 收集文件
$targets = @()
if (Test-Path $Path -PathType Container) {
    $targets = Get-ChildItem -Path $Path -Recurse -Include "*.exe", "*.dll" -File |
        Where-Object { $_.Name -notmatch "^api-ms-win-" }   # 系统 API 转发 dll 不能签
}
elseif (Test-Path $Path) {
    $targets = @(Get-Item $Path)
}
else {
    Write-Warning "路径不存在：$Path。跳过签名。"
    exit 0
}

if ($targets.Count -eq 0) {
    Write-Warning "没有可签名的文件。"
    exit 0
}

Write-Step "待签名文件 $($targets.Count) 个"

# ---------------------------------------------------------------- 逐个签名
# /fd SHA256   文件摘要用 SHA-256（Windows 10+ 必须）
# /tr /td      RFC3161 时间戳，证书过期后签名仍然有效
# /as          追加签名（不覆盖已有的）
$failed = @()
foreach ($file in $targets) {
    Write-Host "  - $($file.Name)"
    & $signTool sign /fd SHA256 /tr $TimestampUrl /td SHA256 /as @certArgs $file.FullName 2>&1 |
        ForEach-Object { Write-Host "      $_" }
    if ($LASTEXITCODE -ne 0) { $failed += $file.FullName }
}

# ---------------------------------------------------------------- 校验
Write-Step "校验签名"
$bad = @()
foreach ($file in $targets) {
    & $signTool verify /pa /v $file.FullName *> $null
    if ($LASTEXITCODE -ne 0) { $bad += $file.FullName }
}

if ($failed.Count -gt 0) {
    Write-Error ("签名失败 " + $failed.Count + " 个：" + $NL + ($failed -join $NL))
    exit 1
}
if ($bad.Count -gt 0) {
    Write-Error ("签名校验失败 " + $bad.Count + " 个：" + $NL + ($bad -join $NL))
    exit 1
}

Write-Step "签名完成，全部通过校验（$($targets.Count) 个文件）"
exit 0
