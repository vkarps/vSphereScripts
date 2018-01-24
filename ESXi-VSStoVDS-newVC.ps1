<#
.SYNOPSIS
  Migrates target ESXi host and it's virtual machines from one vCenter to another and migrates it to the defined Distributed Switch
.DESCRIPTION
  This Script will perform the following steps:
  - Disconnect the defined host from the current vCenter and remove it from the inventory
  ** It is assumed that the host is entirely on a standard switch **
  - Connect the defined host to the defined destination vCenter
  - Migrate the host and the virtual machines running on it to the defined Distributed Switch
  ** it is assumed that the target cluster and vDS have already been configured **
  - Move VMs into their correct folders
  ** it is assumed that the target vCenter already has the folders created **

.INPUTS none
  
.OUTPUTS None
  
.NOTES
  If there are additional vmkernel ports, they will need to be defined in the script, otherwise it will fail and may cause an outage.

  Version:        1.0
  Author:         vKARPS
  Twitter: @vKARPS
  Blog: vkarps.wordpress.com
  Creation Date:  23/01/18
  Purpose/Change: Initial script creation
  
.EXAMPLE
  ./ESXi-VSStoVDS-NewVC.ps1
#>

# Define Functions required to discover VM Folders and to move VMs to the correct folders
# Thanks to http://kunaludapi.blogspot.com.au 
function Get-VMFolderPath {  
    <#  
    .SYNOPSIS  
    Get folder path of Virtual Machines  
    .DESCRIPTION  
    The function retrives complete folder Path from vcenter (Inventory >> Vms and Templates)  
    .NOTES   
    Author: Kunal Udapi  
    http://kunaludapi.blogspot.com  
    .PARAMETER N/a  
    No Parameters Required  
    .EXAMPLE  
     PS> Get-VM vmname | Get-VMFolderPath  
    .EXAMPLE  
     PS> Get-VM | Get-VMFolderPath  
    .EXAMPLE  
     PS> Get-VM | Get-VMFolderPath | Out-File .\vmfolderPathlistl.txt  
    #>  
     #####################################    
     ## http://kunaludapi.blogspot.com    
     ## Version: 1    
     ## Windows 8.1   
     ## Tested this script on    
     ## 1) Powershell v4    
     ## 2) VMware vSphere PowerCLI 6.0 Release 1 build 2548067    
     ## 3) Vsphere 5.5    
     #####################################    
      Begin {} #Begin  
      Process {  
        foreach ($vm in $Input) {  
          $DataCenter = $vm | Get-Datacenter  
          $DataCenterName = $DataCenter.Name  
          $VMname = $vm.Name  
          $VMParentName = $vm.Folder  
          if ($VMParentName.Name -eq "vm") {  
            $FolderStructure = "{0}\{1}" -f $DataCenterName, $VMname  
            $FolderStructure  
            Continue  
          }#if ($VMParentName.Name -eq "vm")  
          else {  
            $FolderStructure = "{0}\{1}" -f $VMParentName.Name, $VMname  
            $VMParentID = Get-Folder -Id $VMParentName.ParentId  
            do {  
              $ParentFolderName = $VMParentID.Name  
              if ($ParentFolderName -eq "vm") {  
                $FolderStructure = "$DataCenterName\$FolderStructure"  
                $FolderStructure  
                break  
              } #if ($ParentFolderName -eq "vm")  
              $FolderStructure = "$ParentFolderName\$FolderStructure"  
              $VMParentID = Get-Folder -Id $VMParentID.ParentId  
            } #do  
            until ($VMParentName.ParentId -eq $DataCenter.Id) #until  
          } #else ($VMParentName.Name -eq "vm")  
        } #foreach ($vm in $VMList)  
      } #Process  
      End {} #End  
} #function Get-VMFolderPath
function Move-VMtoFolderPath {  
    <#  
    .SYNOPSIS  
    Move VM to folder path  
    .DESCRIPTION  
    The function retrives complete folder Path from vcenter (Inventory >> Vms and Templates)  
    .NOTES   
    Author: Kunal Udapi  
    http://kunaludapi.blogspot.com  
    .PARAMETER N/a  
    No Parameters Required  
    .EXAMPLE  
     PS> Get-Content -Path c:\temp\VmFolderPathList.txt | Move-VMtoFolderPath  
    #>  
     #####################################    
     ## http://kunaludapi.blogspot.com    
     ## Version: 1    
     ##    
     ## Tested this script on    
     ## 1) Powershell v4    
     ## 2) VMware vSphere PowerCLI 6.0 Release 1 build 2548067    
     ## 3) Vsphere 5.5    
     #####################################    
      Foreach ($FolderPath in $Input) {  
        $list = $FolderPath -split "\\"  
        $VMName = $list[-1]  
        $count = $list.count - 2  
        0..$count | ForEach-Object {  
             $number = $_  
          if ($_ -eq 0 -and $count -gt 2) {  
                  $Datacenter = Get-Datacenter $list[0]  
             } #if ($_ -eq 0)  
          elseif ($_ -eq 0 -and $count -eq 0) {  
                  $Datacenter = Get-Datacenter $list[$_]  
                  #VM already in Datacenter no need to move  
            Continue  
          } #elseif ($_ -eq 0 -and $count -eq 0)  
          elseif ($_ -eq 0 -and $count -eq 1) {  
            $Datacenter = Get-Datacenter $list[$_]  
          } #elseif ($_ -eq 0 -and $count -eq 1)  
          elseif ($_ -eq 0 -and $count -eq 2) {  
            $Datacenter = Get-Datacenter $list[$_]  
          } #elseif ($_ -eq 0 -and $count -eq 2)  
             elseif ($_ -eq 1) {  
                  $Folder = $Datacenter | Get-folder $list[$_]  
             } #elseif ($_ -eq 1)  
             else {  
            $Folder = $Folder | Get-Folder $list[$_]  
             } #else  
        } #0..$count | foreach  
        Move-VM -VM $VMName -Destination $Folder | out-null
        Write-Host "Moved $VMName to $Folder" -ForegroundColor Cyan  
      } #Foreach ($FolderPath in $VMFolderPathList)  
}#function Set-FolderPath


