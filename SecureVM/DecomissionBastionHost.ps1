#region 0_HEADER

#			 
# --------------------------------------------------------------------
#endregion HEADER

#region Properties

$EnvironmentName 	= ""								#customer name based in 3chars nameconvention
$MgmtRGName 		= "$($EnvironmentName)-mgt-rg"	#Default Management. RG where Automation account is located
$Role 				= "bho"								#Role Tag for VM (always bho so don't modify)

#endregion


#region modules and dependencies

	Add-Type -AssemblyName System.web

#endregion


#region methods

# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function ResetVMPassword ([object] $VM) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{	
    write-warning "Updating VM $($VMName) password process started..."
	$password = [System.Web.Security.Membership]::GeneratePassword(16,1)
	$secpassword = ConvertTo-SecureString $password -AsPlainText -Force
	$Credential  = New-Object System.Management.Automation.PSCredential ("$($VM.Name)", $secpassword)
			
	$result = Set-AzureRmVMAccessExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Name "ResetPassword" -Location $VM.location -Credential $Credential -TypeHandlerVersion "2.0"
	
	write-output "Bastion Host $($VM.Name) credentials have been updated"
	
	$userinfo += New-Object -TypeName psobject -Property @{User="$($VM.Name)"; Password=$password; UserType="bhoaccount"}
	
	return $userinfo
}

# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function RedeployVM ([object] $VM) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{	
	
	$oldDisk = get-azureRMDisk -ResourceGroupName $MgmtRGName | where {$_.Name -like "$($VM.Name)_OsDisk_*"}
	
	
	# This section is required for decrypting already attached disk. Still not working
	#write-warning "Current Disk for bastion host $($VM.Name) is being unencrypted before swapping..."
	#$prc1 = $VM | Start-AzureRmVM
	#start-sleep 10
	#Remove-AzureRmVMDiskEncryptionExtension -ResourceGroupName $MgmtRGName -VMName $VM.Name -confirm:$false -force
	#$prc2 = $VM | Stop-AzureRmVM -confirm:$false -force
	
	write-warning "Disk for bastion host $($VM.Name) will be recreated..."
	write-warning "Redeploying bastion host $($VM.Name) from snapshot and restarting..."
    
	$snapshot = Get-AzureRmSnapshot -ResourceGroupName $MgmtRGName | where {$_.Name -eq "$($VM.Name)_OsDisk_Snapshot"}
	$diskconf = New-AzureRmDiskConfig -AccountType Standard_LRS -Location   $snapshot.Location -SourceResourceId $snapshot.Id -CreateOption Copy 
	$rnd = (Get-Random -Minimum 0 -Maximum 99999).ToString('00000')
	$disk = New-AzureRmDisk -Disk $diskconf -ResourceGroupName $MgmtRGName -DiskName "$($VM.Name)_OsDisk_$($rnd)"
	$newDisk = Set-AzureRmVMOSDisk -VM $vm -ManagedDiskId $disk.Id -Name $disk.Name 
	
	$result = Update-AzureRmVM -ResourceGroupName $MgmtRGName -VM $vm
	
	return $oldDisk
	

}

# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function UpdateVMTags ([object] $VM ) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{	
	write-warning "Updating Tag information for bastion host $($VM.Name)..."
    
	$tags = @{"Roles" = $Role ; "LastProvision" = ""}
	
	Set-AzureRmResource -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -ResourceType "Microsoft.Compute/VirtualMachines" -Tag $tags -confirm:$false -force
}

# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function  GetVMsToDecomissions([object] $VMs ) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{	
	$VMsToDecomission = @()
	foreach ($VM in $VMs)
	{
		$now = get-date -f "MM-dd-yy HH:mm:ss"
		$provisionTime = (Get-AzureRmVM -ResourceGroupName $MgmtRGName -Name $VM.Name).Tags.LastProvision
		
		if ($provisionTime){$TimeDiff = New-TimeSpan $provisionTime $now }
		
		#Array for Vms powered on at least 3h
		if ( $TimeDiff.Hours -gt 2 ){ $VMsToDecomission += $VM }
	}
	
	return $VMsToDecomission
	
}

# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function ApplyHardeningPolicy ([object] $VM ) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{
	$stgaccount = Get-AzureRmStorageAccount | where {$_.tags.Roles -eq "hardening"}
	
	$stgaccKey = ($stgaccount | Get-AzureRmStorageAccountKey | where {$_.KeyName -eq "Key1"}).Value
	
	write-warning "Applying hardening local policy settings for bastion host $($VM.Name)..."
										
	Set-AzureRMVMCustomScriptExtension 	–ExtensionName "HardeningExtension"  `
										–ResourceGroupName $VM.ResourceGroupName `
										–Location  $VM.Location `
										–VMName $VM.Name `
										–StorageAccountName $stgaccount.storageAccountName `
										–StorageAccountKey $stgaccKey `
										–FileName "Add-LocalSecurityPolicy.ps1" `
										–ContainerName "scripts"
								
}

# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function AddSecretsToKeyVault ([object] $creds) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{
	write-warning "Updating KV Values with new Password for bastion host $($VM.Name)..."
	Set-AzureKeyVaultSecret -VaultName "$($EnvironmentName)mgtkv1" -Name $creds.User -SecretValue (ConvertTo-SecureString  $creds.Password -AsPlainText -Force) -ContentType $creds.UserType
	
}

# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function  RemoveAttachedDisks([object] $oldDisk ) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{	
	write-warning "Removing existing provisioned VMDisks for bastion host $($VM.Name)..."
	
	Remove-AzureRmDisk -ResourceGroupName $MgmtRGName -DiskName $oldDisk.Name -confirm:$false -Force
	
}

# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function  EncryptNewDisk( [object] $VM) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{	
	write-warning "Encrypting bastion host $($VM.Name) disk..."
	
	$keyVault = Get-AzureRmKeyVault -VaultName "$($EnvironmentName)mgtkv1" -ResourceGroupName $MgmtRGName
	$diskEncryptionKeyVaultUrl = $keyVault.VaultUri
	$keyVaultResourceId = $keyVault.ResourceId
	$keyEncryptionKeyUrl = (Get-AzureKeyVaultKey -VaultName "$($EnvironmentName)mgtkv1" -Name "DiskEncryption").Key.kid
	
	Set-AzureRmVMDiskEncryptionExtension -ResourceGroupName $MgmtRGName -VMName $VM.Name -DiskEncryptionKeyVaultUrl $diskEncryptionKeyVaultUrl -DiskEncryptionKeyVaultId $keyVaultResourceId -KeyEncryptionKeyUrl $keyEncryptionKeyUrl -KeyEncryptionKeyVaultId $keyVaultResourceId -confirm:$false -force
}

# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function  RemoveHardeningExtension( [object] $VM) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{	
	write-warning "Removing hardening extension in bastion host $($VM.Name) disk..."
	
	if (Get-AzureRmVMExtension -ResourceGroupName $MgmtRGName -VMName $VM.Name -Name "HardeningExtension")
	{
		Remove-AzureRmVMExtension -ResourceGroupName $MgmtRGName -Name "HardeningExtension" -VMName $VM.Name -confirm:$false -force
	}
	
}


	
#endregion



#region Authentication 

  $connectionName = "AzureRunAsConnection"
  try
  {
      $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName         
      Add-AzureRmAccount `
          -ServicePrincipal `
          -TenantId $servicePrincipalConnection.TenantId `
          -ApplicationId $servicePrincipalConnection.ApplicationId `
          -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
  }
  catch {
      if (!$servicePrincipalConnection)
      {
          $ErrorMessage = "Connection $connectionName not found."
          throw $ErrorMessage
      } else{
          Write-Error -Message $_.Exception
          throw $_.Exception
      }
  }
#endregion Authentication



#region Entry Point

write-output "Checking provisioned bastion hosts for $($EnvironmentName)..."

$RunningVMs = Get-AzureRmVM -ResourceGroupName $MgmtRGName -status | where {($_.Tags).count -gt 0 -and $_.tags.Roles -eq $Role -and $_.PowerState -eq "VM Running"}

$VMsToDecomission = GetVMsToDecomissions $RunningVMs

if ($VMsToDecomission.count -gt 0){
    write-output "Bastian hosts currently Running at least 3h  $($VMsToDecomission.Name)...`n`n"
	write-warning "All Bastion Hosts will be decomissioned"
	foreach ($VM in $VMsToDecomission)
	{
		stop-AzureRmVM -Name $VM.Name -ResourceGroupName $MgmtRGName -Confirm:$false -force
		$oldDisk = RedeployVM $VM
		RemoveAttachedDisks $oldDisk
		
		write-warning "`nBastion host $($VM.Name) starting..."
		$VM | Start-AzureRmVM
		
		$newCreds = ResetVMPassword $VM
		AddSecretsToKeyVault $newCreds
		#RemoveHardeningExtension $VM
		#ApplyHardeningPolicy $VM
		#EncryptNewDisk $VM
		UpdateVMTags $VM
	
		write-warning "`nBastion host $($VM.Name) is ready!!!..."
		write-warning "`nBastion host $($VM.Name) will is being decomissioned!!!..."
		
		$VM | Stop-AzureRmVM -confirm:$false -force
	}
}
else
{
    write-output "All existing BastionHosts are decomissioned at this moment"
    break;
}


write-output "All VMs have been decomissioned"


#endregion Entry Point