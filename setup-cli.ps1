#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Interactive TUI for developer machine setup.

.DESCRIPTION
    Arrow-key menu, checkbox tool picker, spinners during install.
    Reads base.json / personal.json and installs via Chocolatey → winget → fallback URL.

.PARAMETER Config
    Path to a JSON config file. Defaults to personal.json next to this script,
    then falls back to base.json.

.PARAMETER DryRun
    Preview what would be installed without installing anything.

.PARAMETER SkipChoco
    Skip Chocolatey entirely and go straight to winget.

.EXAMPLE
    .\setup-cli.ps1
    .\setup-cli.ps1 -DryRun
    .\setup-cli.ps1 -Config personal.json
    .\setup-cli.ps1 -Config \\shared\dotfiles\base.json
#>

param(
    [string]$Config   = "",
    [switch]$DryRun,
    [switch]$SkipChoco
)

# ══════════════════════════════════════════════════════════════════════════════
# 1 · Bootstrap — UTF-8, window title, ANSI on Windows PowerShell 5.x
# ══════════════════════════════════════════════════════════════════════════════

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = "  Dev Setup"
$ESC = [char]27

if ($PSVersionTable.PSVersion.Major -lt 6) {
    try {
        $sig = '[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);' +
               '[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);' +
               '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h);'
        $k = Add-Type -MemberDefinition $sig -Name "K32" -Namespace "ANSI" -PassThru -EA SilentlyContinue
        if ($k) {
            $handle = $k::GetStdHandle(-11); $mode = 0
            $k::GetConsoleMode($handle, [ref]$mode) | Out-Null
            $k::SetConsoleMode($handle, ($mode -bor 4)) | Out-Null
        }
    } catch {}
}

# ══════════════════════════════════════════════════════════════════════════════
# 2 · Colour palette (true-colour ANSI)
# ══════════════════════════════════════════════════════════════════════════════

function col([string]$c) { return "$ESC[${c}m" }

$CY  = col "38;2;0;210;210"     # Cyan       — primary
$TC  = col "38;2;0;150;160"     # Teal       — dim accent / box borders
$GN  = col "38;2;80;220;100"    # Green      — success
$YL  = col "38;2;255;210;0"     # Yellow     — warning / manual
$RD  = col "38;2;255;80;80"     # Red        — error
$WH  = col "38;2;220;220;220"   # White      — normal text
$GR  = col "38;2;100;100;110"   # Gray       — subdued
$BD  = col "1"                   # Bold
$RS  = col "0"                   # Reset

# ══════════════════════════════════════════════════════════════════════════════
# 3 · Cursor utilities
# ══════════════════════════════════════════════════════════════════════════════

function Hide-Cursor  { [Console]::Write("$ESC[?25l") }
function Show-Cursor  { [Console]::Write("$ESC[?25h") }
function Move-Up([int]$n = 1) {
    [Console]::SetCursorPosition(0, [Math]::Max(0, [Console]::CursorTop - $n))
}

# Restore cursor if the script exits unexpectedly
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Show-Cursor }

# ══════════════════════════════════════════════════════════════════════════════
# 4 · Banner
# ══════════════════════════════════════════════════════════════════════════════

function Write-Typewriter {
    param([string]$Text, [int]$DelayMs = 18)
    foreach ($ch in $Text.ToCharArray()) {
        [Console]::Write($ch)
        [System.Threading.Thread]::Sleep($DelayMs)
    }
    [Console]::WriteLine()
}

function Show-Banner {
    Clear-Host
    $lines = @(
        ""
        "  ${TC}┌──────────────────────────────────────────────────────┐${RS}"
        "  ${TC}│${RS}                                                      ${TC}│${RS}"
        "  ${TC}│${RS}  ${BD}${CY} ██████╗ ███████╗██╗   ██╗${RS}                        ${TC}│${RS}"
        "  ${TC}│${RS}  ${CY} ██╔══██╗██╔════╝██║   ██║${RS}                        ${TC}│${RS}"
        "  ${TC}│${RS}  ${CY} ██║  ██║█████╗  ██║   ██║${RS}  ${BD}${WH}S E T U P${RS}              ${TC}│${RS}"
        "  ${TC}│${RS}  ${CY} ██║  ██║██╔══╝  ╚██╗ ██╔╝${RS}  ${GR}Developer Environment${RS}  ${TC}│${RS}"
        "  ${TC}│${RS}  ${CY} ██████╔╝███████╗ ╚████╔╝ ${RS}                        ${TC}│${RS}"
        "  ${TC}│${RS}  ${CY} ╚═════╝ ╚══════╝  ╚═══╝  ${RS}                        ${TC}│${RS}"
        "  ${TC}│${RS}                                                      ${TC}│${RS}"
    )
    foreach ($line in $lines) {
        Write-Host $line
        [System.Threading.Thread]::Sleep(35)
    }
    if ($DryRun) {
        Write-Host "  ${TC}│${RS}  ${YL}  [!]  DRY RUN - nothing will be installed${RS}          ${TC}│${RS}"
        Write-Host "  ${TC}│${RS}                                                      ${TC}│${RS}"
    }
    Write-Host "  ${TC}└──────────────────────────────────────────────────────┘${RS}"
    Write-Host ""
}

# ══════════════════════════════════════════════════════════════════════════════
# ══════════════════════════════════════════════════════════════════════════════
# 5 · Arrow-key menu
# ══════════════════════════════════════════════════════════════════════════════