# user defined variables
$srcvCenter = "VC01.karpslab.local"
$dstvCenter = "VC02.karpslab.local"
$dstCluster = "Cluster-01"
$vmHost = "ESXi-01.karpslab.local"
$pNIC1 = "vmnic2"
$pNIC2 = "vmnic3"
$vDS = "vDS-Cluster-01"
$vSS = "MigSwitch"
$vmk1pg = "vDS-Cluster-01-VL10-NFS"
$vmk2pg = "vDS-Cluster-01-VL20-vMotion1"
$vmk3pg = "vDS-Cluster-01-VL20-vMotion2"

#Connect to vCenter
$srcVCCreds = Get-Credential -Message "Enter credentials for $srcvCenter"
if (Connect-VIServer -Server $srcvCenter -credential $srcVCCreds -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -force) {
  Write-Host "Connected to $srcvCenter" -ForegroundColor green
} 
else {
  Write-Host "Could not connect to vCenter server $srcvCenter" -ForegroundColor Red 
  Write-host "Error:" -ForegroundColor red $Error[0]  
  Break
}

###############################
# Get VM Folders #
###############################
$VMhostObj = Get-VMhost $VMhost
$VMlist = $VMhostObj | get-VM
$VMFolders = $VMlist | Get-VMFolderPath
#############
# Move Host #
#############
Write-Host "Moving $vmhost" -ForegroundColor Yellow
## Disconnect Host from vCenter
Write-Host "Disconnecting $VMhost from $srcvCenter" -ForegroundColor Cyan
Set-VMhost $vmhost -State "Disconnected" | out-null 
# Remove host from Inventory
Write-Host "Removing $VMhost from $srcvCenter" -ForegroundColor Cyan
Remove-VMhost $vmhost -server $srcvCenter -Confirm:$false

#disconnect from source vCenter
disconnect-viserver $srcvCenter -confirm:$false

