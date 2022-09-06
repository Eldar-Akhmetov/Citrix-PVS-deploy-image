#---------------------------------------------------Class Image-------------------------------------------------------#

# To create an instance of a class, you must specify the arguments:
# imageName - The name of the PVS image must be specified similarly to the name of the VHDX file
# storeName - Name of the store where the image is stored
# siteName - PVS Farm Site Name
# deviceWR - The device on which the image is loaded for making changes

# This argument does not need to be passed, the name of the PVS server from which the image is downloaded in private mode
# serverProvisioning - The server name will be obtained when creating an instance of the class, if the load balancing algorithm is enabled for the image, the value will be $null
# 
# Version 1.2.0 - 2022 Eldar Akhmetov
# 
#---------------------------------------------------------------------------------------------------------------------#

class Image {
    [String]$imageName
    [String]$storeName
    [String]$siteName
    [String]$deviceWR
    [String]$serverProvisioning

    Image (
        [String]$imageName,
        [String]$storeName,
        [String]$siteName,
        [String]$deviceWR
    ) {
        $this.imageName = [ValidateNotNullOrEmpty()]$imageName
        $this.storeName = [ValidateNotNullOrEmpty()]$storeName
        $this.siteName = [ValidateNotNullOrEmpty()]$siteName
        $this.deviceWR = [ValidateNotNullOrEmpty()]$deviceWR
        $this.serverProvisioning = $this.GetServerProvisioningPrivateMode()
    }
    #---------------------------------------------------------------------------------------------------------------------#
    
    #------------Checking the availability of the disk in the store PVS and adding the disk to the desired store-----------#

    # Checking the availability of the disk in the store PVS
    # Takes the name PVS Store in arguments, returns boolean value
    [Object]GetPvsImageExists([String]$pvsStore) {
        [String]$pvsImage = $null
        try {
            $pvsImage = Get-PvsDisk -DiskLocatorName $this.imageName -StoreName $pvsStore -SiteName $this.siteName
            if (!([string]::IsNullOrEmpty($pvsImage))) {
                return $true
            }
            else {
                return $false
            }
        }
        catch {
            Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
            return $false
        }
    }

    # Adding an existing image file to the PVS storage
    # In the arguments, you must pass the type of image and the size of the cache in RAM (Megabytes)
    # Disk Types: 0 (Private), (other values are standard image) 1 (Cache on Server), 3 (Cache in Device RAM), 4 (Cache on Device Hard Disk),
    # 6 (Device RAM Disk), 7 (Cache on Server, Persistent), or 9 (Cache in Device RAM with Overflow on Hard Disk)
    [Void]AddExistingImageOnStorePVS([String]$pvsStore, [Int]$WriteCacheType, [Int]$writeCacheSize) {
        if (!$this.GetPvsImageExists($pvsStore)) {
            try {      
                New-PvsDiskLocator -DiskLocatorName $this.imageName -StoreName $pvsStore -SiteName $this.siteName -VHDX 
                $message = "$($this.imageName) image added to PVS Store $($pvsStore)"
                LogWrite -str $message
                Write-Verbose -Message $message -Verbose
            }
            catch {
                LogWrite -str $_.exception.Message
                Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
            }
        }
        else {
            $message = "The image $($this.imageName) already exists in the $($pvsStore) PVS store!"
            LogWrite -str $message
            Write-Warning -Message $message
            return
        }
    }
    #---------------------------------------------------------------------------------------------------------------------#
    
    #-------------------------------Getting and changing the write cache type of the image--------------------------------#

    # Method for getting the type of disk cache entry, returns values:: 
    # 0 (Private), (other values are standard image) 1 (Cache on Server), 3 (Cache in Device RAM), 4 (Cache on Device Hard Disk),
    # 6 (Device RAM Disk), 7 (Cache on Server, Persistent), or 9 (Cache in Device RAM with Overflow on Hard Disk)
    [Object]GetWriteCacheType([String]$storeName) {
        try { 
            [Int]$writeCacheType = (Get-PvsDisk -DiskLocatorName $this.imageName -StoreName $storeName -SiteName $this.siteName | Select-Object WriteCacheType).WriteCacheType
            return $writeCacheType
        }
        catch {
            Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
            return $null
        }
    }