function Show-Menu {
    param([string]$Title, [object[]]$Options)
    # Each entry in $Options may be:
    #   A non-empty string           → selectable item
    #   An empty string ("")         → blank spacer  (non-selectable)
    #   @{ Header = "Section name" } → section header (non-selectable, styled)

    # Build ordered list of row indices that are actually selectable
    $selectableRows = [System.Collections.Generic.List[int]]::new()
    for ($r = 0; $r -lt $Options.Count; $r++) {
        $item     = $Options[$r]
        $isHeader = ($item -is [hashtable] -and $item.ContainsKey('Header'))
        $isSpacer = ($item -is [string]    -and $item -eq '')
        if (-not $isHeader -and -not $isSpacer) { $selectableRows.Add($r) }
    }

    function Render-Header([string]$h) {
        $fill = [Math]::Max(0, 50 - $h.Length)
        "  ${TC}── $h $('─' * $fill)${RS}"
    }

    Write-Host "  ${GR}$Title${RS}"
    Write-Host ""

    # Prime lines so Move-Up math is correct on first redraw
    foreach ($opt in $Options) {
        $isHeader = ($opt -is [hashtable] -and $opt.ContainsKey('Header'))
        $isSpacer = ($opt -is [string]    -and $opt -eq '')
        if      ($isSpacer)  { Write-Host "" }
        elseif  ($isHeader)  { Write-Host (Render-Header $opt.Header) }
        else                 { Write-Host "    $opt" }
    }
    Write-Host ""
    Write-Host "    "   # placeholder for key-hint line

    $selIdx = 0
    Hide-Cursor

    while ($true) {
        Move-Up ($Options.Count + 2)

        for ($r = 0; $r -lt $Options.Count; $r++) {
            $item       = $Options[$r]
            $isHeader   = ($item -is [hashtable] -and $item.ContainsKey('Header'))
            $isSpacer   = ($item -is [string]    -and $item -eq '')
            $isSelected = (-not $isHeader -and -not $isSpacer -and $selectableRows[$selIdx] -eq $r)

            if      ($isSpacer)    { Write-Host (" " * 60) }
            elseif  ($isHeader)    { Write-Host ((Render-Header $item.Header) + "   ") }
            elseif  ($isSelected)  { Write-Host "  ${CY}▶${RS}  ${BD}${WH}$item${RS}   " }
            else                   { Write-Host "  ${GR}   $item${RS}   " }
        }

        Write-Host ""
        Write-Host "  ${GR}↑↓ move  ·  Enter select  ·  Home/End jump  ·  Esc exit${RS}   "

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { $selIdx = if ($selIdx -gt 0) { $selIdx - 1 } else { $selectableRows.Count - 1 } }
            'DownArrow' { $selIdx = if ($selIdx -lt $selectableRows.Count - 1) { $selIdx + 1 } else { 0 } }
            'Home'      { $selIdx = 0 }
            'End'       { $selIdx = $selectableRows.Count - 1 }
            'Enter'     { Show-Cursor; Write-Host ""; return $selIdx }
            'Escape'    { Show-Cursor; return -1 }
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# 6 · Checkbox tool picker
#     ↑↓ navigate · Space toggle · A select all · N deselect all · Enter confirm
# ══════════════════════════════════════════════════════════════════════════════

function Show-Checklist {
    param([object[]]$Tools)

    $checked = @($Tools | ForEach-Object { $true })   # all selected by default
    $cursor  = 0

    # Max usable width — leave margin so lines never wrap
    $maxWidth = [Math]::Max(40, [Console]::WindowWidth - 4)

    function Format-Row([int]$i, [bool]$isCursor, [bool]$isChecked) {
        $box   = if ($isChecked) { "${GN}[x]${RS}" } else { "${GR}[ ]${RS}" }
        $arrow = if ($isCursor)  { "${CY}>${RS}" } else { " " }
        $name  = $Tools[$i].name
        $desc  = $Tools[$i].description
        # Build visible text to measure length (strip ANSI for width calc)
        $visiblePrefix = "  $arrow $box  $name  -  "
        $descAllowed   = $maxWidth - ($visiblePrefix -replace '\x1b\[[0-9;]*m','').Length
        if ($descAllowed -lt 0) { $desc = "" }
        elseif ($desc.Length -gt $descAllowed) { $desc = $desc.Substring(0, $descAllowed) }
        $label = if ($isCursor) { "${BD}${WH}${name}${RS}" } else { "${WH}${name}${RS}" }
        # Pad to fixed width so old text is overwritten
        $line  = "  $arrow $box  $label  ${GR}-  $desc${RS}"
        $pad   = $maxWidth - ($line -replace '\x1b\[[0-9;]*m','').Length
        return $line + (' ' * [Math]::Max(0, $pad))
    }

    Write-Host "  ${GR}${WH}↑↓${GR} move  ·  ${WH}Space${GR} toggle  ·  ${WH}A${GR}/${WH}N${GR} all/none  ·  ${WH}Enter${GR} confirm${RS}"
    Write-Host ""

    # Prime the lines so move-up works on first render
    foreach ($t in $Tools) { Write-Host "    $($t.name)" }
    Write-Host ""
    Write-Host "    "

    Hide-Cursor

    while ($true) {
        Move-Up ($Tools.Count + 2)

        for ($i = 0; $i -lt $Tools.Count; $i++) {
            Write-Host (Format-Row $i ($i -eq $cursor) $checked[$i])
        }

        Write-Host ""
        $count = ($checked | Where-Object { $_ }).Count
        $statusLine = "  ${GR}$count of $($Tools.Count) selected${RS}"
        $statusPad  = $maxWidth - ($statusLine -replace '\x1b\[[0-9;]*m','').Length
        Write-Host ($statusLine + (' ' * [Math]::Max(0, $statusPad))) -NoNewline

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { if ($cursor -gt 0) { $cursor-- } }
            'DownArrow' { if ($cursor -lt $Tools.Count - 1) { $cursor++ } }
            'Spacebar'  { $checked[$cursor] = -not $checked[$cursor] }
            'A'         { 0..($checked.Length - 1) | ForEach-Object { $checked[$_] = $true } }
            'N'         { 0..($checked.Length - 1) | ForEach-Object { $checked[$_] = $false } }
            'Enter' {
                Show-Cursor; Write-Host ""; Write-Host ""
                $result = for ($i = 0; $i -lt $Tools.Count; $i++) {
                    if ($checked[$i]) { $Tools[$i] }
                }
                return @($result)
            }
            'Escape'    { Show-Cursor; return @() }
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# 7 · Spinner (runs in a separate runspace so it animates during blocking ops)
# ══════════════════════════════════════════════════════════════════════════════

function Start-Spinner {
    param([string]$Label)

    $stopEvt = [System.Threading.ManualResetEventSlim]::new($false)
    $rs      = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    $null = $ps.AddScript({
        param([string]$lbl, [System.Threading.ManualResetEventSlim]$stop)
        $e  = [char]27
        $cy = "${e}[38;2;0;210;210m"
        $gr = "${e}[38;2;100;100;110m"
        $rs = "${e}[0m"
        $frames = [char[]]@(0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F)
        $i = 0
        while (-not $stop.IsSet) {
            $f = $frames[$i % $frames.Length]
            [Console]::Write("`r  ${cy}${f}${rs}  ${gr}${lbl}...${rs}   ")
            $i++
            [System.Threading.Thread]::Sleep(80)
        }
        [Console]::Write("`r" + (' ' * ($lbl.Length + 20)) + "`r")
    }).AddArgument($Label).AddArgument($stopEvt)

    $handle = $ps.BeginInvoke()
    return [PSCustomObject]@{ Stop = $stopEvt; PS = $ps; RS = $rs; Handle = $handle }
}

function Stop-Spinner([object]$Spinner) {
    $Spinner.Stop.Set()
    try { $Spinner.PS.EndInvoke($Spinner.Handle) | Out-Null } catch {}
    $Spinner.PS.Dispose()
    $Spinner.RS.Close()
}

# ══════════════════════════════════════════════════════════════════════════════
# 8 · Config loader — resolves "extends" chain and merges tool lists
# ══════════════════════════════════════════════════════════════════════════════

function Resolve-Config {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Host ""
        Write-Host "  ${RD}✗  Config file not found: $Path${RS}"
        exit 1
    }

    $cfg = Get-Content $Path -Raw | ConvertFrom-Json

    if ($cfg.extends) {
        $parentPath = $cfg.extends
        if (-not [IO.Path]::IsPathRooted($parentPath)) {
            $parentPath = Join-Path (Split-Path $Path -Parent) $parentPath
        }

        $parent = Resolve-Config $parentPath

        # Merge: base tools first, personal tools overlay (same name wins)
        $merged = [Collections.Generic.List[object]]::new()
        foreach ($t in $parent.tools) { if ($t.name) { $merged.Add($t) } }
        foreach ($t in $cfg.tools) {
            if (-not $t.name) { continue }
            $existing = $merged | Where-Object { $_.name -eq $t.name }
            if ($existing) {
                $merged[$merged.IndexOf($existing)] = $t
            } else {
                $merged.Add($t)
            }
        }

        return [PSCustomObject]@{
            settings = if ($cfg.settings) { $cfg.settings } else { $parent.settings }
            tools    = $merged
        }
    }

    return $cfg
}

# ══════════════════════════════════════════════════════════════════════════════
# 9 · Install helpers
# ══════════════════════════════════════════════════════════════════════════════

function Test-Installed([string]$Cmd) {
    try { $null = Invoke-Expression $Cmd 2>&1; return $true } catch { return $false }
}

function Install-Chocolatey {
    if ($DryRun) { return $false }
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                    [Environment]::GetEnvironmentVariable("Path","User")
        return (Get-Command choco -EA SilentlyContinue) -ne $null
    } catch { return $false }
}

function Install-Tool {
    param([object]$Tool, [bool]$UseChoco, [bool]$ChocoOK, [bool]$WingetOK)

    if ($DryRun) { return [PSCustomObject]@{ Status = "dryrun" } }

    # ① Chocolatey
    if ($UseChoco -and $ChocoOK -and $Tool.choco) {
        try {
            $null = choco install $Tool.choco -y --no-progress 2>&1
            if ($LASTEXITCODE -eq 0) { return [PSCustomObject]@{ Status = "ok"; Via = "Chocolatey" } }
        } catch {}
    }

    # ② winget
    if ($WingetOK -and $Tool.winget) {
        try {
            $null = winget install --id $Tool.winget -e --accept-source-agreements --accept-package-agreements 2>&1
            if ($LASTEXITCODE -eq 0) { return [PSCustomObject]@{ Status = "ok"; Via = "winget" } }
        } catch {}
    }

    # ③ Manual fallback
    return [PSCustomObject]@{ Status = "manual"; Url = $Tool.fallbackUrl }
}

# ══════════════════════════════════════════════════════════════════════════════
# 10 · Summary screen
# ══════════════════════════════════════════════════════════════════════════════

function Show-Summary {
    param(
        [string[]]  $AlreadyInstalled,
        [object[]]  $Installed,
        [object[]]  $ManualRequired,
        [string[]]  $Failed,
        [object[]]  $DryRunTools
    )

    $div = "  ${TC}$(('─') * 56)${RS}"

    Write-Host ""
    Write-Host $div
    Write-Host ""

    if ($DryRunTools.Count -gt 0) {
        Write-Host "  ${BD}${YL}Would install${RS}"
        foreach ($t in $DryRunTools) {
            Write-Host "  ${YL}  ◌  $($t.name)${RS}  ${GR}$($t.description)${RS}"
        }
        Write-Host ""
    }

    if ($AlreadyInstalled.Count -gt 0) {
        Write-Host "  ${BD}${GR}Already installed${RS}"
        foreach ($n in $AlreadyInstalled) {
            Write-Host "  ${GR}  ✓  $n${RS}"
        }
        Write-Host ""
    }

    if ($Installed.Count -gt 0) {
        Write-Host "  ${BD}${GN}Newly installed${RS}"
        foreach ($r in $Installed) {
            $via = "${GR}via $($r.Via)${RS}"
            Write-Host "  ${GN}  ✓  $($r.Name)${RS}  $via"
        }
        Write-Host ""
    }

    if ($ManualRequired.Count -gt 0) {
        Write-Host "  ${BD}${YL}Manual install required${RS}"
        foreach ($r in $ManualRequired) {
            Write-Host "  ${YL}  !  $($r.Name)${RS}"
            Write-Host "  ${GR}       → $($r.Url)${RS}"
        }
        Write-Host ""
    }

    if ($Failed.Count -gt 0) {
        Write-Host "  ${BD}${RD}Failed${RS}"
        foreach ($n in $Failed) {
            Write-Host "  ${RD}  ✗  $n${RS}"
        }
        Write-Host ""
    }

    Write-Host $div
    Write-Host ""

    if ($Installed.Count -gt 0 -or $ManualRequired.Count -gt 0) {
        Write-Host "  ${GR}Some tools may need a new terminal session to appear on PATH.${RS}"
        Write-Host ""
    }

    $total   = $AlreadyInstalled.Count + $Installed.Count + $ManualRequired.Count + $Failed.Count + $DryRunTools.Count
    $summary = "  ${GR}Done. $total tool$(if ($total -ne 1) {'s'}) processed."
    if (-not $DryRun -and $Installed.Count -gt 0) { $summary += "  ${GN}$($Installed.Count) installed." }
    if ($ManualRequired.Count -gt 0) { $summary += "  ${YL}$($ManualRequired.Count) need manual steps." }
    $summary += "${RS}"
    Write-Host $summary
    Write-Host ""
}

# ══════════════════════════════════════════════════════════════════════════════
# 11 · Snapshot
# ══════════════════════════════════════════════════════════════════════════════

$CommonDevTools = @(
    # Editors & IDEs
    @{ name="Visual Studio 2022";   description="Microsoft IDE";                      checkCommand="& 'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\devenv.exe' /?"; choco="visualstudio2022community"; winget="Microsoft.VisualStudio.2022.Community" }
    @{ name="Rider";                description="JetBrains .NET IDE";                 checkCommand="rider64 --version";               choco="jetbrains-rider";        winget="JetBrains.Rider" }
    @{ name="WebStorm";             description="JetBrains JS IDE";                   checkCommand="webstorm64 --version";             choco="webstorm";               winget="JetBrains.WebStorm" }
    @{ name="IntelliJ IDEA";        description="JetBrains Java IDE";                 checkCommand="idea64 --version";                 choco="intellijidea-community";  winget="JetBrains.IntelliJIDEA.Community" }
    @{ name="Notepad++";            description="Lightweight text editor";            checkCommand="notepad++ --version";              choco="notepadplusplus";        winget="Notepad++.Notepad++" }
    @{ name="Sublime Text";         description="Sophisticated text editor";          checkCommand="subl --version";                   choco="sublimetext4";           winget="SublimeHQ.SublimeText.4" }
    @{ name="Neovim";               description="Hyperextensible Vim-based editor";   checkCommand="nvim --version";                   choco="neovim";                 winget="Neovim.Neovim" }
    # Version control
    @{ name="Fork";                 description="Git client";                         checkCommand="fork --version";                   choco="fork";                   winget="Fork.Fork" }
    @{ name="GitHub Desktop";       description="GitHub GUI client";                  checkCommand="Test-Path ""$env:LOCALAPPDATA\GitHubDesktop\GitHubDesktop.exe""";  choco="github-desktop";         winget="GitHub.GitHubDesktop" }
    @{ name="GitKraken";            description="Cross-platform Git client";          checkCommand="Test-Path ""$env:LOCALAPPDATA\gitkraken\Update.exe""";  choco="gitkraken";              winget="Axosoft.GitKraken" }
    @{ name="Sourcetree";           description="Atlassian Git client";               checkCommand="Test-Path ""$env:LOCALAPPDATA\SourceTree\SourceTree.exe""";  choco="sourcetree";             winget="Atlassian.Sourcetree" }
    # Terminals & shells
    @{ name="Windows Terminal";     description="Modern terminal for Windows";        checkCommand="Get-AppxPackage Microsoft.WindowsTerminal -EA SilentlyContinue";  choco="microsoft-windows-terminal"; winget="Microsoft.WindowsTerminal" }
    @{ name="Oh My Posh";           description="Prompt theme engine";                checkCommand="oh-my-posh --version";             choco="oh-my-posh";             winget="JanDeDobbeleer.OhMyPosh" }
    @{ name="PowerShell 7";         description="Cross-platform PowerShell";          checkCommand="pwsh --version";                   choco="powershell-core";        winget="Microsoft.PowerShell" }
    # Browsers
    @{ name="Google Chrome";        description="Web browser";                        checkCommand="& 'C:\Program Files\Google\Chrome\Application\chrome.exe' --version"; choco="googlechrome"; winget="Google.Chrome" }
    @{ name="Firefox";              description="Mozilla web browser";                checkCommand="& 'C:\Program Files\Mozilla Firefox\firefox.exe' --version"; choco="firefox"; winget="Mozilla.Firefox" }
    @{ name="Arc";                  description="Arc browser";                        checkCommand="& ""$env:LOCALAPPDATA\Arc\app-*\Arc.exe"" --version"; choco=""; winget="TheBrowserCompany.Arc" }
    # API & HTTP tools
    @{ name="Postman";              description="API testing platform";               checkCommand="postman --version";                choco="postman";                winget="Postman.Postman" }
    @{ name="Insomnia";             description="API client";                         checkCommand="insomnia --version";               choco="insomnia-rest-api-client"; winget="Kong.Insomnia" }
    @{ name="Bruno";                description="Offline API client";                 checkCommand="bru --version";                    choco="bruno";                  winget="Bruno.Bruno" }
    # Databases
    @{ name="pgAdmin";              description="PostgreSQL admin tool";              checkCommand="& ""$env:ProgramFiles\pgAdmin 4\runtime\pgAdmin4.exe"" --version"; choco="pgadmin4"; winget="PostgreSQL.pgAdmin" }
    @{ name="DBeaver";              description="Universal database tool";            checkCommand="dbeaver --version";                choco="dbeaver";                winget="dbeaver.dbeaver" }
    @{ name="TablePlus";            description="Database GUI";                       checkCommand="Test-Path ""$env:APPDATA\TablePlus\TablePlus.exe""";  choco="tableplus";              winget="TablePlus.TablePlus" }
    @{ name="Azure Data Studio";    description="Data management tool";              checkCommand="azuredatastudio --version";         choco="azure-data-studio";      winget="Microsoft.AzureDataStudio" }
    @{ name="Redis Insight";        description="Redis GUI";                          checkCommand="Test-Path ""$env:APPDATA\RedisInsight\RedisInsight.exe""";  choco="redisinsight";           winget="Redis.RedisInsight" }
    # Cloud & DevOps
    @{ name="AWS CLI";              description="Amazon Web Services CLI";            checkCommand="aws --version";                    choco="awscli";                 winget="Amazon.AWSCLI" }
    @{ name="Terraform";            description="Infrastructure as code tool";        checkCommand="terraform --version";              choco="terraform";              winget="Hashicorp.Terraform" }
    @{ name="Helm";                 description="Kubernetes package manager";         checkCommand="helm version";                     choco="kubernetes-helm";        winget="Helm.Helm" }
    @{ name="Azure Functions Core"; description="Azure Functions local runtime";      checkCommand="func --version";                   choco="azure-functions-core-tools"; winget="Microsoft.Azure.FunctionsCoreTools" }
    # Runtimes & SDKs
    @{ name="Java (JDK)";           description="Java Development Kit";               checkCommand="java --version";                   choco="microsoft-openjdk";      winget="Microsoft.OpenJDK.21" }
    @{ name="Go";                   description="Go programming language";            checkCommand="go version";                       choco="golang";                 winget="GoLang.Go" }
    @{ name="Rust";                 description="Rust programming language";          checkCommand="rustc --version";                  choco="rust";                   winget="Rustlang.Rust.MSVC" }
    @{ name="Ruby";                 description="Ruby programming language";          checkCommand="ruby --version";                   choco="ruby";                   winget="RubyInstallerTeam.Ruby.3.3" }
    @{ name="PHP";                  description="PHP scripting language";             checkCommand="php --version";                    choco="php";                    winget="PHP.PHP" }
    # Package managers & build tools
    @{ name="pnpm";                 description="Fast Node package manager";          checkCommand="pnpm --version";                   choco="pnpm";                   winget="pnpm.pnpm" }
    @{ name="Yarn";                 description="Node package manager";               checkCommand="yarn --version";                   choco="yarn";                   winget="Yarn.Yarn" }
    @{ name="Make";                 description="Build automation tool";              checkCommand="make --version";                   choco="make";                   winget="GnuWin32.Make" }
    # Design
    @{ name="Figma";                description="Collaborative design tool";          checkCommand="figma --version";                  choco="figma";                  winget="Figma.Figma" }
    # Security & credentials
    @{ name="1Password";            description="Password manager";                   checkCommand="& ""$env:LOCALAPPDATA\1Password\app\8\1Password.exe"" --version"; choco="1password"; winget="AgileBits.1Password" }
    @{ name="1Password CLI";        description="1Password command-line tool";        checkCommand="op --version";                     choco="1password-cli";          winget="AgileBits.1Password.CLI" }
    # Communication (if used)
    @{ name="Microsoft Teams";      description="Team collaboration";                 checkCommand="& ""$env:LOCALAPPDATA\Microsoft\Teams\current\Teams.exe"" --version"; choco="microsoft-teams"; winget="Microsoft.Teams" }
    @{ name="Zoom";                 description="Video conferencing";                 checkCommand="& ""$env:APPDATA\Zoom\bin\Zoom.exe"" --version"; choco="zoom"; winget="Zoom.Zoom" }
    # Utilities
    @{ name="7-Zip";                description="File archiver";                      checkCommand="7z i";                             choco="7zip";                   winget="7zip.7zip" }
    @{ name="PowerToys";            description="Windows system utilities";           checkCommand="& ""$env:LOCALAPPDATA\Microsoft\PowerToys\PowerToys.exe"" --version"; choco="powertoys"; winget="Microsoft.PowerToys" }
    @{ name="ShareX";               description="Screen capture tool";                checkCommand="Test-Path ""$env:ProgramFiles\ShareX\ShareX.exe""";  choco="sharex";                 winget="ShareX.ShareX" }
)

function Add-ToPersonal {
    param([object[]]$Tools, [string]$PersonalPath)

    Write-Host ""
    Write-Host "  ${BD}${WH}Add to personal.json?${RS}"
    Write-Host "  ${GR}Select the tools you want to keep — they'll be written to ${WH}$(Split-Path $PersonalPath -Leaf)${GR} for you.${RS}"
    Write-Host ""

    $picked = Show-Checklist -Tools ($Tools | ForEach-Object {
        [PSCustomObject]@{ name = $_.name; description = $_.description }
    })

    if (-not $picked -or $picked.Count -eq 0) {
        Write-Host "  ${GR}Nothing added.${RS}"
        Write-Host ""
        return
    }

    $personal = Get-Content $PersonalPath -Raw | ConvertFrom-Json
    $existingNames = @{}
    foreach ($t in $personal.tools) { if ($t.name) { $existingNames[$t.name] = $true } }

    $added = 0
    foreach ($p in $picked) {
        if ($existingNames.ContainsKey($p.name)) { continue }
        $full = $Tools | Where-Object { $_.name -eq $p.name } | Select-Object -First 1
        # Prefer checkCommand from the live $CommonDevTools lookup (avoids stale/missing paths from imported snapshots)
        $checkCmd = ($CommonDevTools | Where-Object { $_.name -eq $full.name } | Select-Object -First 1).checkCommand
        if (-not $checkCmd) { $checkCmd = $full.checkCommand }
        $entry = [ordered]@{ name = $full.name; description = $full.description; checkCommand = $checkCmd }
        if ($full.choco)  { $entry.choco  = $full.choco }
        if ($full.winget) { $entry.winget = $full.winget }
        $personal.tools += [PSCustomObject]$entry
        $added++
    }

    $personal | ConvertTo-Json -Depth 5 | Set-Content -Path $PersonalPath -Encoding UTF8
    Write-Host "  ${GN}[+]  $added tool$(if ($added -ne 1) {'s'}) added to ${WH}$(Split-Path $PersonalPath -Leaf)${RS}"
    Write-Host ""
}

function Show-GitPush {
    param([string]$RepoPath)

    $div = "  ${TC}$(([string][char]0x2500) * 56)${RS}"
    $isRepo = Test-Path (Join-Path $RepoPath '.git')

    Write-Host ""
    Write-Host "  ${BD}${WH}Push to Git${RS}"
    Write-Host "  ${GR}Put your config on GitHub so you can clone it on any machine.${RS}"
    Write-Host ""
    Write-Host $div
    Write-Host ""

    if (-not $isRepo) {
        Write-Host "  ${YL}  This folder is not a git repo yet.${RS}"
        Write-Host "  ${GR}  Initialising...${RS}"
        git -C $RepoPath init | Out-Null
        Write-Host "  ${GN}  [+] git init done${RS}"
        Write-Host ""
    }

    # Stage and commit
    $filesToStage = @('base.json', 'personal.json', 'setup-cli.ps1', '.gitignore')
    if (Test-Path (Join-Path $RepoPath 'snapshot.enc')) { $filesToStage += 'snapshot.enc' }
    git -C $RepoPath add $filesToStage 2>&1 | Out-Null
    $status = git -C $RepoPath status --short 2>&1
    if ($status) {
        git -C $RepoPath commit -m "chore: update dev-setup config" 2>&1 | Out-Null
        Write-Host "  ${GN}  [+] Changes committed${RS}"
    } else {
        Write-Host "  ${GR}  Nothing to commit — already up to date.${RS}"
    }
    Write-Host ""

    # Check for remote
    $remote = git -C $RepoPath remote get-url origin 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ${YL}  No remote set. Create a repo on GitHub, then paste the URL:${RS}"
        Write-Host "  ${GR}  (e.g. https://github.com/you/dev-setup.git)${RS}"
        Write-Host ""
        Show-Cursor
        Write-Host "  Remote URL: " -NoNewline
        $remoteUrl = Read-Host
        if ($remoteUrl) {
            git -C $RepoPath remote add origin $remoteUrl 2>&1 | Out-Null
            Write-Host "  ${GN}  [+] Remote added${RS}"
            Write-Host ""
        } else {
            Write-Host "  ${YL}  Skipped — run: git remote add origin <url> && git push -u origin main${RS}"
            Write-Host ""
            return
        }
    } else {
        Write-Host "  ${GR}  Remote: ${WH}$remote${RS}"
        Write-Host ""
    }

    Write-Host "  ${GR}  Pushing...${RS}"
    $pushOut = git -C $RepoPath push -u origin HEAD 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ${GN}  [+] Pushed! On your next machine run:${RS}"
        Write-Host ""
        $remoteUrl = git -C $RepoPath remote get-url origin 2>&1
        Write-Host "  ${WH}  git clone $remoteUrl C:\Source\dev-setup${RS}"
        Write-Host "  ${WH}  cd C:\Source\dev-setup${RS}"
        Write-Host "  ${WH}  .\setup-cli.ps1${RS}"
    } else {
        Write-Host "  ${YL}  Push failed. You may need to set up credentials or create the repo first.${RS}"
        Write-Host "  ${GR}  $pushOut${RS}"
    }
    Write-Host ""
    Write-Host $div
    Write-Host ""
}