#Connect to $dst vCenter
$dstVCCreds = Get-Credential -Message "Enter credentials for $dstvCenter"
if (Connect-VIServer -Server $dstvCenter -Credential $dstVCCreds -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -force) {
  Write-Host "Connected to $dstvCenter" -ForegroundColor green
} 
else {
  Write-Host "Could not connect to vCenter server $dstvCenter" -ForegroundColor Red 
  Write-host "Error:" -ForegroundColor red $Error[0]  
  Break
}

# Add host to new vCenter
$ESXcreds = Get-Credential -Username root -Message "Enter the root password for $vmhost"
$location = Get-Cluster $dstCluster
Add-VMhost -Server $dstvCenter -Name $vmHost -Location $location -Credential $ESXcreds | out-null
Write-Host "Please validate that $VMhost has been added to $dstvCenter"
#Prompt to continue or exit
$continue = Read-Host "Would you like to continue to adding the host to the vDS (Y/N)?"
while("Y","N" -notcontains $continue)
{
	$continue = Read-Host "Please enter Y or N" 
}
if ($continue -eq "N")
{
  Write-Host "Exiting Script" -ForegroundColor Red
  break
}elseif ($continue -eq "Y") 
{
  Write-Host "Continuing to vDS Migration" -ForegroundColor Green
}
######################
# Step host into vDS #
######################
#add host to vDS
Write-Host "Adding $VMhost and $pNIC1 to $vDS" -ForegroundColor Cyan
$vdsObj = Get-VDSwitch $vDS
$vdsObj | Add-VDSwitchVMHost -VMHost $vmhost | Out-Null

#Migrate first adapter to vDS
$pNIC1Obj = Get-VMHostNetworkAdapter -VMhost $vmhost -Physical -name $pNIC1
$vdsObj | Add-VDSwitchPhysicalNetworkAdapter -VMHostNetworkAdapter $pNIC1Obj -Confirm:$false

#Prompt to continue or exit
Write-Host "Please validate that the $vmhost and $pnic1 have been added to $vds" -ForegroundColor Red
$continue = Read-Host "Would you like to continue to VMKernel migration (Y/N)?"
while("Y","N" -notcontains $continue)
{
	$continue = Read-Host "Please enter Y or N"
}
if ($continue -eq "N")
{
  Write-Host "Exiting Script" -ForegroundColor Red
  break
}elseif ($continue -eq "Y") 
{
  Write-Host "Continuing to VMKernel migration" -ForegroundColor Green
}

######################
# VMKernel Migration #
######################

#Migrate vmk1
Write-Host "Migrating vmk1 to $vDS" -ForegroundColor Cyan
$vmk1pgObj = Get-VDPortgroup -name $vmk1pg -VDSwitch $vdsObj
$vmk1 = Get-VMHostNetworkAdapter -Name vmk1 -VMHost $vmhost
Set-VMHostNetworkAdapter -PortGroup $vmk1pgObj -VirtualNic $vmk1 -confirm:$false | Out-Null
Write-Host "Please validate that the vmk1 has migrated successfully" -ForegroundColor Red

#Prompt to continue or exit
$continue = Read-Host "Would you like to continue migrating the next vmkernel port vmk2 (Y/N)?"
while("Y","N" -notcontains $continue)
{
	$continue = Read-Host "Please enter Y or N"
}
if ($continue -eq "N")
{
  Write-Host "Exiting Script" -ForegroundColor Red
  break
}elseif ($continue -eq "Y") 
{
  Write-Host "Continuing VMKernel migration" -ForegroundColor Green
}
#Migrate Vmk2
Write-Host "Migrating vmk2 to $vDS" -ForegroundColor Cyan
$vmk2pgObj = Get-VDPortgroup -name $vmk2pg -VDSwitch $vdsObj
$vmk2 = Get-VMHostNetworkAdapter -Name vmk2 -VMHost $vmhost
Set-VMHostNetworkAdapter -PortGroup $vmk2pgObj -VirtualNic $vmk2 -confirm:$false | Out-Null
Write-Host "Please validate that the vmk2 has migrated successfully" -ForegroundColor Red