    # Getting the name of the provisioning server from which the image is downloaded in private mode
    # If the image mode is Standard, then $null will be returned and a warning about the need to change the disk mode
    [Object]GetServerProvisioningPrivateMode() {
        $this.serverProvisioning = $null
        if ($this.GetWriteCacheType($this.storeName) -eq 0) {
            try {
                $this.serverProvisioning = (Get-PvsDiskInfo -DiskLocatorName $this.imageName -StoreName $this.storeName -SiteName $this.siteName | Select-Object ServerName).ServerName
            }
            catch {
                LogWrite -str $_.exception.Message
                Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
            }
            return $this.serverProvisioning
        }
        if ($this.GetWriteCacheType($this.storeName) -gt 0) {
            $message = "The mode of this $($this.imageName) disk is standard, you need to change the mode to private to request a PVS server!"
            LogWrite -str $message
            Write-Warning -Message $message
            return $this.serverProvisioning
        }        
        else {
            $message = "Check the correctness of the transmitted data, this image was not found. Couldn't find the $($this.imageName) image!"
            LogWrite -str $message
            Write-Error -Message $message
            return $this.serverProvisioning
        }        
    }

    # Method assigns the cache entry type "Standard" for the image, WriteCacheType values ranging from 1-9:
    # 1 (Cache on Server), 3 (Cache in Device RAM), 4 (Cache on Device Hard Disk), 6 (Device RAM Disk), 7 (Cache on Server, Persistent), or 9 (Cache in Device RAM with Overflow on Hard Disk)
    # writeCacheSize the value of megabytes for the size of the image cache in RAM
    [Void]SetWriteCacheTypeStandard([String]$storeName, [Int]$WriteCacheType, [Int]$writeCacheSize) {
        if (0 -eq $this.GetWriteCacheType($storeName)) {
            if (($WriteCacheType -ge 1) -and ($WriteCacheType -le 9)) {
                try {
                    [String[]]$diskLockDevice = (Get-PvsDiskLocatorLock -DiskLocatorName $this.imageName -StoreName $storeName -SiteName $this.siteName | Select-Object DeviceName).DeviceName
                    if ($diskLockDevice.Count -eq 0) {
                        try { Remove-PvsDiskLocatorFromDevice -DiskLocatorName $this.imageName -StoreName $storeName -SiteName $this.siteName } catch {}
                        Remove-PvsDiskLocator -DiskLocatorName $this.imageName -StoreName $storeName -SiteName $this.siteName 
                        New-PvsDiskLocator -DiskLocatorName $this.imageName -StoreName $storeName -SiteName $this.siteName -VHDX
                        Set-PvsDisk -Name $this.imageName -StoreName $storeName -SiteName $this.siteName -WriteCacheType $WriteCacheType -WriteCacheSize $writeCacheSize
                        Add-PvsDiskLocatorToDevice -DiskLocatorName $this.imageName -StoreName $storeName -SiteName $this.siteName -DeviceName $this.deviceWR -RemoveExisting
                        $message = "Write Cache Type of the $($this.imageName) image has been converted to Standard"
                        LogWrite -str $message
                        Write-Verbose -Message $message -Verbose
                    }
                    if ($diskLockDevice.Count -gt 0) {
                        if (($diskLockDevice.Count -eq 1) -and ($diskLockDevice[0] -eq $this.deviceWR)) {
                            Unlock-PvsDisk -DiskLocatorName $this.imageName -StoreName $storeName -SiteName $this.siteName
                            try { Remove-PvsDiskLocatorFromDevice -DiskLocatorName $this.imageName -StoreName $storeName -SiteName $this.siteName } catch {}
                            Remove-PvsDiskLocator -DiskLocatorName $this.imageName -StoreName $storeName -SiteName $this.siteName
                            New-PvsDiskLocator -DiskLocatorName $this.imageName -StoreName $storeName -SiteName $this.siteName -VHDX
                            Set-PvsDisk -Name $this.imageName -StoreName $storeName -SiteName $this.siteName -WriteCacheType $WriteCacheType -WriteCacheSize $writeCacheSize
                            Add-PvsDiskLocatorToDevice -DiskLocatorName $this.imageName -StoreName $storeName -SiteName $this.siteName -DeviceName $this.deviceWR -RemoveExisting
                            $message = "Write Cache Type of the $($this.imageName) image has been converted to Standard"
                            LogWrite -str $message
                            Write-Verbose -Message $message -Verbose
                        }
                        else {
                            $message = "Image $($this.imageName) locked by a virtual machine $($diskLockDevice)"
                            LogWrite -str $message
                            Write-Error -Message $message
                        }
                    }
                }
                catch {
                    LogWrite -str $_.exception.Message
                    Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
                }
            }
            else {
                Write-Error -Message "Invalid value for Write Cache Type, the value must be in the range from 1-9!"
            }
        }
        else {
            $message = "The type of image cache entry $($this.imageName) is already standard!"
            LogWrite -str $message
            Write-Warning -Message $message
        }
    }