function Save-Snapshot {
    param([object[]]$Tools, [string]$OutPath)

    # Only scan tools that are NOT already in base/personal config
    $configNames  = @{}
    foreach ($t in $Tools) { if ($t.name) { $configNames[$t.name] = $true } }

    $candidates = @($CommonDevTools | Where-Object { -not $configNames.ContainsKey($_.name) })
    $total      = $candidates.Count
    $i          = 0
    $discovered = [Collections.Generic.List[object]]::new()

    Write-Host ""
    Write-Host "  ${BD}${WH}Scanning for tools not in your config...${RS}"
    Write-Host "  ${GR}Checking $total common dev tools against what's installed${RS}"
    Write-Host ""

    foreach ($tool in $candidates) {
        $i++
        $pct    = [int](($i / $total) * 100)
        $filled = [int](($pct / 100) * 40)
        $bar    = ([string][char]0x2588 * $filled) + ([string][char]0x2591 * (40 - $filled))
        [Console]::Write("`r  ${CY}${bar}${RS}  ${GR}$pct%%  $($tool.name)${RS}   ")

        if (Test-Installed $tool.checkCommand) {
            $entry = [ordered]@{
                name        = $tool.name
                description = $tool.description
            }
            if ($tool.choco)  { $entry.choco  = $tool.choco }
            if ($tool.winget) { $entry.winget = $tool.winget }
            $discovered.Add($entry)
        }
    }

    [Console]::WriteLine()
    Write-Host ""

    $snapshot = [ordered]@{
        _comment   = "Snapshot generated by dev-setup on $(Get-Date -Format 'yyyy-MM-dd')"
        _hint      = "These tools are installed on this machine but not in your base.json or personal.json. Copy any you want into personal.json."
        discovered = $discovered
    }

    $snapshot | ConvertTo-Json -Depth 5 | Set-Content -Path $OutPath -Encoding UTF8

    if ($discovered.Count -gt 0) {
        Write-Host "  ${BD}${WH}Found $($discovered.Count) tool$(if ($discovered.Count -ne 1) {'s'}) not in your config:${RS}"
        Write-Host ""
        foreach ($d in $discovered) {
            Write-Host "  ${CY}  +  $($d.name)${RS}  ${GR}$($d.description)${RS}"
        }
        Write-Host ""
        Write-Host "  ${GR}Saved to ${WH}$(Split-Path $OutPath -Leaf)${RS}"
        Write-Host ""

        # Offer to add directly to personal.json
        $personalPath = Join-Path (Split-Path $OutPath -Parent) "personal.json"
        if (Test-Path $personalPath) {
            Add-ToPersonal -Tools $discovered -PersonalPath $personalPath
        }

        # Offer to encrypt for safe git storage
        Write-Host "  ${GR}Encrypt snapshot so it's safe to push to a public repo?  ${WH}[Y/n]${GR} : ${RS}" -NoNewline
        $ans = [Console]::ReadKey($true)
        Write-Host ""
        if ($ans.KeyChar -ne 'n' -and $ans.KeyChar -ne 'N') {
            $encPath = Join-Path (Split-Path $OutPath -Parent) "snapshot.enc"
            if (Protect-Snapshot -JsonPath $OutPath -OutPath $encPath) {
                Write-Host "  ${GN}✓  Encrypted snapshot saved to ${WH}snapshot.enc${RS}"
                Write-Host "  ${GR}  Commit and push ${WH}snapshot.enc${GR} — safe for public repos.${RS}"
                Write-Host "  ${GR}  On your next machine choose ${WH}Restore snapshot${GR} from the menu.${RS}"
                Write-Host ""
            }
        }
    } else {
        Write-Host "  ${GN}  Your config already covers everything found on this machine.${RS}"
    }
    Write-Host ""
}

