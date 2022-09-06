#---------------------------------------------Class Device Writeable--------------------------------------------------#
# To create an instance of a class, you must pass arguments:
# deviceName - The device name is the same as in the PVS farm
# siteName - PVS Farm Site Name

# Image - An instance of an object of the Image class is created in the constructor, 
# the missing arguments for creating an image object are taken from the results of executing methods of the current class
# 
# Version 1.2.0 - 2022 Eldar Akhmetov
# 
#---------------------------------------------------------------------------------------------------------------------#

Using module ".\Image.psm1"

class DeviceWR {
    [String]$deviceName
    [String]$siteName
    [Image]$Image

    DeviceWR (
        [String]$deviceName,
        [String]$siteName
    ) {
        $this.deviceName = [ValidateNotNullOrEmpty()]$deviceName
        $this.siteName = [ValidateNotNullOrEmpty()]$siteName
        $this.Image = [Image]::New($this.GetImageNameConnectedtoDevice(), $this.GetStoreNameImageLocation(), $this.siteName, $this.deviceName)
    }
    
    #---------------------------------------------------------------------------------------------------------------------#

    #----------------------Getting the name of the connected image its store name and device status-----------------------#
    # Getting the name of the image connected to the device
    # Returns $null if no image is connected to the device
    [Object]GetImageNameConnectedtoDevice() {
        [String]$imageName = $null
        try {
            $imageName = (Get-PvsDeviceInfo -DeviceName $this.deviceName | Select-Object DiskLocatorName).DiskLocatorName -split ".+\\"
            $imageName = $imageName -replace " "
        }
        catch {
            LogWrite -str $_.exception.Message
            Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
        }
        if (!([string]::IsNullOrEmpty($imageName))) {
            return $imageName
        }
        else {
            $message = "Images are not connected to the $($this.deviceName) device"
            LogWrite -str $message
            Write-Warning -Message $message
            return $null
        }
    } 

    # Getting the name of the store where the image is located
    # Returns $null if no image is connected to the device
    [Object]GetStoreNameImageLocation() {
        [String]$storeName = $null
        try {
            $storeName = (Get-PvsDeviceInfo -DeviceName $this.deviceName | Select-Object DiskLocatorName).DiskLocatorName -split "\\.+"
            $storeName = $storeName -replace " "
        }
        catch {
            LogWrite -str $_.exception.Message
            Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
        }
        if (!([string]::IsNullOrEmpty($storeName))) {
            return $storeName
        }
        else {
            $message = "Images are not connected to the $($this.deviceName) device"
            LogWrite -str $message
            Write-Warning -Message $message
            return $null
        }
    }  
    
    # Getting the device status: enabled "true", disabled "false"
    # To get the status, the device name must be passed to the method
    static [Object]GetDeviceActiveStatus([String]$deviceName) {
        try {
            [boolean]$status = (Get-PvsDeviceInfo -DeviceName $deviceName | Select-Object Active).Active
            return $status
        }
        catch {
            LogWrite -str $_.exception.Message
            Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
            return $null
        }
    }
    #---------------------------------------------------------------------------------------------------------------------#
    
    #----------------------------Preparing an image for replication and turning off the device----------------------------#
    # The method creates jobs for executing code on remote machines, the code cleans certificates and stops services for the subsequent replication of the reference image.
    # After creating a job, the method returns it for subsequent processing of the work results
    [Object]RunImagePackaging() {
        try {
            if (($null -ne [DeviceWR]::GetDeviceActiveStatus($this.deviceName)) -and ($true -eq [DeviceWR]::GetDeviceActiveStatus($this.deviceName))) {
                $job_PrepareImage = Invoke-Command -ScriptBlock $global:prepareImage -ComputerName $this.deviceName -AsJob
                $message = "The process of packaging the $($this.GetImageNameConnectedtoDevice()) image on the $($this.deviceName) device has been started!"
                LogWrite -str $message 
                Write-Verbose -Message $message -Verbose
                return $job_PrepareImage
            }
            else {
                $message = "Image $($this.GetImageNameConnectedtoDevice()) cannot be packed, the $($this.deviceName) device is turned off!"
                LogWrite -str $message
                Write-Error -Message $message
                return $null
            }
                         
        }
        catch {
            LogWrite -str $_.exception.Message
            Write-Error -Message $_.Exception.Message -Category $_.CategoryInfo.Category -ErrorId $_.FullyQualifiedErrorId
            return $null
        }
    }

}
#---------------------------------------------------------------------------------------------------------------------#