#Prompt to continue or exit
$continue = Read-Host "Would you like to continue migrating the next vmkernel port vmk3 (Y/N)?"
while("Y","N" -notcontains $continue)
{
	$continue = Read-Host "Please enter Y or N"
}
if ($continue -eq "N")
{
  Write-Host "Exiting Script" -ForegroundColor Red
  break
}elseif ($continue -eq "Y") 
{
  Write-Host "Continuing VMKernel migration" -ForegroundColor Green
}

#Migrate vmk3
Write-Host "Migrating vmk3 to $vDS" -ForegroundColor Cyan
$vmk3pgObj = Get-VDPortgroup -name $vmk3pg -VDSwitch $vdsObj
$vmk3 = Get-VMHostNetworkAdapter -Name vmk3 -VMHost $vmhost
Set-VMHostNetworkAdapter -PortGroup $vmk3pgObj -VirtualNic $vmk3 -confirm:$false | Out-Null
Write-Host "Please validate that the vmk3 has migrated successfully" -ForegroundColor Red

#Prompt to continue or exit
$continue = Read-Host "Would you like to being migrating the Virtual Machine Networks (Y/N)?"
while("Y","N" -notcontains $continue)
{
	$continue = Read-Host "Please enter Y or N"
}
if ($continue -eq "N")
{
  Write-Host "Exiting Script" -ForegroundColor Red
  break
}elseif ($continue -eq "Y") 
{
  Write-Host "Continuing to Virtual Machine Network Migration" -ForegroundColor Green
}

########################
# VM Network Migration #
########################

#migrate VM networking
$VMhostObj = Get-VMhost $VMhost
$VMlist = $VMhostObj | get-VM
Write-Host "Now migrating VM networks from $vss to $vds" -ForegroundColor Yellow
foreach ($VM in $VMlist){
   $VMnic = Get-NetworkAdapter $vm
   $VMnic | Set-NetworkAdapter -PortGroup (Get-VirtualPortGroup -VMhost  $VMHost -Distributed -Name $vmnic.NetworkName) -Confirm:$false | out-null
   Write-Host "Migrated $VM network to vSS on $VMhost" -ForegroundColor Cyan
}
Write-Host "Completed migrating VM Networks, please validate that they're operational" -ForegroundColor Red

#Prompt to continue or exit
$continue = Read-Host "Would you like migrate the remaining NIC to $vDS (Y/N)?"
while("Y","N" -notcontains $continue)
{
	$continue = Read-Host "Please enter Y or N" -ForegroundColor Blue
}
if ($continue -eq "N")
{
  Write-Host "Exiting Script" -ForegroundColor Red
  break
}elseif ($continue -eq "Y") 
{
  Write-Host "Continuing migrating host from $vss to $vds" -ForegroundColor Green
}

########################
# Cutover last adapter #
########################

#Migrate second adapter to vDS
$pNIC2Obj = Get-VMHostNetworkAdapter -VMhost $vmhost -Physical -name $pNIC2
$vdsObj | Add-VDSwitchPhysicalNetworkAdapter -VMHostNetworkAdapter $pNIC2Obj -Confirm:$false

#Prompt to continue or exit
Write-Host "Please validate that the $pNIC2 has been added to $vDS" -ForegroundColor Red
$continue = Read-Host "Would you like to remove $vss (Y/N)?"
while("Y","N" -notcontains $continue)
{
	$continue = Read-Host "Please enter Y or N"
}
if ($continue -eq "N")
{
  Write-Host "Exiting Script" -ForegroundColor Red
  break
}elseif ($continue -eq "Y") 
{
  Write-Host "Continuing to cleanup tasks" -ForegroundColor Green
}

###############################
# Move VMs to correct folders #
###############################
Write-Host "Moving VMs to correct folders" -ForegroundColor Yellow
$VMfolders | Move-VMtoFolderPath
##################
# Remove vSwitch #
##################
#Remove vSwitch
$vssObj = Get-VirtualSwitch -VMhost $VMhost -Name $vss
Remove-VirtualSwitch $vssObj -confirm:$False
Write-Host "Removed $vss from $Vmhost" -ForegroundColor Cyan
Write-Host "Script has completed" -ForegroundColor Green
Disconnect-viserver $dstvCenter -confirm:$False