# ══════════════════════════════════════════════════════════════════════════════
# 11a · Snapshot encryption / decryption  (AES-256-CBC + PBKDF2)
# ══════════════════════════════════════════════════════════════════════════════

function Protect-Snapshot {
    param([string]$JsonPath, [string]$OutPath)

    Show-Cursor
    Write-Host ""
    Write-Host "  ${BD}${WH}Encrypt snapshot${RS}"
    Write-Host "  ${GR}Set a passphrase — you'll need it to restore on another machine.${RS}"
    Write-Host "  ${GR}Use something memorable but strong (min 8 chars).${RS}"
    Write-Host ""
    Write-Host "  ${GR}Passphrase : ${RS}" -NoNewline;  $ss1 = Read-Host -AsSecureString
    Write-Host "  ${GR}Confirm    : ${RS}" -NoNewline;  $ss2 = Read-Host -AsSecureString

    $b1   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss1)
    $b2   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss2)
    $pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto($b1)
    $conf = [Runtime.InteropServices.Marshal]::PtrToStringAuto($b2)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)

    if ($pass -ne $conf) {
        Write-Host ""
        Write-Host "  ${RD}✗  Passphrases do not match.${RS}"
        Write-Host ""
        return $false
    }
    if ($pass.Length -lt 8) {
        Write-Host ""
        Write-Host "  ${YL}!  Passphrase must be at least 8 characters.${RS}"
        Write-Host ""
        return $false
    }

    $plain = [System.Text.Encoding]::UTF8.GetBytes((Get-Content $JsonPath -Raw))

    $salt = New-Object byte[] 16
    $rng  = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($salt); $rng.Dispose()

    # PBKDF2 — 300 000 iterations of SHA-1 (universally available on .NET 4.5+)
    $kdf  = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pass, $salt, 300000)
    $key  = $kdf.GetBytes(32)   # AES-256
    $iv   = $kdf.GetBytes(16)   # AES block size

    $aes          = [System.Security.Cryptography.Aes]::Create()
    $aes.Key      = $key
    $aes.IV       = $iv
    $aes.Mode     = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding  = [System.Security.Cryptography.PaddingMode]::PKCS7

    $ms = New-Object System.IO.MemoryStream
    $cs = New-Object System.Security.Cryptography.CryptoStream($ms, $aes.CreateEncryptor(), 'Write')
    $cs.Write($plain, 0, $plain.Length)
    $cs.FlushFinalBlock()
    $cipher = $ms.ToArray()
    $cs.Dispose(); $ms.Dispose(); $aes.Dispose()

    [ordered]@{
        _info      = "dev-setup encrypted snapshot — AES-256-CBC / PBKDF2-SHA1-300k"
        salt       = [Convert]::ToBase64String($salt)
        ciphertext = [Convert]::ToBase64String($cipher)
    } | ConvertTo-Json | Set-Content -Path $OutPath -Encoding UTF8

    return $true
}

