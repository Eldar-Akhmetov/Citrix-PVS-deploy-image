#------------------------------------------The image packaging script------------------------------------------------#
#
# The script is executed on the included virtual machines PVS with the connected image in private mode
# SCOM, SCCM certificates, RDS Grace Period are cleared.
# The Windows Update service is being terminated and disabled and the device is being turned off.
# 
# Version 1.2.0 - 2022 Eldar Akhmetov
# 
#---------------------------------------------------------------------------------------------------------------------#

$global:prepareImage = {
    $definition = @"
using System;
using System.Runtime.InteropServices;
namespace Win32Api
{
          public class NtDll
          {
                    [DllImport("ntdll.dll", EntryPoint="RtlAdjustPrivilege")]
                    public static extern int RtlAdjustPrivilege(ulong Privilege, bool Enable, bool CurrentThread, ref bool Enabled);
          }
}
"@
    $KeyPath_GracePeriod = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod"
    $CertPath_SMS = "Cert:\LocalMachine\SMS"
    $KeyCertPath_SMS = "HKLM:\Software\Microsoft\SystemCertificates\SMS\Certificates"
    $CertPath_MonAgent = "Cert:\LocalMachine\Microsoft Monitoring Agent"
    $KeyCertPath_MonAgent = "HKLM:\Software\Microsoft\SystemCertificates\Microsoft Monitoring Agent\Certificates"
    if (Test-Path $KeyPath_GracePeriod) {
        try {
            try { Add-Type -TypeDefinition $definition -PassThru } catch {}
            $bEnabled = $false
            $res = [Win32Api.NtDll]::RtlAdjustPrivilege(9, $true, $false, [ref]$bEnabled)
            $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod", [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::takeownership)
            $acl = $key.GetAccessControl()
            if ([ADSI]::Exists("WinNT://localhost/Администраторы")) { $AdminGroup = "Администраторы" }
            else { $AdminGroup = "Administrators" }
            $acl.SetOwner([System.Security.Principal.NTAccount]$AdminGroup)
            $key.SetAccessControl($acl)
            $rule = New-Object System.Security.AccessControl.RegistryAccessRule ($AdminGroup, "FullControl", "Allow")
            $acl.SetAccessRule($rule)
            $key.SetAccessControl($acl)
            Remove-Item $KeyPath_GracePeriod
        }
        catch {
            Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
        }
    }
    #endregion
    # delete users profiles, except sysmtem and current user
    try { 
        Get-WmiObject win32_userprofile -filter "Special='False'" | ForEach-Object { $_.Delete() }
    }
    catch {}
    # Cleanup SCCM cache
    $resman = New-Object -ComObject "UIResource.UIResourceMgr"
    $cacheInfo = $resman.GetCacheInfo()
    try {
        $cacheinfo.GetCacheElements()  | ForEach-Object { $cacheInfo.DeleteCacheElement($_.CacheElementID) }
    }
    catch {}
    #endregion
    # SCCM reset
    if (Get-Service CcmExec) {
        Stop-Service CcmExec
    }
    if (Test-Path $CertPath_SMS) {
        try {
            Get-ChildItem $CertPath_SMS -Recurse | Where-Object subject -match "SMS" | Remove-Item 
        }
        catch {
            Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
        }
    }
    if (Test-Path $KeyCertPath_SMS) {
        try {
            Remove-Item -path "$($KeyCertPath_SMS)\*" -Force
            Remove-Item -path "c:\windows\smscfg.ini"
        }
        catch {
            Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
        }
    }
    
    # SCOM reset
    if (Get-Service HealthService) {
        Stop-Service HealthService
    }
    if (Test-Path $CertPath_MonAgent) {
        try {
            Get-ChildItem $CertPath_MonAgent -Recurse | Where-Object subject -match $domain | Remove-Item
            Remove-Item -path "$($KeyCertPath_MonAgent)\*" -Force
        }
        catch {
            Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
        }
    }
    # wuausrv disabling and stop
    Set-Service wuauserv -StartupType Disabled
    Stop-Service wuauserv
    Write-Warning -Message "$($env:computername) The image is prepared for packaging!"
    Stop-Computer -Force
}

#---------------------------------------------------------------------------------------------------------------------#