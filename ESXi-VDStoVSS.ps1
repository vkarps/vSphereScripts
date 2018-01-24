<#
.SYNOPSIS
  Migrates target ESXi host and it's virtual machines from the defined vDS to the defined vSS
.DESCRIPTION
  This script will perform the following steps:
  - A Standard virtual switch will be created based off the Distributed switch defined 
  - Step the host into the vDS with the defined adapter $pnic1
  - Disable DRS on the cluster which the host resides in
  - Migrate virtual machines from the vDS to the newly created vSS
  - Migrate the hosts VMKernel ports from the vDS to the vSS
  - Migrate the second adapter from the vDS to the vSS and remove the host from the vDS
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
  ./ESXi-VDStoVSS.ps1
#>

#user defined variables
$srcvCenter = "VC01.karpslab.local"
$vmHost = "ESXi-01.karpslab.local"
$pNIC1 = "vmnic2"
$pNIC2 = "vmnic3"
$vDS = "vDS-Cluster-01"
$vSS = "MigSwitch"
$vmk1pg = "vDS-Cluster-01-VL10-NFS"
$vmk2pg = "vDS-Cluster-01-VL20-vMotion1"
$vmk3pg = "vDS-Cluster-01-VL20-vMotion2"


#Connect to Source vCenter
if (Connect-VIServer -Server $srcvCenter -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -force) {
      Write-Host "Connected to $srcvCenter" -ForegroundColor green
    } 
    else {
      Write-Host "Could not connect to vCenter server $srcvCenter" -ForegroundColor Red 
      Write-host "Error:" -ForegroundColor red $Error[0]  
      Break
    }

##########################
# Standard vSwitch Setup #
##########################

#Get vDS Details
$vDSobj = Get-VDSwitch -Name $vDS
$vDSpg = $vdsObj | Get-VDPortgroup

#Create vSwitch
Write-Host "Creating standard switch $vss based off $vds" -ForegroundColor Yellow
$vSSObj = New-VirtualSwitch -VMHost $vmHost -Name $vss -mtu $vDSObj.mtu

#Create Port Groups
foreach($pg in $vDSpg){
    #Get port group VLAN ID
    $pgVLAN = $pg.Extensiondata.Config.DefaultPortConfig.Vlan.VlanID
    #Check if it is the uplink pg
    If ($pg.IsUplink -eq "True"){Write-Host "Skipping Uplink PortGroup" -ForegroundColor yellow}
    #If it is not the uplink pg, create it on the vSS
    else{
        New-VirtualPortGroup -Name $pg.name -VirtualSwitch $vSSObj -VLanId $pgVLAN | Out-null
        Write-Host "Created PortGroup $pg with Vlan ID $pgVLAN" -ForegroundColor Cyan
    }
}

Write-Host "Stepping $Vmhost into $vss" -Foregroundcolor Yellow
#Get physical adapter
$pNIC1Obj = Get-VMHostNetworkAdapter -VMhost $vmhost -Physical -name $pNIC1
#Remove specified adapter from vDS
Write-Host "Removing $pnic1 from $vds" -ForegroundColor Cyan
$pNIC1Obj | Remove-VDSwitchPhysicalNetworkAdapter -Confirm:$false
# Add specified adapter to newly created vSS
Write-Host "Migrating $pNIC1 from $vDS to $vss" -ForegroundColor Cyan
Add-VirtualSwitchPhysicalNetworkAdapter -VirtualSwitch $vSSObj -VMHostPhysicalNic $pnic1Obj -Confirm:$false

#Validate if user wishes to continue
Write-Host "Please validate that the vSwitch and Portgroups have been created correctly before proceeding" -ForegroundColor Red 
$continue = Read-Host "Would you like to continue to migrating VM networks (Y/N)?"
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
  Write-Host "Continuing to VM Network Migration" -ForegroundColor Green
}

########################
# VM Network Migration #
########################

#Set Cluster DRS Setting to Manual
$VMhostObj = Get-VMHost $VMhost
$ClusterObj = Get-Cluster -Name $VMhostObj.Parent
Write-Host "Setting DRS for Cluster $clusterObj to Manual" -ForegroundColor Cyan
Set-Cluster -Cluster $clusterObj -DrsAutomationLevel Manual -Confirm:$false |Out-Null

#Get List of virtual machines that are running on the host
$VMlist = $VMhostObj | get-VM

#Migrate VM Networks
Write-Host "Now migrating VM networks from $vds to $vss" -ForegroundColor Yellow
foreach ($VM in $VMlist){
   $VMnic = Get-NetworkAdapter $vm
   $VMnic | Set-NetworkAdapter -PortGroup (Get-VirtualPortGroup -VMhost  $VMHost -Standard -Name $vmnic.NetworkName)
   Write-Host "Migrated $VM network to $vSS on $VMhost" -ForegroundColor Cyan
}

#Validate if user wishes to continue
Write-Host "Please validate that the the VMs are available and on the vSS" -ForegroundColor Red 
$continue = Read-Host "Would you like to continue to migrating VMKernel Ports (Y/N)?"
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
  Write-Host "Continuing to VMKernel Migration" -ForegroundColor Green
}

######################
# VMKernel Migration #
######################
# This section was taken from https://www.virtuallyghetto.com/2013/11/automate-reverse-migrating-from-vsphere.html and modified to suit this scenario

#Get pNic and swtich objects
$pNIC2Obj = Get-VMHostNetworkAdapter -VMhost $vmhost -Physical -name $pNIC2
$vSSObj = Get-VirtualSwitch -VMhost $VMhost -Name $vSS

#Get VMK ports to migrate
$vmk1 = Get-VMHostNetworkAdapter -VMhost $vmhost -VMKernel -name vmk1
$vmk2 = Get-VMHostNetworkAdapter -VMhost $vmhost -VMKernel -name vmk2
$vmk3 = Get-VMHostNetworkAdapter -VMhost $vmhost -VMKernel -name vmk3

#get VMK port groups to migrate to
$vmk1pgObj = Get-virtualportgroup -virtualswitch $vssObj -name $vmk1pg
$vmk2pgObj = Get-virtualportgroup -virtualswitch $vssObj -name $vmk2pg
$vmk3pgObj = Get-virtualportgroup -virtualswitch $vssObj -name $vmk3pg

#create array of VMKports and VMKPortGroups
$vmkArray =@($vmk1,$vmk2,$vmk3)
$vmkpgArray =@($vmk1pgObj,$vmk2pgObj,$vmk3pgObj)

#Move physical nic and VMK ports from vDS to vSS
Write-Host "Migrating $vmhost from $vds to $vss" -ForegroundColor Cyan
Add-VirtualSwitchPhysicalNetworkAdapter -VirtualSwitch $vssObj -VMHostPhysicalNic $pNIC2Obj -VMHostVirtualNic $vmkarray -VirtualNicPortgroup $vmkpgarray  -Confirm:$false

#remove host from vds
Write-Host "Removing $vmhost from $vds" -ForegroundColor Cyan
$vdsObj | Remove-VDSwitchVMHost -VMHost $vmhost -Confirm:$false

Write-host "Script has completed, host has now been migrated from $vDS to $vss" -ForegroundColor green
#disconnect from src vCenter
disconnect-viserver $srcvCenter -confirm:$flase