function Unprotect-Snapshot {
    param([string]$EncPath)

    if (-not (Test-Path $EncPath)) {
        Write-Host "  ${RD}✗  No encrypted snapshot found: $(Split-Path $EncPath -Leaf)${RS}"
        Write-Host ""
        return $null
    }

    $bundle = Get-Content $EncPath -Raw | ConvertFrom-Json

    Show-Cursor
    Write-Host "  ${GR}Passphrase : ${RS}" -NoNewline
    $ss   = Read-Host -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    $pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    try {
        $salt   = [Convert]::FromBase64String($bundle.salt)
        $cipher = [Convert]::FromBase64String($bundle.ciphertext)

        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pass, $salt, 300000)
        $key = $kdf.GetBytes(32)
        $iv  = $kdf.GetBytes(16)

        $aes         = [System.Security.Cryptography.Aes]::Create()
        $aes.Key     = $key
        $aes.IV      = $iv
        $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

        $ms = New-Object System.IO.MemoryStream(, $cipher)
        $cs = New-Object System.Security.Cryptography.CryptoStream($ms, $aes.CreateDecryptor(), 'Read')
        $sr = New-Object System.IO.StreamReader($cs)
        $json = $sr.ReadToEnd()
        $sr.Dispose(); $cs.Dispose(); $ms.Dispose(); $aes.Dispose()

        return $json | ConvertFrom-Json
    } catch {
        Write-Host ""
        Write-Host "  ${RD}✗  Decryption failed — wrong passphrase?${RS}"
        Write-Host ""
        return $null
    }
}