    # Method changes the image mode to Private
    # You must specify the Provisioning server
    [Void]SetWriteCacheTypePrivate([String]$storeName, [String]$serverProvisioning) {
        try {
            Set-PvsDisk -Name $this.imageName -StoreName $storeName -SiteName $this.siteName -WriteCacheType "0"
            Set-PvsDiskLocator -DiskLocatorName $this.imageName -StoreName $storeName -SiteName $this.siteName -ServerName $serverProvisioning
            $message = "The type of the $($this.imageName) image cache entry has been changed to private!"
            LogWrite -str $message
            Write-Warning -Message $message
        }
        catch {
            LogWrite -str $_.exception.Message
            Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
        }
    }
    #---------------------------------------------------------------------------------------------------------------------#

    #--------------------------------Adding a disk to a device or to a collection of devices-------------------------------#

    # Assigning an image to a device
    # To add an image to a device, you need to pass the store name and the name of the device to the method
    [Void]AddImageToDevice([String]$storeName, [String]$deviceName) {
        try {
            Add-PvsDiskLocatorToDevice -DiskLocatorName $this.imageName -StoreName $storeName -SiteName $this.siteName -DeviceName $deviceName -RemoveExisting
            $message = "The $($this.imageName) image is assigned to device: $($deviceName)" 
            LogWrite -str $message
            Write-Verbose -Message $message -Verbose
        }
        catch {
            LogWrite -str $_.exception.Message
            Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
        }
    }

    # Assigning a device collection image
    # To add an image for a collection of devices, you need to pass the name of the storage and the name of the collection of devices to the method
    [Void]AddImageToDeviceCollection([String]$storeName, [String]$deviceCollection) {
        try {
            Add-PvsDiskLocatorToDevice -DiskLocatorName $this.imageName -StoreName $storeName -SiteName $this.siteName -CollectionName $deviceCollection -RemoveExisting
            $message = "The $($this.imageName) image is assigned to devices from the collection: $($deviceCollection)" 
            LogWrite -str $message
            Write-Verbose -Message $message -Verbose
        }
        catch {
            LogWrite -str $_.exception.Message
            Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
        }  
    }

    # Assigning an image to multiple device collections
    # To add an image for multiple device collections, you need to pass to the method an array [PSCustomObject[]] containing objects [PSCustomObject] in the form: 
    # Name = [String]"Store name" ; DeviceCollection = [String]"Name or Names of Device Collections" (Device Collection name separator ",")"
    [Void]AddImageToMultipleDeviceCollections([PSCustomObject[]]$stores) {
        try {
            foreach ($store in $stores) {
                if ($this.GetPvsImageExists($store.Name)) {
                    [String[]]$deviceCollections = $store.DeviceCollection -split "," -replace " "
                    $deviceCollections | ForEach-Object { Add-PvsDiskLocatorToDevice -DiskLocatorName $this.imageName -StoreName $store.Name -SiteName $this.siteName -CollectionName $_ -RemoveExisting }
                    $message = "The $($this.imageName) image is assigned to devices from the collection: $($store.DeviceCollection)" 
                    LogWrite -str $message
                    Write-Verbose -Message $message -Verbose
                }
            }
        }
        catch {
            LogWrite -str $_.exception.Message
            Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
        }  
    }
    #---------------------------------------------------------------------------------------------------------------------#

