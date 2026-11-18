# ============================================================
# DDNS Certificate Renewal / NGINX Certificate Sync
# ============================================================


# ------------------------------------------------------------
# Windows Toast Notification
# ------------------------------------------------------------
function Show-Notification {
    [CmdletBinding()]
    param (
        [string]$ToastTitle,
        [string]$ToastText
    )

    try {
        [Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime] > $null

        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02
        )

        $xml = [xml]$template.GetXml()

        ($xml.toast.visual.binding.text | Where-Object { $_.id -eq "1" }).AppendChild(
            $xml.CreateTextNode($ToastTitle)
        ) | Out-Null

        ($xml.toast.visual.binding.text | Where-Object { $_.id -eq "2" }).AppendChild(
            $xml.CreateTextNode($ToastText)
        ) | Out-Null

        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml.OuterXml)

        $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
        $toast.Tag   = "ASUS Router Script"
        $toast.Group = "ASUS Router Script"

        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(
            "Merlin DDNS Refresh"
        ).Show($toast)
    }
    catch {
        Write-Warning "Toast notification failed: $($_.Exception.Message)"
    }
}


# ------------------------------------------------------------
# Native command helper
#
# nginx.exe normally writes normal status output to stderr.
# This prevents Windows PowerShell from treating that alone
# as a terminating PowerShell error.
# ------------------------------------------------------------
function Invoke-NativeCommand {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string[]]$ArgumentList = @()
    )

    $oldPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"

        $output = & $FilePath @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = ($output -join [Environment]::NewLine)
    }
}