function Show-Restore {
    param([string]$EncPath, [string]$PersonalPath)

    Write-Host ""
    Write-Host "  ${BD}${WH}Restore snapshot${RS}"
    Write-Host "  ${GR}Decrypt your snapshot and choose which tools to add to ${WH}$(Split-Path $PersonalPath -Leaf)${GR}.${RS}"
    Write-Host ""

    $snap = Unprotect-Snapshot -EncPath $EncPath
    if (-not $snap) { return }

    $tools = @($snap.discovered)
    if ($tools.Count -eq 0) {
        Write-Host "  ${GR}No tools found in snapshot.${RS}"
        Write-Host ""
        return
    }

    Write-Host "  ${GN}✓  Decrypted — $($tools.Count) tool$(if ($tools.Count -ne 1) {'s'}) found${RS}"
    Write-Host ""

    # Enrich with the live entry from $CommonDevTools so checkCommand is always current
    $enriched = $tools | ForEach-Object {
        $t    = $_
        $live = $CommonDevTools | Where-Object { $_.name -eq $t.name } | Select-Object -First 1
        if ($live) { [PSCustomObject]$live }
        else       { [PSCustomObject]@{ name = $t.name; description = $t.description; choco = $t.choco; winget = $t.winget } }
    }

    Add-ToPersonal -Tools $enriched -PersonalPath $PersonalPath
}

