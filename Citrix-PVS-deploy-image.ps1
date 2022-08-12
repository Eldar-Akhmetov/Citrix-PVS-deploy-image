#------------------Script for automatic packaging and replication of PVS images on device collections-----------------#
# 1) Data is loaded from an XML file (Names of PVS servers, Site Name, Name of a collection of writable changes to images, 
# associations of store names and collections of devices for subsequent binding of images from these Stores
# 2) The enabled devices from the collection are checked to record changes to the images and the image is packaged: 
# SCOM, SCCM certificates, RDL Grace Period are cleared. Shutting down services and turning off the device
# 3) Each image is transferred to standard mode, copied to all PVS servers, added to COD 2 PVS servers
# 4) Images are assigned to device collections according to an XML file
#---------------------------------------------------------------------------------------------------------------------#

# Uploading a file with classes
. "$($PSScriptRoot)\Classes.ps1"

# Importing a module to work with PVS
Import-Module "C:\Program Files\Citrix\Provisioning Services Console\Citrix.PVS.SnapIn.dll"
Set-PvsConnection -Server localhost

# Creating a name for the log file with the current date
$date = get-date -Format "yyyy.MM.dd"
$global:logfile = "$($PSScriptRoot)\logs\$($date)-log.log"

# The function of recording a log file
function LogWrite {
    param(
        [Parameter(Mandatory = $true)]
        $str
    )
    $date = get-date -Format "yyyy.MM.dd hh:mm:ss"
    [String]$log_str = $date + ": " + $str
    $log_str | Out-File -filepath $global:logfile -Encoding UTF8 -Append
}

# Downloading the XML configuration file
try {
    [xml]$Setting = Get-Content -Path "$($PSScriptRoot)\Setting.xml"
}
catch [Exception] {
    $message = "$($PSScriptRoot)\Setting.xml Error loading the configuration file!"
    LogWrite -str $message
    throw $_
}

[PSCustomObject[]]$stores = $null

try {
    # Getting a store and collections of devices for assigning orders
    Select-Xml $Setting -XPath '/configuration/StoresAndDevices/Associated_Stores' | ForEach-Object { $stores += New-Object -TypeName PSCustomObject @{ Name = $_.Node.Store ; DeviceCollection = $_.Node.DeviceCollection } }

    # Getting the site name
    [String]$siteName = Select-Xml $Setting -XPath '/configuration/Setting/SiteName'

    [String]$domain = Select-Xml $Setting -XPath '/configuration/Setting/Domain'

    # Getting a devices collection  for recording changes to images
    [String]$devicesCollectionWR = Select-Xml $Setting -XPath '/configuration/Setting/WR_DeviceCollection'

    # Getting PVP servers COD 1
    [String[]]$serversPVS_COD1 = (Select-Xml $Setting -XPath '/configuration/Setting/ServersPVS_COD1') -replace " "

    #Getting PVP servers COD 2
    [String[]]$serversPVS_COD2 = (Select-Xml $Setting -XPath '/configuration/Setting/ServersPVS_COD2') -replace " "

    # Creating a PSCustomObject with the names of PVS servers and COD membership
    [PSCustomObject[]]$pvsServers = $null
    $pvsServers += $serversPVS_COD1 -split "," | ForEach-Object { New-Object -TypeName PSCustomObject @{ Name = $_ ; COD = "COD1" } }
    $pvsServers += $serversPVS_COD2 -split "," | ForEach-Object { New-Object -TypeName PSCustomObject @{ Name = $_ ; COD = "COD2" } }

    # Getting all the devices from the device collection to make changes to the images
    #[String[]]$devicesWRName = (Get-PvsDevice -CollectionName $devicesCollectionWR -SiteName $siteName | Select-Object DeviceName).DeviceName
    [DeviceWR[]]$devicesObjectsWR = $null
    [System.Management.Automation.Job[]]$jobs_PrepareImage = $null
}
catch [Exception] {
    throw $_
}

# The image packaging script is executed on the end device with the image in private mode
$global:prepareImage_Script = {
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

# A loop is executed, if the device for making changes to the image is enabled, then we create a Device object and execute the script for preparing the image for replication
foreach ($deviceName in $devicesWRName) {
    if ([DeviceWR]::GetDeviceActiveStatus($deviceName)) {
        [DeviceWR]$device = [DeviceWR]::New($deviceName, $siteName)
        # We execute the script for preparing the image for replication, the method returns a Job to track the execution of the task
        $job = $device.RunImagePackaging()
        # If the task is not empty, then add it to the array and add the device object to the array
        if ($null -ne $job) {
            $jobs_PrepareImage += $job
            $devicesObjectsWR += $device
        }
    }
}
# We are waiting for the completion of the jobs
if ($null -ne $jobs_PrepareImage) {
    $jobs_PrepareImage | Wait-Job
    foreach ($deviceObject in $devicesObjectsWR) {
        # The cycle does not end until all devices are turned off
        while ([DeviceWR]::GetDeviceActiveStatus($deviceObject.deviceName)) {
        }
        $message = "The process of packaging the $($deviceObject.GetImageNameConnectedtoDevice()) image on the $($deviceObject.deviceName) device has been completed successfully, the device is off!"
        LogWrite -str $message
        Write-Verbose -Message $message -Verbose
    }
}

foreach ($deviceObject in $devicesObjectsWR) {
    # We check that each image is in private mode and is provided from one PVS server
    if ($null -ne $deviceObject.Image.GetServerProvisioningPrivateMode()) {
        $pvsStoreCOD2 = $deviceObject.Image.storeName -replace "COD\d", "COD2"
        # We change the disk mode to the standard one with writing the cache to RAM and to disk
        $deviceObject.Image.SetWriteCacheTypeStandard($deviceObject.Image.storeName, 9, 4096)
        # We copy the images to all the PVS servers
        $deviceObject.Image.CopyImage($pvsServers)
        # Adding an image to the COD 2 PVP server
        $deviceObject.Image.AddExistingImageOnStorePVS($pvsStoreCOD2, 9, 4096)
        # Assigning images to device collections
        $deviceObject.Image.AddImageToMultipleDeviceCollections($stores)

    }
    else {
        $message = "The $($this.imageName) disk is in private cache write mode, but use load balancing algorithm, will change the load balancing algorithm to one PVS server!"
        LogWrite -str $message
        Write-Warning -Message $message
    }
}

Read-Host "To exit, press 'Enter'"