# ------------------------------------------------------------
# Apply exact ACL required for an installed NGINX private key
#
# Final ACL:
#   SYSTEM          Full Control
#   Administrators  Full Control
#   nginx_svc       Read
# ------------------------------------------------------------
function Set-NginxPrivateKeyAcl {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $svcAccount = "$env:COMPUTERNAME\nginx_svc"

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Private key not found: $Path"
    }

    & icacls.exe $Path /inheritance:r | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Failed disabling inheritance on private key: $Path"
    }

    & icacls.exe $Path /grant:r `
        "NT AUTHORITY\SYSTEM:(F)" `
        "BUILTIN\Administrators:(F)" `
        "${svcAccount}:(R)" | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Failed applying private-key ACL to: $Path"
    }
}


# ------------------------------------------------------------
# Variables
# ------------------------------------------------------------
$script:WebService       = "nginx"
$script:CertDownloadPath = "C:\ProgramData\nginx-cert-staging"
$script:CertInstallPath  = "C:\ProgramData\nginx"

$script:User             = "XXXXXXXXXXXXXXXXXXXXX"
$script:IP               = "192.168.50.1"

# Replace this with the ROTATED router password.
# Later this can be replaced entirely with SSH key authentication.
$script:Password         = "XXXXXXXXXXXXXXXXXXXXX"


# ------------------------------------------------------------
# Domain folders
# ------------------------------------------------------------
$Domains = @(
    "plexrequest.freemyip.com_ecc",
    "firetopgames.freemyip.com_ecc"
)

$DomainPaths = @{
    "plexrequest.freemyip.com_ecc"  = "/jffs/.le"
    "firetopgames.freemyip.com_ecc" = "/jffs/.FTGle"
}


# ------------------------------------------------------------
# Locate PSCP
# ------------------------------------------------------------
$pscpCommand = Get-Command pscp.exe -ErrorAction SilentlyContinue

if (-not $pscpCommand) {
    Write-Host "ERROR: pscp.exe not found in PATH." -ForegroundColor Red
    Show-Notification "SCP Missing" "pscp.exe was not found in PATH"
    exit 1
}

$pscpExe = $pscpCommand.Source


# ------------------------------------------------------------
# Locate nginx
# ------------------------------------------------------------
$nginxExe = Join-Path $script:CertInstallPath "nginx.exe"

if (-not (Test-Path -LiteralPath $nginxExe -PathType Leaf)) {
    Write-Host "ERROR: nginx.exe not found at $nginxExe" -ForegroundColor Red
    Show-Notification "NGINX Missing" "nginx.exe was not found"
    exit 1
}


# ------------------------------------------------------------
# Verify staging directory
# ------------------------------------------------------------
if (-not (Test-Path -LiteralPath $script:CertDownloadPath -PathType Container)) {
    Write-Host "ERROR: Protected staging directory is missing:" -ForegroundColor Red
    Write-Host $script:CertDownloadPath -ForegroundColor Red

    Show-Notification "Certificate Error" "Certificate staging directory is missing"
    exit 1
}


# ------------------------------------------------------------
# Verify nginx service
# ------------------------------------------------------------
try {
    $initialService = Get-Service -Name $script:WebService -ErrorAction Stop
}
catch {
    Write-Host "ERROR: nginx Windows service was not found." -ForegroundColor Red
    Show-Notification "NGINX Service Error" "nginx service was not found"
    exit 1
}

if ($initialService.Status -ne "Running") {
    Write-Host "ERROR: nginx was not running before certificate renewal." -ForegroundColor Red
    Show-Notification "NGINX Service Error" "nginx was not running before renewal"
    exit 1
}


# ------------------------------------------------------------
# State used for rollback
# ------------------------------------------------------------
$backupRoot      = $null
$backupReady     = $false
$installStarted  = $false
$restartAttempted = $false


# ------------------------------------------------------------
# Start
# ------------------------------------------------------------
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "NGINX Certificate Update" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Using PSCP : $pscpExe"
Write-Host "Router     : $($script:IP)"
Write-Host "Staging    : $($script:CertDownloadPath)"
Write-Host "NGINX root : $($script:CertInstallPath)"
Write-Host ""

Show-Notification "Downloading DDNS Certs" "PlexRequest + FiretopGames"


try {

    # ========================================================
    # DOWNLOAD CERTIFICATES
    # ========================================================
    foreach ($domain in $Domains) {

        if (-not $DomainPaths.ContainsKey($domain)) {
            throw "Domain folder '$domain' has no entry in `$DomainPaths."
        }

        $parentPath = $DomainPaths[$domain]
        $base = $domain -replace "_ecc$", ""

        $remoteKey =
            "$($script:User)@$($script:IP):$parentPath/$domain/$base.key"

        $remoteChain =
            "$($script:User)@$($script:IP):$parentPath/$domain/fullchain.pem"

        $localKey =
            Join-Path $script:CertDownloadPath "$base.key"

        $localChain =
            Join-Path $script:CertDownloadPath "$base.fullchain.pem"

        $tempKey =
            "$localKey.tmp"

        $tempChain =
            "$localChain.tmp"


        # Remove stale temporary files from any previous failed run.
        Remove-Item -LiteralPath $tempKey -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempChain -Force -ErrorAction SilentlyContinue


        # ----------------------------------------------------
        # Download private key
        # ----------------------------------------------------
        Write-Host "Fetching KEY for $base..." -ForegroundColor Cyan

        $result = Invoke-NativeCommand `
            -FilePath $pscpExe `
            -ArgumentList @(
                "-batch",
                "-scp",
                "-pw",
                $script:Password,
                $remoteKey,
                $tempKey
            )

        if ($result.Output) {
            Write-Host $result.Output
        }

        if ($result.ExitCode -ne 0) {
            throw "Private-key download failed for $base. PSCP exit code: $($result.ExitCode)"
        }


        # ----------------------------------------------------
        # Download certificate chain
        # ----------------------------------------------------
        Write-Host "Fetching certificate chain for $base..." -ForegroundColor Cyan

        $result = Invoke-NativeCommand `
            -FilePath $pscpExe `
            -ArgumentList @(
                "-batch",
                "-scp",
                "-pw",
                $script:Password,
                $remoteChain,
                $tempChain
            )

        if ($result.Output) {
            Write-Host $result.Output
        }

        if ($result.ExitCode -ne 0) {
            throw "Certificate-chain download failed for $base. PSCP exit code: $($result.ExitCode)"
        }


        # ----------------------------------------------------
        # Verify downloads exist and are not empty
        # ----------------------------------------------------
        if (-not (Test-Path -LiteralPath $tempKey -PathType Leaf)) {
            throw "Downloaded private key does not exist for $base."
        }

        if ((Get-Item -LiteralPath $tempKey).Length -le 0) {
            throw "Downloaded private key is empty for $base."
        }

        if (-not (Test-Path -LiteralPath $tempChain -PathType Leaf)) {
            throw "Downloaded certificate chain does not exist for $base."
        }

        if ((Get-Item -LiteralPath $tempChain).Length -le 0) {
            throw "Downloaded certificate chain is empty for $base."
        }


        # ----------------------------------------------------
        # Promote successful temporary downloads
        # ----------------------------------------------------
        Move-Item `
            -LiteralPath $tempKey `
            -Destination $localKey `
            -Force

        Move-Item `
            -LiteralPath $tempChain `
            -Destination $localChain `
            -Force

        Write-Host "Downloaded $base successfully." -ForegroundColor Green
        Write-Host ""
    }


    # ========================================================
    # BACK UP CURRENTLY INSTALLED CERTIFICATES
    #
    # nginx remains ONLINE.
    # ========================================================
    $backupRoot = Join-Path `
        $script:CertDownloadPath `
        ("backup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))

    New-Item `
        -ItemType Directory `
        -Path $backupRoot `
        -Force | Out-Null

    # Back up only files that actually existed before this run.

    foreach ($domain in $Domains) {

        $base = $domain -replace "_ecc$", ""

        $dstKey =
            Join-Path $script:CertInstallPath "$base`key.pem"

        $dstCert =
            Join-Path $script:CertInstallPath "$base`cert.pem"


        # Back up whatever is currently installed.
        # Missing files are allowed so this script can repair an incomplete install.

        if (Test-Path -LiteralPath $dstKey -PathType Leaf) {

            Copy-Item `
                -LiteralPath $dstKey `
                -Destination (Join-Path $backupRoot "${base}key.pem") `
                -Force
        }
        else {
            Write-Host "WARNING: Existing private key is missing: $dstKey" -ForegroundColor Yellow
            Write-Host "The newly downloaded key will repair it." -ForegroundColor Yellow
        }


        if (Test-Path -LiteralPath $dstCert -PathType Leaf) {

            Copy-Item `
                -LiteralPath $dstCert `
                -Destination (Join-Path $backupRoot "${base}cert.pem") `
                -Force
        }
        else {
            Write-Host "WARNING: Existing certificate is missing: $dstCert" -ForegroundColor Yellow
            Write-Host "The newly downloaded certificate will repair it." -ForegroundColor Yellow
        }

    }

    $backupReady = $true


    # ========================================================
    # INSTALL NEW CERTIFICATE FILES
    #
    # nginx is STILL ONLINE and using the currently loaded
    # certificate material.
    # ========================================================
    Show-Notification "Installing Certs" "Validating new certificates"

    $installStarted = $true


    foreach ($domain in $Domains) {

        $base = $domain -replace "_ecc$", ""

        $srcKey =
            Join-Path $script:CertDownloadPath "$base.key"

        $srcChain =
            Join-Path $script:CertDownloadPath "$base.fullchain.pem"

        $dstKey =
            Join-Path $script:CertInstallPath "$base`key.pem"

        $dstCert =
            Join-Path $script:CertInstallPath "$base`cert.pem"


        Write-Host "Installing $base..." -ForegroundColor Cyan

        Copy-Item `
            -LiteralPath $srcKey `
            -Destination $dstKey `
            -Force

        Copy-Item `
            -LiteralPath $srcChain `
            -Destination $dstCert `
            -Force


        # Reapply exact hardened private-key ACL every time.
        Set-NginxPrivateKeyAcl -Path $dstKey

        Write-Host "Installed $base." -ForegroundColor Green
    }


    # ========================================================
    # TEST NGINX BEFORE RESTARTING
    # ========================================================
    Write-Host ""
    Write-Host "Testing nginx configuration and certificates..." -ForegroundColor Cyan

    $nginxPrefix = $script:CertInstallPath.TrimEnd("\") + "\"

    $test = Invoke-NativeCommand `
        -FilePath $nginxExe `
        -ArgumentList @(
            "-p",
            $nginxPrefix,
            "-t"
        )

    if ($test.Output) {
        Write-Host $test.Output
    }

    if ($test.ExitCode -ne 0) {
        throw "nginx -t failed with the newly installed certificates."
    }


    # ========================================================
    # RESTART NGINX
    # ========================================================
    Write-Host ""
    Write-Host "nginx validation succeeded." -ForegroundColor Green
    Write-Host "Restarting nginx..." -ForegroundColor Cyan

    $restartAttempted = $true

    Restart-Service `
        -Name $script:WebService `
        -ErrorAction Stop


    $service = Get-Service `
        -Name $script:WebService `
        -ErrorAction Stop

    $service.WaitForStatus(
        [System.ServiceProcess.ServiceControllerStatus]::Running,
        [TimeSpan]::FromSeconds(30)
    )

    $service.Refresh()

    if ($service.Status -ne "Running") {
        throw "nginx failed to return to Running state."
    }


    # Give worker processes a moment to appear.
    Start-Sleep -Seconds 2

    $nginxProcesses =
        Get-Process nginx -ErrorAction SilentlyContinue

    if (-not $nginxProcesses) {
        throw "nginx service reports Running but no nginx.exe processes exist."
    }


    # ========================================================
    # CLEAN STAGING FILES
    # ========================================================
    Write-Host ""
    Write-Host "Cleaning staging files..." -ForegroundColor Cyan

    foreach ($domain in $Domains) {

        $base = $domain -replace "_ecc$", ""

        $filesToDelete = @(
            (Join-Path $script:CertDownloadPath "$base.key"),
            (Join-Path $script:CertDownloadPath "$base.fullchain.pem"),
            (Join-Path $script:CertDownloadPath "$base.key.tmp"),
            (Join-Path $script:CertDownloadPath "$base.fullchain.pem.tmp")
        )

        foreach ($file in $filesToDelete) {
            Remove-Item `
                -LiteralPath $file `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }


    # Backup is no longer needed after successful activation.
    if (
        $backupRoot -and
        (Test-Path -LiteralPath $backupRoot)
    ) {
        Remove-Item `
            -LiteralPath $backupRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }


    # ========================================================
    # SUCCESS
    # ========================================================
    Write-Host ""
    Write-Host "======================================================" -ForegroundColor Green
    Write-Host "Certificate update completed successfully." -ForegroundColor Green
    Write-Host "======================================================" -ForegroundColor Green
    Write-Host ""

    Show-Notification `
        "Certs Installed" `
        "$($script:WebService) up with new certs"

    exit 0
}


catch {

    $originalError = $_.Exception.Message

    Write-Host ""
    Write-Host "======================================================" -ForegroundColor Red
    Write-Host "CERTIFICATE UPDATE FAILED" -ForegroundColor Red
    Write-Host "======================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host $originalError -ForegroundColor Red
    Write-Host ""


    # ========================================================
    # ROLLBACK IF INSTALLATION HAD STARTED
    # ========================================================
    $rollbackSucceeded = $false

    if (
        $backupReady -and
        $installStarted -and
        $backupRoot -and
        (Test-Path -LiteralPath $backupRoot)
    ) {

        try {
            Write-Host "Restoring previous certificates..." -ForegroundColor Yellow


            foreach ($domain in $Domains) {

                $base = $domain -replace "_ecc$", ""

                $backupKey =
                    Join-Path $backupRoot "$base`key.pem"

                $backupCert =
                    Join-Path $backupRoot "$base`cert.pem"

                $dstKey =
                    Join-Path $script:CertInstallPath "$base`key.pem"

                $dstCert =
                    Join-Path $script:CertInstallPath "$base`cert.pem"


                # Restore only files that actually existed before this run.
                
                if (Test-Path -LiteralPath $backupKey -PathType Leaf) {

                    Copy-Item `
                        -LiteralPath $backupKey `
                        -Destination $dstKey `
                        -Force

                    Set-NginxPrivateKeyAcl -Path $dstKey
                }
                else {
                    Write-Host "No previous private key existed for $base; removing newly installed key." -ForegroundColor Yellow

                    Remove-Item `
                        -LiteralPath $dstKey `
                        -Force `
                        -ErrorAction SilentlyContinue
                }

                if (Test-Path -LiteralPath $backupCert -PathType Leaf) {

                    Copy-Item `
                        -LiteralPath $backupCert `
                        -Destination $dstCert `
                        -Force
                }
                else {
                    Write-Host "No previous certificate existed for $base; removing newly installed certificate." -ForegroundColor Yellow

                    Remove-Item `
                        -LiteralPath $dstCert `
                        -Force `
                        -ErrorAction SilentlyContinue
                }
            }


            # ------------------------------------------------
            # Validate restored configuration
            # ------------------------------------------------
            $nginxPrefix = $script:CertInstallPath.TrimEnd("\") + "\"

            $restoreTest = Invoke-NativeCommand `
                -FilePath $nginxExe `
                -ArgumentList @(
                    "-p",
                    $nginxPrefix,
                    "-t"
                )

            if ($restoreTest.Output) {
                Write-Host $restoreTest.Output
            }

            if ($restoreTest.ExitCode -ne 0) {
                throw "Restored certificates also failed nginx -t."
            }


            # ------------------------------------------------
            # If a restart had already been attempted, restart
            # again to guarantee the restored certificates are
            # the ones loaded by nginx.
            # ------------------------------------------------
            if ($restartAttempted) {

                Write-Host "Restarting nginx with restored certificates..." -ForegroundColor Yellow

                Restart-Service `
                    -Name $script:WebService `
                    -ErrorAction Stop


                $service = Get-Service `
                    -Name $script:WebService `
                    -ErrorAction Stop

                $service.WaitForStatus(
                    [System.ServiceProcess.ServiceControllerStatus]::Running,
                    [TimeSpan]::FromSeconds(30)
                )

                $service.Refresh()

                if ($service.Status -ne "Running") {
                    throw "nginx failed to start with restored certificates."
                }
            }
            else {

                # If nginx was never restarted, it should still
                # be serving the previously loaded certificate.
                $service = Get-Service `
                    -Name $script:WebService `
                    -ErrorAction Stop

                if ($service.Status -ne "Running") {

                    Start-Service `
                        -Name $script:WebService `
                        -ErrorAction Stop

                    $service.WaitForStatus(
                        [System.ServiceProcess.ServiceControllerStatus]::Running,
                        [TimeSpan]::FromSeconds(30)
                    )
                }
            }


            $rollbackSucceeded = $true

            Write-Host "Previous certificates restored successfully." -ForegroundColor Green
        }
        catch {
            Write-Host ""
            Write-Host "ROLLBACK FAILED:" -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red
            Write-Host ""
            Write-Host "Backup retained at:" -ForegroundColor Yellow
            Write-Host $backupRoot -ForegroundColor Yellow
        }
    }


    # ========================================================
    # REMOVE DOWNLOADED/STAGING CERTIFICATE COPIES
    #
    # Do not remove backupRoot if rollback failed.
    # ========================================================
    foreach ($domain in $Domains) {

        $base = $domain -replace "_ecc$", ""

        $filesToDelete = @(
            (Join-Path $script:CertDownloadPath "$base.key"),
            (Join-Path $script:CertDownloadPath "$base.fullchain.pem"),
            (Join-Path $script:CertDownloadPath "$base.key.tmp"),
            (Join-Path $script:CertDownloadPath "$base.fullchain.pem.tmp")
        )

        foreach ($file in $filesToDelete) {
            Remove-Item `
                -LiteralPath $file `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }


    # If rollback worked, its temporary backup can be removed.
    if (
        $rollbackSucceeded -and
        $backupRoot -and
        (Test-Path -LiteralPath $backupRoot)
    ) {
        Remove-Item `
            -LiteralPath $backupRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }


    Show-Notification `
        "Certificate Update Failed" `
        $originalError

    exit 1
}