function Show-Help {
    $div = "  ${TC}$(([string][char]0x2500) * 56)${RS}"

    Clear-Host
    Write-Host ""
    Write-Host "  ${BD}${WH}How to customise Dev Setup${RS}"
    Write-Host ""
    Write-Host $div
    Write-Host ""
    Write-Host "  ${BD}${CY}The two config files${RS}"
    Write-Host ""
    Write-Host "  ${WH}base.json${RS}"
    Write-Host "  ${GR}  The shared foundation. Put tools every dev on your team needs here.${RS}"
    Write-Host "  ${GR}  Commit this to a shared or team repo so everyone stays in sync.${RS}"
    Write-Host ""
    Write-Host "  ${WH}personal.json${RS}"
    Write-Host "  ${GR}  Your own extras, layered on top of base. Lives in your personal repo.${RS}"
    Write-Host "  ${GR}  An entry with the same name as a base entry overrides it${RS}"
    Write-Host "  ${GR}  (useful for pinning a specific version).${RS}"
    Write-Host ""
    Write-Host $div
    Write-Host ""
    Write-Host "  ${BD}${CY}Adding a tool${RS}"
    Write-Host "  ${GR}Open ${WH}personal.json${GR} and add an entry to the ${WH}tools${GR} array:${RS}"
    Write-Host ""
    Write-Host "  ${TC}{${RS}"
    Write-Host "  ${TC}  ${WH}""name"":         ${GN}""Postman"",${RS}"
    Write-Host "  ${TC}  ${WH}""description"":  ${GN}""API testing platform"",${RS}"
    Write-Host "  ${TC}  ${WH}""checkCommand"": ${GN}""postman --version"",${RS}"
    Write-Host "  ${TC}  ${WH}""choco"":         ${GN}""postman"",${RS}"
    Write-Host "  ${TC}  ${WH}""winget"":        ${GN}""Postman.Postman""${RS}"
    Write-Host "  ${TC}}${RS}"
    Write-Host ""
    Write-Host "  ${GR}Find the winget ID:   ${WH}winget search <name>${RS}"
    Write-Host "  ${GR}Find the choco name:  ${WH}choco search <name>${RS}"
    Write-Host "  ${GR}Only ${WH}name${GR} and ${WH}checkCommand${GR} are required — omit the rest if not available.${RS}"
    Write-Host ""
    Write-Host $div
    Write-Host ""
    Write-Host "  ${BD}${CY}Pointing personal.json at a different base${RS}"
    Write-Host "  ${GR}Change the ${WH}extends${GR} field to any local or network path:${RS}"
    Write-Host ""
    Write-Host "  ${TC}  ${WH}""extends"": ${GN}""\\\\shared-server\\dotfiles\\base.json""${RS}"
    Write-Host "  ${TC}  ${WH}""extends"": ${GN}""C:\\Source\\team-dotfiles\\base.json""${RS}"
    Write-Host ""
    Write-Host $div
    Write-Host ""
    Write-Host "  ${BD}${CY}Useful flags when running the script${RS}"
    Write-Host "  ${WH}-DryRun${RS}          ${GR}Preview without installing anything${RS}"
    Write-Host "  ${WH}-Config <path>${RS}   ${GR}Use a different JSON file${RS}"
    Write-Host "  ${WH}-SkipChoco${RS}       ${GR}Skip Chocolatey, use winget only${RS}"
    Write-Host ""
    Write-Host $div
    Write-Host ""
    Write-Host "  ${GR}Press any key to return to the menu...${RS}"
    $null = [Console]::ReadKey($true)
}

# ══════════════════════════════════════════════════════════════════════════════
# ══════════════════════════════════════════════════════════════════════════════

Show-Banner

# Resolve config path
if (-not $Config) {
    $Config = if (Test-Path "$PSScriptRoot\personal.json") { "$PSScriptRoot\personal.json" }
              elseif (Test-Path "$PSScriptRoot\base.json")  { "$PSScriptRoot\base.json" }
              else {
                  Write-Host "  ${RD}No config file found next to this script.${RS}"
                  Write-Host "  ${GR}Place personal.json or base.json in the same folder.${RS}"
                  Write-Host ""
                  exit 1
              }
}

$cfg = Resolve-Config $Config
$configLabel = Split-Path $Config -Leaf

Write-Host "  ${BD}${WH}" -NoNewline; Write-Typewriter "Welcome to Dev Setup!"
Write-Host "  ${GR}" -NoNewline; Write-Typewriter "Stop spending your first day reading setup docs."
Write-Host ""
Write-Host "  ${GR}  ${CY}For you${GR}    — define your tools once, run on any new machine in minutes.${RS}"
Write-Host "  ${GR}  ${CY}For teams${GR}  — one shared config, every new joiner set up before lunch.${RS}"
Write-Host ""
Write-Host "  ${TC}$(([string][char]0x2500) * 56)${RS}"
Write-Host ""
Write-Host "  ${GR}Config  : ${WH}$configLabel${RS}  ${GR}(${WH}$($cfg.tools.Count)${GR} tools)${RS}"
Write-Host ""

# ── Main menu ────────────────────────────────────────────────────────────────

$menuChoice = Show-Menu -Title "What would you like to do?" -Options @(
    @{ Header = "Install" },
    "Install all tools",
    "Pick tools to install",
    "Dry run  — preview without installing",
    "",
    @{ Header = "Config" },
    "Snapshot this machine  — find tools not in your config",
    "Restore snapshot  — decrypt & apply on this machine",
    "Push to Git  — save & share your config",
    "",
    @{ Header = "Other" },
    "Help  — how to customise base & personal",
    "Exit"
)

if ($menuChoice -eq -1 -or $menuChoice -eq 7) {
    Write-Host "  ${GR}Bye.${RS}"; Write-Host ""; exit 0
}

