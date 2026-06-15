#Requires -Modules Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.SignIns
<#
.SYNOPSIS
    Offboarding eines Microsoft 365 Benutzers.
.DESCRIPTION
    Deaktiviert den Account, setzt das Passwort zurueck, widerruft Sessions,
    richtet Mailweiterleitung ein, entfernt Gruppenmitgliedschaften und Lizenzen.
.PARAMETER User
    UPN des zu offboardenden Benutzers (z. B. max.muster@contoso.com)
.PARAMETER ManagerEmail
    UPN des Managers, an den E-Mails weitergeleitet werden sollen.
.EXAMPLE
    .\OffboardingUser.ps1 -User max.muster@contoso.com -ManagerEmail chef@contoso.com
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$User,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ManagerEmail
)

$ErrorActionPreference = 'Stop'

# --- Logging-Hilfsfunktion ---
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line
    Add-Content -Path "$PSScriptRoot\offboarding_$(Get-Date -Format 'yyyyMMdd').log" -Value $line
}

# --- Zufaelliges Passwort generieren (mind. 16 Zeichen, Gross/Klein/Zahl/Sonderzeichen) ---
function New-SecureRandomPassword {
    $chars  = 'abcdefghijkmnopqrstuvwxyz'
    $upper  = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $digits = '23456789'
    $special= '!@#$%&*?'
    $all    = ($chars + $upper + $digits + $special).ToCharArray()
    $pwd    = (
        ($chars.ToCharArray()   | Get-Random),
        ($upper.ToCharArray()   | Get-Random),
        ($digits.ToCharArray()  | Get-Random),
        ($special.ToCharArray() | Get-Random)
    )
    $pwd += 1..12 | ForEach-Object { $all | Get-Random }
    return -join ($pwd | Get-Random -Count $pwd.Count)
}

# --- Verbindung aufbauen ---
Write-Log "Starte Offboarding fuer: $User"

try {
    Connect-MgGraph -Scopes 'User.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.ReadWrite.All' -NoWelcome
    Connect-ExchangeOnline -ShowBanner:$false
    Write-Log "Verbindung zu Microsoft Graph und Exchange Online hergestellt."
}
catch {
    Write-Log "Verbindung fehlgeschlagen: $_" -Level ERROR
    throw
}

# --- User-Objekt abrufen ---
try {
    $mgUser = Get-MgUser -UserId $User -Property Id, DisplayName, AssignedLicenses
    Write-Log "Benutzer gefunden: $($mgUser.DisplayName) (ID: $($mgUser.Id))"
}
catch {
    Write-Log "Benutzer '$User' nicht gefunden: $_" -Level ERROR
    throw
}

# --- 1. Account deaktivieren ---
try {
    if ($PSCmdlet.ShouldProcess($User, 'Account deaktivieren')) {
        Update-MgUser -UserId $mgUser.Id -AccountEnabled:$false
        Write-Log "Account deaktiviert: $User"
    }
}
catch {
    Write-Log "Fehler beim Deaktivieren des Accounts: $_" -Level ERROR
    throw
}

# --- 2. Passwort zuruecksetzen ---
try {
    if ($PSCmdlet.ShouldProcess($User, 'Passwort zuruecksetzen')) {
        $newPassword = New-SecureRandomPassword
        $passwordProfile = @{
            Password                      = $newPassword
            ForceChangePasswordNextSignIn = $true
        }
        Update-MgUser -UserId $mgUser.Id -PasswordProfile $passwordProfile
        # Passwort wird bewusst nicht geloggt – nur Hinweis, dass Aktion erfolgte
        Write-Log "Passwort zurueckgesetzt (zufaellig generiert, ForceChange=true)."
    }
}
catch {
    Write-Log "Fehler beim Passwort-Reset: $_" -Level ERROR
    throw
}

# --- 3. Alle aktiven Sessions widerrufen ---
try {
    if ($PSCmdlet.ShouldProcess($User, 'Sign-in Sessions widerrufen')) {
        Revoke-MgUserSignInSession -UserId $mgUser.Id | Out-Null
        Write-Log "Alle Sign-in Sessions widerrufen."
    }
}
catch {
    Write-Log "Fehler beim Widerrufen der Sessions: $_" -Level ERROR
    throw
}

# --- 4. Mailweiterleitung einrichten ---
try {
    if ($PSCmdlet.ShouldProcess($User, "Mailweiterleitung zu $ManagerEmail einrichten")) {
        Set-Mailbox -Identity $User -ForwardingSmtpAddress $ManagerEmail -DeliverToMailboxAndForward $false
        Write-Log "Mailweiterleitung eingerichtet: $User -> $ManagerEmail"
    }
}
catch {
    Write-Log "Fehler beim Einrichten der Mailweiterleitung: $_" -Level ERROR
    throw
}

# --- 5. Aus allen Gruppen entfernen ---
try {
    $memberships = Get-MgUserMemberOf -UserId $mgUser.Id -All |
                   Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' }

    Write-Log "Gefundene Gruppenmitgliedschaften: $($memberships.Count)"

    foreach ($group in $memberships) {
        try {
            if ($PSCmdlet.ShouldProcess($group.Id, "Benutzer aus Gruppe entfernen")) {
                Remove-MgGroupMemberByRef -GroupId $group.Id -DirectoryObjectId $mgUser.Id
                Write-Log "Aus Gruppe entfernt: $($group.Id)"
            }
        }
        catch {
            # Warnung statt Abbruch – dynamische Gruppen koennen nicht manuell geaendert werden
            Write-Log "Gruppe konnte nicht entfernt werden (z. B. dynamisch): $($group.Id) – $_" -Level WARN
        }
    }
}
catch {
    Write-Log "Fehler beim Abrufen der Gruppenmitgliedschaften: $_" -Level ERROR
    throw
}

# --- 6. Lizenzen entfernen ---
try {
    $assignedLicenses = $mgUser.AssignedLicenses
    if ($assignedLicenses.Count -gt 0) {
        if ($PSCmdlet.ShouldProcess($User, "$($assignedLicenses.Count) Lizenz(en) entfernen")) {
            Set-MgUserLicense -UserId $mgUser.Id -AddLicenses @() -RemoveLicenses $assignedLicenses.SkuId
            Write-Log "Lizenzen entfernt: $($assignedLicenses.SkuId -join ', ')"
        }
    }
    else {
        Write-Log "Keine Lizenzen zugewiesen, kein Schritt erforderlich."
    }
}
catch {
    Write-Log "Fehler beim Entfernen der Lizenzen: $_" -Level ERROR
    throw
}

Write-Log "Offboarding abgeschlossen fuer: $User"
