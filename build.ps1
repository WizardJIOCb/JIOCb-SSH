[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$version = '20240203-110809-5046fc22'
$release = "WezTerm-windows-$version"
$expectedHash = '57e5d03b585303d81e8b8e96d1230362852eb39aca92b3b29c7a42cfb82f9ac4'
$runtime = Join-Path $PSScriptRoot 'runtime'

if (-not (Test-Path -LiteralPath (Join-Path $runtime 'wezterm-gui.exe'))) {
    $scratch = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N')))
    try {
        $archive = Join-Path $scratch.FullName "$release.zip"
        $uri = "https://github.com/wezterm/wezterm/releases/download/$version/$release.zip"
        Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $archive
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expectedHash) {
            throw 'Unexpected SHA256 for WezTerm.'
        }
        Expand-Archive -LiteralPath $archive -DestinationPath $scratch.FullName
        $unpacked = Join-Path $scratch.FullName $release
        Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/wezterm/wezterm/$version/LICENSE.md" -OutFile (Join-Path $unpacked 'LICENSE.md')
        [IO.Directory]::Move($unpacked, $runtime)
    }
    finally {
        if ($scratch.Parent.FullName -eq ([IO.Path]::GetTempPath()).TrimEnd('\') -and $scratch.Name -match '^[0-9a-f]{32}$') {
            Remove-Item -LiteralPath $scratch.FullName -Recurse -Force
        }
    }
}

Push-Location -LiteralPath $PSScriptRoot
try {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:winexe /optimize+ /codepage:65001 /win32icon:los.ico '/out:Лось SSH.exe' /reference:System.Windows.Forms.dll Launcher.cs
    if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed.' }
    Get-Item -LiteralPath 'Лось SSH.exe' | Select-Object -ExpandProperty FullName
}
finally { Pop-Location }
