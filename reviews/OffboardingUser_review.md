# Review: OffboardingUser.ps1

**Reviewer:** Claude Code (4net AG)
**Datum:** 2026-06-15
**Script-Stand:** "irgendwann 2023" (kein Versionsstempel)

---

## Gesamtbewertung

| Kategorie                  | Bewertung |
|----------------------------|-----------|
| Sicherheit                 | 🔴 Kritisch |
| Veraltete Module / Cmdlets | 🔴 Kritisch |
| Fehlerbehandlung           | 🔴 Kritisch |
| Logging / Nachvollziehbarkeit | 🟠 Mangelhaft |
| Code-Qualität & Lesbarkeit | 🟡 Ausbaufähig |

---

## 1. Sicherheitsprobleme 🔴

### S-01 – Hardcodiertes Passwort (KRITISCH)
```powershell
$pw = "Temp1234!"
Set-MsolUserPassword -UserPrincipalName $user -NewPassword $pw -ForceChangePassword $false
```
**Problem:** Das Temporärpasswort steht im Klartext im Script. Jeder mit Lesezugriff auf den Code kennt das Passwort. Es wird zudem nie geändert (`ForceChangePassword $false`).

**Empfehlung:** Zufälliges Passwort generieren (z. B. mit `[System.Web.Security.Membership]::GeneratePassword()`) oder aus einem Secret Vault (z. B. Azure Key Vault) beziehen. `ForceChangePassword` auf `$true` setzen.

---

### S-02 – Keine Eingabevalidierung (KRITISCH)
```powershell
param($user, $manager)
```
**Problem:** Keine Typisierung, keine Pflichtfeld-Prüfung. Wird `$user` leer übergeben, können MSOL-Cmdlets auf alle User oder auf ungültige Objekte angewendet werden. Dies kann zu unbeabsichtigtem Massenschaden führen.

**Empfehlung:**
```powershell
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$User,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ManagerEmail
)
```

---

### S-03 – `Get-PSSession | Remove-PSSession` entfernt alle Sessions
```powershell
Get-PSSession | Remove-PSSession
```
**Problem:** Beendet **alle** PowerShell-Sessions auf dem ausführenden Rechner, nicht nur jene des Offboarding-Users. Kann parallel laufende Prozesse oder andere Admin-Sessions unterbrechen.

**Empfehlung:** Sessions gezielt nach dem Verbindungsaufbau speichern und nur diese entfernen.

---

## 2. Veraltete Module / Cmdlets 🔴

Das Script verwendet ausschliesslich das **MSOnline-Modul (MSOL)**, das von Microsoft offiziell abgekündigt wurde (End of Life: März 2024 für neue Tenants, vollständige Abschaltung in Vorbereitung).

| Veraltetes Cmdlet | Ersatz (Microsoft.Graph) |
|---|---|
| `Connect-MsolService` | `Connect-MgGraph` |
| `Set-MsolUser -BlockCredential` | `Update-MgUser -AccountEnabled $false` |
| `Set-MsolUserPassword` | `Update-MgUser` mit `PasswordProfile` |
| `Revoke-MsolUserAllRefreshTokens` | `Revoke-MgUserSignInSession` |
| `Get-MsolUserGroupMembership` | `Get-MgUserMemberOf` |
| `Remove-MsolGroupMember` | `Remove-MgGroupMemberByRef` |
| `Get-MsolUser` | `Get-MgUser` |
| `Set-MsolUserLicense` | `Set-MgUserLicense` |

**Empfehlung:** Vollständige Migration auf `Microsoft.Graph` (Modul `Microsoft.Graph.Users`, `Microsoft.Graph.Groups`, `Microsoft.Graph.Identity.SignIns`).

---

## 3. Fehlende Fehlerbehandlung 🔴

Das gesamte Script hat **kein einziges `try/catch`-Block**. Schlägt ein Schritt fehl (z. B. User nicht gefunden, Netzwerkfehler, fehlende Berechtigungen), läuft das Script ungehindert weiter.

**Mögliche Konsequenzen:**
- Lizenz wird nicht entfernt, weil vorheriger Schritt still scheiterte
- Weiterleitung wird gesetzt, obwohl User nicht blockiert wurde
- Keine Fehlermeldung an den Operator

**Empfehlung:** Jeden kritischen Schritt in `try/catch` kapseln, `$ErrorActionPreference = 'Stop'` setzen, Fehler loggen und Script bei kritischem Fehler abbrechen.

---

## 4. Logging / Nachvollziehbarkeit 🟠

Das einzige Log-Statement ist:
```powershell
Write-Host "Fertig."
```

**Probleme:**
- Kein Timestamp
- Kein Protokoll welcher User offboardet wurde
- Kein Audit-Trail bei Fehlern
- Kein Output-Log für Tickets oder Compliance-Anforderungen

**Empfehlung:** Strukturiertes Logging mit Zeitstempel und Schritt-Bestätigungen. Optionale Ausgabe in eine Log-Datei oder ins Windows Event Log.

---

## 5. Code-Qualität & Lesbarkeit 🟡

| Problem | Empfehlung |
|---|---|
| Parametername `$manager` ist mehrdeutig (E-Mail? UPN? DisplayName?) | Umbenennen zu `$ManagerEmail` |
| Kein `[CmdletBinding()]` / kein `-WhatIf`-Support | `[CmdletBinding(SupportsShouldProcess)]` hinzufügen für Dry-Run |
| Kein Versionskommentar, kein Autor, kein Änderungsprotokoll | Header-Block ergänzen |
| `$licenses.AccountSkuId` funktioniert nicht korrekt bei mehreren Lizenzen | Korrekt iterieren mit `foreach` |

---

## Zusammenfassung der Massnahmen

| Priorität | Massnahme |
|---|---|
| 🔴 Sofort | Hardcodiertes Passwort entfernen |
| 🔴 Sofort | Eingabevalidierung hinzufügen |
| 🔴 Kurzfristig | Migration auf Microsoft.Graph |
| 🔴 Kurzfristig | `try/catch`-Fehlerbehandlung implementieren |
| 🟠 Mittelfristig | Strukturiertes Logging einführen |
| 🟡 Mittelfristig | `SupportsShouldProcess` / `-WhatIf` ergänzen |