if ($menuChoice -eq 6) {
    Show-Help
    & $MyInvocation.MyCommand.Path -Config $Config -SkipChoco:$SkipChoco
    exit
}

if ($menuChoice -eq 5) {
    Show-GitPush -RepoPath $PSScriptRoot
    Write-Host "  ${GR}Press any key to return to the menu...${RS}"
    $null = [Console]::ReadKey($true)
    & $MyInvocation.MyCommand.Path -Config $Config -SkipChoco:$SkipChoco
    exit
}

if ($menuChoice -eq 4) {
    $encPath      = Join-Path $PSScriptRoot "snapshot.enc"
    $personalPath = Join-Path $PSScriptRoot "personal.json"
    Show-Restore -EncPath $encPath -PersonalPath $personalPath
    Write-Host "  ${GR}Press any key to return to the menu...${RS}"
    $null = [Console]::ReadKey($true)
    & $MyInvocation.MyCommand.Path -Config $Config -SkipChoco:$SkipChoco
    exit
}

if ($menuChoice -eq 3) {
    $snapPath = Join-Path $PSScriptRoot "snapshot.json"
    Save-Snapshot -Tools $cfg.tools -OutPath $snapPath
    Write-Host "  ${GR}Press any key to return to the menu...${RS}"
    $null = [Console]::ReadKey($true)
    & $MyInvocation.MyCommand.Path -Config $Config -SkipChoco:$SkipChoco
    exit
}

if ($menuChoice -eq 2) {
    $DryRun = $true
    Show-Banner
    Write-Host "  ${BD}${WH}Welcome to Dev Setup!${RS}"
    Write-Host "  ${GR}Installs your team tools + personal extras on any Windows machine.${RS}"
    Write-Host "  ${GR}Uses ${WH}Chocolatey${GR} → ${WH}winget${GR} → ${WH}manual link${GR}. Already-installed tools are skipped.${RS}"
    Write-Host ""
    Write-Host "  ${GR}Config  : ${WH}$configLabel${RS}  ${GR}(${WH}$($cfg.tools.Count)${GR} tools)${RS}"
    Write-Host ""
}

# ── Tool selection ────────────────────────────────────────────────────────────

if ($menuChoice -eq 1) {
    Write-Host "  ${GR}Pick tools:${RS}"
    Write-Host ""
    $toolsToProcess = Show-Checklist -Tools $cfg.tools
} else {
    $toolsToProcess = $cfg.tools
}

if (-not $toolsToProcess -or $toolsToProcess.Count -eq 0) {
    Write-Host "  ${YL}Nothing selected. Exiting.${RS}"; Write-Host ""; exit 0
}

$toolWord = if ($toolsToProcess.Count -eq 1) { "tool" } else { "tools" }
Write-Host "  ${GR}Processing ${WH}$($toolsToProcess.Count)${GR} $toolWord...${RS}"
Write-Host ""

# ── Installer availability ────────────────────────────────────────────────────

$chocoOK   = (Get-Command choco  -EA SilentlyContinue) -ne $null
$wingetOK  = (Get-Command winget -EA SilentlyContinue) -ne $null
$useChoco  = $cfg.settings.preferChocolatey -and -not $SkipChoco

if ($useChoco -and -not $chocoOK -and -not $DryRun) {
    $sp = Start-Spinner "Installing Chocolatey"
    $chocoOK = Install-Chocolatey
    Stop-Spinner $sp
    if ($chocoOK) {
        Write-Host "  ${GN}✓  Chocolatey ready${RS}"
    } else {
        Write-Host "  ${YL}!  Chocolatey unavailable — falling back to winget${RS}"
    }
    Write-Host ""
}

# ── Process each tool ─────────────────────────────────────────────────────────

$already  = [Collections.Generic.List[string]]::new()
$done     = [Collections.Generic.List[object]]::new()
$manual   = [Collections.Generic.List[object]]::new()
$failed   = [Collections.Generic.List[string]]::new()
$dryTools = [Collections.Generic.List[object]]::new()

Hide-Cursor

foreach ($tool in $toolsToProcess) {

    if (Test-Installed $tool.checkCommand) {
        Write-Host "  ${GR}✓  $($tool.name) — already installed${RS}"
        $already.Add($tool.name)
        continue
    }

    if ($DryRun) {
        Write-Host "  ${YL}◌  $($tool.name) — would install${RS}"
        $dryTools.Add($tool)
        continue
    }

    $sp     = Start-Spinner $tool.name
    $result = Install-Tool -Tool $tool -UseChoco $useChoco -ChocoOK $chocoOK -WingetOK $wingetOK
    Stop-Spinner $sp

    switch ($result.Status) {
        "ok" {
            Write-Host "  ${GN}✓  $($tool.name)${RS}  ${GR}via $($result.Via)${RS}"
            $done.Add([PSCustomObject]@{ Name = $tool.name; Via = $result.Via })
        }
        "manual" {
            Write-Host "  ${YL}!  $($tool.name) — manual install needed${RS}"
            $manual.Add([PSCustomObject]@{ Name = $tool.name; Url = $result.Url })
        }
        default {
            Write-Host "  ${RD}✗  $($tool.name) — failed${RS}"
            $failed.Add($tool.name)
        }
    }
}

Show-Cursor
Write-Host ""

Show-Summary `
    -AlreadyInstalled $already.ToArray() `
    -Installed        $done.ToArray() `
    -ManualRequired   $manual.ToArray() `
    -Failed           $failed.ToArray() `
    -DryRunTools      $dryTools.ToArray()

# ── What next? ────────────────────────────────────────────────────────────────

$nextOptions = if ($DryRun) {
    @("Install all tools now", "Pick tools to install", "Exit")
} else {
    @("Return to main menu", "Exit")
}

$next = Show-Menu -Title "What would you like to do next?" -Options $nextOptions

if ($DryRun) {
    switch ($next) {
        0 {
            $DryRun = $false
            Show-Banner
            Write-Host "  ${GR}Config  : ${WH}$configLabel${RS}  ${GR}(${WH}$($cfg.tools.Count)${GR} tools)${RS}"
            Write-Host ""
            $toolsToProcess = $cfg.tools
            & $MyInvocation.MyCommand.Path -Config $Config -SkipChoco:$SkipChoco
            exit
        }
        1 {
            $DryRun = $false
            Show-Banner
            Write-Host "  ${GR}Config  : ${WH}$configLabel${RS}  ${GR}(${WH}$($cfg.tools.Count)${GR} tools)${RS}"
            Write-Host ""
            & $MyInvocation.MyCommand.Path -Config $Config -SkipChoco:$SkipChoco
            exit
        }
        default { Write-Host "  ${GR}Bye.${RS}"; Write-Host ""; exit 0 }
    }
} else {
    if ($next -eq 0) {
        & $MyInvocation.MyCommand.Path -Config $Config -SkipChoco:$SkipChoco
        exit
    } else {
        Write-Host "  ${GR}Bye.${RS}"; Write-Host ""; exit 0
    }
}
