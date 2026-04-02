# =============================================================================
# Ubuntu WSL Automated Installation Script (Idempotent)
# =============================================================================
# This script installs a WSL distribution (e.g., Ubuntu) with a custom user,
# configures isolation (disables Windows PATH and automount), optionally runs
# an internal setup script inside WSL, and sets the distribution as default.
# The script is idempotent – running it multiple times will safely reconfigure
# the environment to the desired state without causing errors or duplicates.
# =============================================================================

# -----------------------------------------------------------------------------
# 0. Administrator Check
# -----------------------------------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "This script requires Administrator privileges. Please run as Administrator."
    exit 1
}

# -----------------------------------------------------------------------------
# 1. Helper Functions
# -----------------------------------------------------------------------------

# Load environment variables from a .env file
function Load-Env {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) {
        throw "Configuration file '$FilePath' not found."
    }

    Write-Host "Loading configuration from $FilePath..." -ForegroundColor Cyan
    $envVariables = @{}
    Get-Content $FilePath | ForEach-Object {
        if ($_ -match "^\s*([^#][^=]+)=(.*)") {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim() -replace '^"|"$', ''
            $envVariables[$key] = $value
        }
    }
    return $envVariables
}

# Check if a user exists inside the WSL distribution
function Test-WslUser {
    param(
        [Parameter(Mandatory)]
        [string]$Distribution,
        [Parameter(Mandatory)]
        [string]$UserName
    )
    $result = wsl -d $Distribution -u root id -u $UserName 2>$null
    return ($LASTEXITCODE -eq 0)
}

# Create a new Linux user inside the WSL distribution if not already present
function Add-WslUser {
    param(
        [Parameter(Mandatory)]
        [string]$Distribution,
        [Parameter(Mandatory)]
        [pscredential]$Credential
    )

    $userName = $Credential.UserName.ToLower()
    $plainPassword = $Credential.GetNetworkCredential().Password

    if (Test-WslUser -Distribution $Distribution -UserName $userName) {
        Write-Host "User '$userName' already exists. Skipping creation." -ForegroundColor Green
        return
    }

    if ([string]::IsNullOrEmpty($plainPassword)) {
        Write-Host "Creating passwordless user '$userName'..."
        wsl -d $Distribution -u root adduser --gecos GECOS --disabled-password $userName
    } else {
        Write-Host "Creating user '$userName' with password..."
        # Pipe password twice: for password and confirmation
        "${plainPassword}`n${plainPassword}`n" | wsl -d $Distribution -u root adduser --gecos GECOS $userName
    }

    Write-Host "Adding user '$userName' to sudo group..."
    wsl -d $Distribution -u root usermod -aG sudo $userName
}

# Ensure the WSL distribution is installed and configured
function Ensure-WslDistro {
    param(
        [Parameter(Mandatory)]
        [string]$Distribution,
        [Parameter(Mandatory)]
        [string]$Username,
        [Parameter(Mandatory)]
        [securestring]$Password
    )

    # Check if already installed
    $list = wsl -l -v 2>&1
    if ($list | Select-String -Pattern $Distribution -SimpleMatch) {
        Write-Host "Distribution '$Distribution' is already installed. Ensuring configuration..." -ForegroundColor Green
    } else {
        Write-Host "Installing distribution '$Distribution' (non‑interactive)..." -ForegroundColor Yellow
        wsl --install $Distribution --no-launch

        # Initialize the filesystem by triggering a simple command
        Write-Host "Initializing filesystem..."
        wsl -d $Distribution -u root echo "Filesystem initialized"
    }

    # Create the custom user (idempotent)
    $cred = [PSCredential]::new($Username, $Password)
    Add-WslUser -Distribution $Distribution -Credential $cred

    # Set the default user via wsl.conf (idempotent)
    Write-Host "Ensuring default user is '$Username' via wsl.conf..."
    $userLower = $Username.ToLower()
    $wslConfContent = "[user]`ndefault = $userLower`n"
    # Write configuration inside the Linux distribution
    $wslConfContent | wsl -d $Distribution -u root sh -c "cat > /etc/wsl.conf"

    # Restart the distribution to apply the new default user
    Write-Host "Restarting distribution to apply changes..."
    wsl --terminate $Distribution

    Write-Host "Installation/configuration of '$Distribution' completed." -ForegroundColor Green
}

