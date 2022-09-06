#------------------Script for automatic packaging and replication of PVS images on device collections-----------------#
# 1) Data is loaded from an XML file (Names of PVS servers, Site Name, Name of a collection of writable changes to images, 
# associations of store names and collections of devices for subsequent binding of images from these Stores
# 2) The enabled devices from the collection are checked to record changes to the images and the image is packaged: 
# SCOM, SCCM certificates, RDL Grace Period are cleared. Shutting down services and turning off the device
# 3) Each image is transferred to standard mode, copied to all PVS servers, added to COD 2 PVS servers
# 4) Images are assigned to device collections according to an XML file
# 
# Version 1.2.0 - 2022 Eldar Akhmetov
# 
#---------------------------------------------------------------------------------------------------------------------#

# Importing the Image class
Using module ".\Classes\Image.psm1"

# Importing the DeviceWR class
Using module ".\Classes\DeviceWR.psm1"

# Importing a module to work with PVS
Import-Module "C:\Program Files\Citrix\Provisioning Services Console\Citrix.PVS.SnapIn.dll"

# Importing the image packaging script
. ".\Scripts\prepareImage.ps1"

# Connecting to a local PVS server
Set-PvsConnection -Server localhost

# Creating a name for the log file with the current date
$date = get-date -Format "yyyy.MM.dd"
$global:logfile = "$($PSScriptRoot)\logs\$($date)-log.log"

# The function of recording a log file
function global:LogWrite {
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

    # The request from the console will be the user enters the device names in edit mode manually or they will be obtained from the collection of devices for editing images
    [String[]]$devicesWRName = $null
    $message = "You want to enter the names of devices with connected images manually, enter [Y] or the images of all enabled devices from the $($devicesCollectionWR) collection will be prepared and assigned, enter [N]. [Y/N]"
    $response = (Read-Host -Prompt $message).ToLower()
    if ($response -eq "y" -or $response -eq "n") {
        if ($response -eq "y") {
            $message = "Enter the device names separated by commas for images preparation and subsequent replication"
            $devicesWRName = (Read-Host -Prompt $message) -split "," -replace " "
            foreach ($device in $devicesWRName) {
                if (![DeviceWR]::GetDeviceActiveStatus($deviceName)) {
                    Write-Verbose -Message "The $($device) device is turned off! To pack a connected image, the device must be turned on." -Verbose
                }
            }
        }
        if ($response -eq "n") {
            # Getting all the devices from the device collection to make changes to the images
            $devicesWRName = (Get-PvsDevice -CollectionName $devicesCollectionWR -SiteName $siteName | Select-Object DeviceName).DeviceName
        } 
    }
    else {
        Write-Verbose -Message "You entered an incorrect value!!!" -Verbose
    }

    [DeviceWR[]]$devicesObjectsWR = $null
    [System.Management.Automation.Job[]]$jobs_PrepareImage = $null
}
catch [Exception] {
    throw $_
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
