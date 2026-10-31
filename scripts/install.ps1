# Install NomadFS on Windows from a GitHub release, for this user:
#   the app          the release's installer, run silently (it installs under
#                    %LOCALAPPDATA%\Programs and adds the Start menu entry)
#   the command line %LOCALAPPDATA%\NomadFS\bin\nomadfs.exe, put on your PATH
#
#   irm https://raw.githubusercontent.com/highercomve/nomadfs/main/scripts/install.ps1 | iex
#   powershell -ExecutionPolicy Bypass -File scripts\install.ps1
#
# Set these first to change what it does (the same names as install.sh):
#   $env:VERSION = '0.3.14'   that release, not the latest
#   $env:NO_RESTART = '1'     leave the app stopped
#   $env:NO_CLI = '1'         skip the command line node
#
# Every file is checked against the release's SHA256SUMS. The app updates
# itself from then on (About > Updates), and the command line with
# `nomadfs --upgrade`. Windows PowerShell 5.1 and PowerShell 7 both run it.

& {
    $ErrorActionPreference = 'Stop'
    # Invoke-WebRequest's progress bar makes downloads many times slower in 5.1.
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $repo = 'https://github.com/highercomve/nomadfs'

    # x64 builds; Windows 11 on ARM runs them too.
    if ($env:PROCESSOR_ARCHITECTURE -notin @('AMD64', 'ARM64')) {
        throw "No NomadFS build for $env:PROCESSOR_ARCHITECTURE Windows"
    }

    # The latest release: where /releases/latest redirects (no API rate limit).
    $version = $env:VERSION
    if (-not $version) {
        $request = [Net.HttpWebRequest]::Create("$repo/releases/latest")
        $request.AllowAutoRedirect = $false
        $request.Method = 'HEAD'
        $response = $request.GetResponse()
        $location = $response.Headers['Location']
        $response.Close()
        $version = ($location -split '/v')[-1]
    }
    $version = $version.TrimStart('v')
    if ($version -notmatch '^\d+\.\d+\.\d+') { throw "Couldn't find the latest release ($version)" }
    $base = "$repo/releases/download/v$version"

    $appFile = "nomadfs-gui-$version-windows-x86_64-setup.exe"
    $cliFile = "nomadfs-$version-x86_64-windows.exe"
    $wantCli = -not $env:NO_CLI

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("nomadfs-install-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Write-Host "Installing NomadFS $version"
        $sums = Join-Path $tmp 'SHA256SUMS'
        Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile $sums
        $expected = @{}
        foreach ($line in Get-Content $sums) {
            $parts = $line -split '\s+', 2
            if ($parts.Count -eq 2) { $expected[$parts[1].TrimStart('*')] = $parts[0].ToLower() }
        }
        function Fetch($name) {
            Write-Host "Downloading $name"
            $path = Join-Path $tmp $name
            Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile $path
            if (-not $expected.ContainsKey($name)) { throw "$name isn't in SHA256SUMS" }
            $got = (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower()
            if ($got -ne $expected[$name]) { throw "$name doesn't match its checksum" }
            $path
        }
        $setup = Fetch $appFile
        $cli = if ($wantCli) { Fetch $cliFile } else { $null }

        # Stop the running app: the installer replaces its files.
        $running = Get-Process -Name 'nomadfs-gui' -ErrorAction SilentlyContinue
        if ($running) {
            Write-Host 'Stopping the running NomadFS'
            $running | Stop-Process -Force
            $running | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
        }

        Write-Host 'Running the installer'
        # The installer alone: -Wait would also wait on an app it starts.
        $installer = Start-Process -FilePath $setup -ArgumentList '/S' -PassThru
        if (-not $installer.WaitForExit(300000)) { $installer.Kill(); throw 'The installer was still running after 5 minutes' }
        if ($installer.ExitCode -ne 0) { throw "The installer failed (exit code $($installer.ExitCode))" }
        $app = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs') -Recurse -Filter 'nomadfs-gui.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $app) { throw "The installer ran, but the app isn't under $env:LOCALAPPDATA\Programs" }
        Write-Host "Installed the app to $($app.DirectoryName)"

        if ($cli) {
            $bin = Join-Path $env:LOCALAPPDATA 'NomadFS\bin'
            New-Item -ItemType Directory -Force -Path $bin | Out-Null
            Copy-Item -Force $cli (Join-Path $bin 'nomadfs.exe')
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            $entries = if ($userPath) { $userPath -split ';' } else { @() }
            if ($entries -notcontains $bin) {
                [Environment]::SetEnvironmentVariable('Path', (($entries + $bin) | Where-Object { $_ }) -join ';', 'User')
                Write-Host "Installed the command line to $bin\nomadfs.exe (on your PATH in new terminals)"
            } else {
                Write-Host "Installed the command line to $bin\nomadfs.exe"
            }
        }

        if (-not $env:NO_RESTART) {
            Start-Process -FilePath $app.FullName
            Write-Host 'Started NomadFS'
        }
        Write-Host "NomadFS $version is installed."
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}