# Ensure WSL isolation settings are correct in /etc/wsl.conf
function Ensure-WslIsolation {
    param(
        [Parameter(Mandatory)]
        [string]$Distribution
    )

    Write-Host "=== Ensuring WSL Isolation ===" -ForegroundColor Cyan

    # Function to update a specific section/key
    function Update-WslConfSetting {
        param(
            [string]$Section,
            [string]$Key,
            [string]$Value,
            [string]$Distribution
        )

        $scriptBlock = @"
set -e
CONF="/etc/wsl.conf"
SECTION="$Section"
KEY="$Key"
VALUE="$Value"

# Create file if missing
touch "\$CONF"

# Ensure section exists (add if missing)
if ! grep -q "^\[$SECTION\]" "\$CONF"; then
    echo >> "\$CONF"
    echo "[$SECTION]" >> "\$CONF"
fi

# Update or add the key-value pair inside the section
# This sed command will:
# - Inside the section, replace existing key=... with key=value
# - If the key does not exist in the section, add it at the end of the section
awk -v section="[$SECTION]" -v key="$KEY" -v val="$VALUE" '
BEGIN { in_section=0; key_found=0; }
/^\[.*\]/ {
    if (in_section && !key_found) {
        print key " = " val;
    }
    in_section = (\$0 == section);
    key_found = 0;
    print;
    next;
}
in_section && !key_found && \$1 == key {
    print key " = " val;
    key_found = 1;
    next;
}
{ print }
END {
    if (in_section && !key_found) {
        print key " = " val;
    }
}' "\$CONF" > "\$CONF.tmp" && mv "\$CONF.tmp" "\$CONF"
"@
        # Execute the script inside WSL
        $scriptBlock | wsl -d $Distribution -u root bash
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set $Section/$Key = $Value in /etc/wsl.conf"
        }
    }

    # Set automount: enabled = false
    Update-WslConfSetting -Section "automount" -Key "enabled" -Value "false" -Distribution $Distribution

    # Set interop: appendWindowsPath = false, enabled = false
    Update-WslConfSetting -Section "interop" -Key "appendWindowsPath" -Value "false" -Distribution $Distribution
    Update-WslConfSetting -Section "interop" -Key "enabled" -Value "false" -Distribution $Distribution

    Write-Host "WSL isolation settings are correctly configured." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 2. Main Script
# -----------------------------------------------------------------------------

try {
    # Load configuration from .env
    $envVars = Load-Env -FilePath ".\.env"

    # Validate required variables
    $required = @("DISTRO_NAME", "USER_NAME", "USER_PASSWORD")
    foreach ($var in $required) {
        if (-not $envVars.ContainsKey($var)) {
            throw "Missing required variable '$var' in .env file."
        }
    }

    $distroName   = $envVars["DISTRO_NAME"]
    $userName     = $envVars["USER_NAME"]
    $userPassword = $envVars["USER_PASSWORD"]

    # Convert plain password to SecureString
    $securePass = ConvertTo-SecureString $userPassword -AsPlainText -Force

    # Ensure the distribution is installed and configured
    Ensure-WslDistro -Distribution $distroName -Username $userName -Password $securePass

    # Set as default WSL distribution only if not already default
    Write-Host "Ensuring '$distroName' is the default WSL distribution..." -ForegroundColor Cyan
    $currentDefault = wsl --status | Select-String "Default Distribution:" | ForEach-Object { ($_ -split ":")[1].Trim() }
    if ($currentDefault -ne $distroName) {
        wsl --set-default $distroName
        Write-Host "Default distribution set to '$distroName'." -ForegroundColor Green
    } else {
        Write-Host "'$distroName' is already the default distribution." -ForegroundColor Green
    }

    # Ensure isolation (disable Windows PATH and automount)
    Ensure-WslIsolation -Distribution $distroName

    # Copy and execute internal setup script if present
    $internalScript = "opencode/wsl_install.sh"
    if (Test-Path $internalScript) {
        Write-Host "=== Executing internal setup script ===" -ForegroundColor Cyan
        try {
            # Copy script to WSL (overwrites existing)
            Write-Host "Copying $internalScript to /tmp/ inside WSL..."
            Get-Content $internalScript -Raw | wsl -d $distroName -u root sh -c "cat > /tmp/wsl_install.sh"
            if ($LASTEXITCODE -ne 0) { throw "Failed to copy script." }

            # Make executable
            wsl -d $distroName -u root chmod +x /tmp/wsl_install.sh
            if ($LASTEXITCODE -ne 0) { throw "Failed to set executable permissions." }

            # Execute with environment variables
            Write-Host "Running $internalScript as root..."
            wsl -d $distroName -u root env USER_NAME="$userName" USER_PASSWORD="$userPassword" bash /tmp/wsl_install.sh
            if ($LASTEXITCODE -ne 0) { throw "Script failed with exit code $LASTEXITCODE." }

            Write-Host "Internal setup completed successfully." -ForegroundColor Green
        } catch {
            Write-Warning "Internal setup encountered an error: $_"
        } finally {
            # Clean up script file
            wsl -d $distroName -u root rm -f /tmp/wsl_install.sh 2>$null
        }
    } else {
        Write-Warning "Internal setup script '$internalScript' not found in current directory. Skipping..."
    }

    # Shut down WSL to apply all changes (wsl.conf and any changes made by internal script)
    Write-Host "Shutting down WSL to apply changes..." -ForegroundColor Cyan
    wsl --shutdown

    Write-Host @"

=== Installation completed successfully ===
- Windows programs have been removed from PATH inside WSL.
- Windows drives are no longer automatically mounted.
- The default user is '$userName'.
- Internal setup script executed (if present).

Please open a new WSL terminal to verify the configuration.
"@ -ForegroundColor White

} catch {
    Write-Error "Script failed: $_"
    exit 1
}