    #---------------------------Copying images to the PVS servers stores using robocopy.exe-------------------------------#
    # Copying each image is started in a separate process, after copying, the presence of errors and the completion code of the process are checked
    # if the exit code is equal to "1", then the files have been copied successfully
    [Void]CopyImage([PSCustomObject[]]$pvsServers) {
        try {
            [String]$imagePath_COD1 = (Get-PvsDiskInfo -DiskLocatorName $this.imageName -StoreName $this.storeName -SiteName $this.siteName | Select-Object OriginalFile).OriginalFile -replace "\\$($this.imageName).vhdx", ""
        }
        catch {
            LogWrite -str $_.exception.Message
            Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
            return
        }
        $imageFileName = $this.imageName + ".vhdx"
        $pvpFileName = $this.imageName + ".pvp"
        [System.Diagnostics.Process[]]$processes = $null
        $procID_ServerName = @{}
        if (($null -ne $this.GetWriteCacheType($this.storeName)) -and (0 -ne $this.GetWriteCacheType($this.storeName))) {
            foreach ($server in $pvsServers) {
                if (($this.serverProvisioning -ne $server.Name) -and ($null -ne $this.serverProvisioning)) {
                    try {
                        $copyPathUNC = ("\\$($server.Name)\$($imagePath_COD1 -replace ":","$" ` -replace "COD\d", $server.COD)")
                        if (!(Test-Path "$($copyPathUNC)\$($imageFileName)")) {
                            $process = New-Object System.Diagnostics.Process 
                            $argumentList = "$($imagePath_COD1) $($copyPathUNC) $($imageFileName) $($pvpFileName) /R:2 /W:5"
                            $process.StartInfo = New-Object System.Diagnostics.ProcessStartInfo("robocopy", $argumentList)
                            $process.StartInfo.CreateNoWindow = $true
                            $process.StartInfo.UseShellExecute = $false
                            $process.Start() | Out-Null
                            $processes += $process
                            $procID_ServerName.Add(($process.Id), ($server.Name))
                            $message = "Starting copying of the $($this.imageName) image to the store of the $($server.Name) PVS server"
                            LogWrite -str $message
                            Write-Verbose -Message $message -Verbose
                        }
                        else {
                            $message = "The image file $($this.imageName) exists in the Store of the $($server.Name) server"
                            LogWrite -str $message
                            Write-Error -Message $message
                        }
                    }
                    catch {
                        LogWrite -str $_.exception.Message
                        Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
                    }
                }
            }
            if ($processes.Count -gt 0) {
                $processes | ForEach-Object { try { $_.WaitForExit() } catch {} }
                foreach ($process in $processes) {
                    if ($process.ExitCode -eq 1) {
                        $message = "The $($this.imageName) image was successfully copied to the server $($procID_ServerName.($process.Id))"
                        LogWrite -str $message
                        Write-Verbose -Message $message -Verbose
                        $process.Dispose()
                    }
                    else {
                        $message = "Error copying the $($this.imageName) image to the server $($procID_ServerName.($process.Id))"
                        LogWrite -str $message
                        Write-Error -Message $message
                    }
                }
            }
        }
        else {
            $message = "The writer cache type of the $($this.imageName) image is private, to copy the image to PVS servers, you need to change the type to standard!"
            LogWrite -str $message
            Write-Error -Message $message
            return
        }
    }
}
#---------------------------------------------------------------------------------------------------------------------#