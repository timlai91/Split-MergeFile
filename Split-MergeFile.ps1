#requires -Version 5.1
<#
.SYNOPSIS
    將大型檔案切割成多個分段，或依資訊清單將分段合併回原始檔案。

.DESCRIPTION
    Split 模式可透過 -PartSizeMB 指定每段上限，或透過 -PartCount 指定分段數量。
    切割完成後會建立 JSON 資訊清單，記錄分段順序、大小與原始檔案 SHA-256。
    Join 模式可直接讀取資訊清單並合併，預設會比對 SHA-256。

.EXAMPLE
    .\Split-MergeFile.ps1 -Mode Split -InputPath 'D:\Data\large.iso' -PartSizeMB 200

.EXAMPLE
    .\Split-MergeFile.ps1 -Mode Split -InputPath 'D:\Data\large.iso' -PartCount 5 -OutputDirectory 'D:\Parts'

.EXAMPLE
    .\Split-MergeFile.ps1 -Mode Join -ManifestPath 'D:\Parts\large.iso.parts.json'

.EXAMPLE
    .\Split-MergeFile.ps1 -Mode Join -ManifestPath 'D:\Parts\large.iso.parts.json' -OutputPath 'D:\Restored\large.iso' -Force
#>

[CmdletBinding(DefaultParameterSetName = 'SplitBySize', SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Split', 'Join')]
    [string]$Mode,

    [Parameter(Mandatory, ParameterSetName = 'SplitBySize')]
    [Parameter(Mandatory, ParameterSetName = 'SplitByCount')]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,

    [Parameter(Mandatory, ParameterSetName = 'SplitBySize')]
    [ValidateRange(1, 8796093022207)]
    [long]$PartSizeMB,

    [Parameter(Mandatory, ParameterSetName = 'SplitByCount')]
    [ValidateRange(1, 1000000)]
    [int]$PartCount,

    [Parameter(ParameterSetName = 'SplitBySize')]
    [Parameter(ParameterSetName = 'SplitByCount')]
    [string]$OutputDirectory,

    [Parameter(Mandatory, ParameterSetName = 'Join')]
    [ValidateNotNullOrEmpty()]
    [string]$ManifestPath,

    [Parameter(ParameterSetName = 'Join')]
    [string]$OutputPath,

    [Parameter(ParameterSetName = 'Join')]
    [switch]$SkipHashVerification,

    [switch]$Force,

    [ValidateRange(1, 64)]
    [int]$BufferSizeMB = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

function Copy-ExactBytes {
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Source,
        [Parameter(Mandatory)][System.IO.Stream]$Destination,
        [Parameter(Mandatory)][long]$ByteCount,
        [Parameter(Mandatory)][byte[]]$Buffer,
        [long]$ProgressBase = 0,
        [long]$ProgressTotal = 0,
        [string]$Activity = '處理檔案'
    )

    [long]$remaining = $ByteCount
    [long]$copied = 0
    while ($remaining -gt 0) {
        $toRead = [int][Math]::Min([long]$Buffer.Length, $remaining)
        $read = $Source.Read($Buffer, 0, $toRead)
        if ($read -le 0) { throw "來源檔案提前結束，尚缺 $remaining 位元組。" }
        $Destination.Write($Buffer, 0, $read)
        $remaining -= $read
        $copied += $read

        if ($ProgressTotal -gt 0) {
            $done = $ProgressBase + $copied
            $percent = [Math]::Min(100, [int](($done * 100.0) / $ProgressTotal))
            Write-Progress -Activity $Activity -Status "$percent%" -PercentComplete $percent
        }
    }
}

function Invoke-SplitFile {
    $sourcePath = Resolve-FullPath $InputPath
    if (-not [System.IO.File]::Exists($sourcePath)) { throw "找不到輸入檔案：$sourcePath" }

    $sourceInfo = [System.IO.FileInfo]::new($sourcePath)
    if ($sourceInfo.Length -eq 0) { throw '不支援切割 0 位元組的空檔案。' }

    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $destDir = $sourceInfo.DirectoryName
    } else {
        $destDir = Resolve-FullPath $OutputDirectory
    }
    [System.IO.Directory]::CreateDirectory($destDir) | Out-Null

    if ($PSCmdlet.ParameterSetName -eq 'SplitBySize') {
        [long]$partBytes = $PartSizeMB * 1MB
        [int]$actualCount = [int][Math]::Ceiling($sourceInfo.Length / [double]$partBytes)
    } else {
        if ($PartCount -gt $sourceInfo.Length) {
            throw "分段數量不可大於檔案位元組數；此檔案最多可切成 $($sourceInfo.Length) 段。"
        }
        [int]$actualCount = $PartCount
        [long]$partBytes = [long][Math]::Ceiling($sourceInfo.Length / [double]$PartCount)
    }

    $digits = [Math]::Max(3, $actualCount.ToString().Length)
    $manifestPath = Join-Path $destDir ($sourceInfo.Name + '.parts.json')
    $plannedPaths = for ($i = 1; $i -le $actualCount; $i++) {
        Join-Path $destDir (('{0}.part{1}' -f $sourceInfo.Name, $i.ToString("D$digits")))
    }

    $collisions = @($plannedPaths + $manifestPath | Where-Object { [System.IO.File]::Exists($_) })
    if ($collisions.Count -gt 0 -and -not $Force) {
        throw "輸出檔案已存在。請改用其他目錄，或加上 -Force。第一個衝突：$($collisions[0])"
    }

    if (-not $PSCmdlet.ShouldProcess($sourcePath, "切割為 $actualCount 個分段至 $destDir")) { return }

    [byte[]]$buffer = New-Object byte[] ($BufferSizeMB * 1MB)
    $parts = [System.Collections.Generic.List[object]]::new()
    $inputStream = $null
    try {
        $inputStream = [System.IO.File]::Open($sourcePath, 'Open', 'Read', 'Read')
        [long]$processed = 0
        for ($i = 1; $i -le $actualCount; $i++) {
            if ($PSCmdlet.ParameterSetName -eq 'SplitByCount') {
                [long]$baseSize = [Math]::Floor($sourceInfo.Length / [double]$actualCount)
                [long]$extra = $sourceInfo.Length % $actualCount
                [long]$thisSize = $baseSize + $(if ($i -le $extra) { 1 } else { 0 })
            } else {
                [long]$thisSize = [Math]::Min($partBytes, $sourceInfo.Length - $processed)
            }

            $partPath = $plannedPaths[$i - 1]
            $outputStream = $null
            try {
                $outputStream = [System.IO.File]::Open($partPath, 'Create', 'Write', 'None')
                Copy-ExactBytes -Source $inputStream -Destination $outputStream -ByteCount $thisSize `
                    -Buffer $buffer -ProgressBase $processed -ProgressTotal $sourceInfo.Length `
                    -Activity "正在切割 $($sourceInfo.Name)"
            } finally {
                if ($null -ne $outputStream) { $outputStream.Dispose() }
            }

            $parts.Add([ordered]@{
                Index = $i
                FileName = [System.IO.Path]::GetFileName($partPath)
                Length = $thisSize
            })
            $processed += $thisSize
        }
    } catch {
        foreach ($path in $plannedPaths) {
            if ([System.IO.File]::Exists($path)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
        throw
    } finally {
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        Write-Progress -Activity "正在切割 $($sourceInfo.Name)" -Completed
    }

    Write-Verbose '正在計算原始檔案 SHA-256...'
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    $manifest = [ordered]@{
        SchemaVersion = 1
        OriginalFileName = $sourceInfo.Name
        OriginalLength = $sourceInfo.Length
        SHA256 = $sourceHash
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        PartCount = $actualCount
        Parts = $parts
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    [pscustomobject]@{
        Mode = 'Split'
        Source = $sourcePath
        OutputDirectory = $destDir
        Manifest = $manifestPath
        PartCount = $actualCount
        OriginalBytes = $sourceInfo.Length
        SHA256 = $sourceHash
    }
}

function Invoke-JoinFile {
    $resolvedManifest = Resolve-FullPath $ManifestPath
    if (-not [System.IO.File]::Exists($resolvedManifest)) { throw "找不到資訊清單：$resolvedManifest" }

    $manifest = Get-Content -LiteralPath $resolvedManifest -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($property in 'OriginalFileName', 'OriginalLength', 'SHA256', 'PartCount', 'Parts') {
        if ($null -eq $manifest.$property) { throw "資訊清單缺少必要欄位：$property" }
    }

    $manifestDir = [System.IO.Path]::GetDirectoryName($resolvedManifest)
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $targetPath = Join-Path $manifestDir ([string]$manifest.OriginalFileName)
    } else {
        $targetPath = Resolve-FullPath $OutputPath
    }

    $targetDir = [System.IO.Path]::GetDirectoryName($targetPath)
    [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null
    if ([System.IO.File]::Exists($targetPath) -and -not $Force) {
        throw "輸出檔案已存在：$targetPath。若要覆寫，請加上 -Force。"
    }

    $orderedParts = @($manifest.Parts | Sort-Object {[int]$_.Index})
    if ($orderedParts.Count -ne [int]$manifest.PartCount) {
        throw "資訊清單的分段數量不一致：預期 $($manifest.PartCount)，實際 $($orderedParts.Count)。"
    }

    [long]$sumLength = 0
    foreach ($part in $orderedParts) {
        $partPath = Join-Path $manifestDir ([string]$part.FileName)
        if (-not [System.IO.File]::Exists($partPath)) { throw "缺少分段檔案：$partPath" }
        $actualLength = ([System.IO.FileInfo]::new($partPath)).Length
        if ($actualLength -ne [long]$part.Length) {
            throw "分段大小不符：$partPath，預期 $($part.Length)，實際 $actualLength。"
        }
        $sumLength += $actualLength
    }
    if ($sumLength -ne [long]$manifest.OriginalLength) {
        throw "所有分段的總大小與原始檔案大小不符。"
    }

    if (-not $PSCmdlet.ShouldProcess($targetPath, "合併 $($orderedParts.Count) 個分段")) { return }

    [byte[]]$buffer = New-Object byte[] ($BufferSizeMB * 1MB)
    $outputStream = $null
    try {
        $outputStream = [System.IO.File]::Open($targetPath, 'Create', 'Write', 'None')
        [long]$processed = 0
        foreach ($part in $orderedParts) {
            $partPath = Join-Path $manifestDir ([string]$part.FileName)
            $inputStream = $null
            try {
                $inputStream = [System.IO.File]::Open($partPath, 'Open', 'Read', 'Read')
                Copy-ExactBytes -Source $inputStream -Destination $outputStream -ByteCount ([long]$part.Length) `
                    -Buffer $buffer -ProgressBase $processed -ProgressTotal ([long]$manifest.OriginalLength) `
                    -Activity "正在合併 $($manifest.OriginalFileName)"
            } finally {
                if ($null -ne $inputStream) { $inputStream.Dispose() }
            }
            $processed += [long]$part.Length
        }
    } catch {
        if ($null -ne $outputStream) { $outputStream.Dispose(); $outputStream = $null }
        if ([System.IO.File]::Exists($targetPath)) { Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue }
        throw
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        Write-Progress -Activity "正在合併 $($manifest.OriginalFileName)" -Completed
    }

    $verified = $null
    $actualHash = $null
    if (-not $SkipHashVerification) {
        Write-Verbose '正在驗證合併檔案 SHA-256...'
        $actualHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
        $verified = $actualHash -eq [string]$manifest.SHA256
        if (-not $verified) {
            Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
            throw "SHA-256 驗證失敗，已刪除不完整的輸出檔案。預期：$($manifest.SHA256)，實際：$actualHash"
        }
    }

    [pscustomobject]@{
        Mode = 'Join'
        Manifest = $resolvedManifest
        Output = $targetPath
        Bytes = ([System.IO.FileInfo]::new($targetPath)).Length
        HashVerified = $verified
        SHA256 = $actualHash
    }
}

if ($Mode -eq 'Split') {
    if ($PSCmdlet.ParameterSetName -eq 'Join') { throw 'Split 模式請使用 -InputPath 搭配 -PartSizeMB 或 -PartCount。' }
    Invoke-SplitFile
} else {
    if ($PSCmdlet.ParameterSetName -ne 'Join') { throw 'Join 模式請使用 -ManifestPath。' }
    Invoke-JoinFile
}
