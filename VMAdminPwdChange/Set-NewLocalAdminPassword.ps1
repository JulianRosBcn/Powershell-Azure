#region 0_HEADER

#region Properties

$EnvironmentName 	= ""								#customer name based in 3chars nameconvention
$MgmtRGName 		= "$($EnvironmentName)-mgt-rg"	#Default Management. RG where Automation account is located

#endregion


#region modules and dependencies

	Add-Type -AssemblyName System.web

#endregion


#region methods
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function ResetVMPassword ([object] $VM) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{	

    write-output "Updating VM $($VMName) password process started..."
	$password = [System.Web.Security.Membership]::GeneratePassword(16,1)
	$secpassword = ConvertTo-SecureString $password -AsPlainText -Force
	$Credential  = New-Object System.Management.Automation.PSCredential ("lokalniAdministrator", $secpassword)
			
	Set-AzureRmVMAccessExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Name "ResetPassword" -Location $VM.location -Credential $Credential -TypeHandlerVersion "2.0"
	
	write-output "VM $($VM.Name) localadmin credentials have been updated"
	
	
	return $password
}

# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function AddSecretsToKeyVault ([string] $password , [object] $VM) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{
	write-warning "Updating KV Values with new Password for VM $($VM.Name)..."
	$securepassword = ConvertTo-SecureString -String $password -AsPlainText -Force
	Set-AzureKeyVaultSecret -VaultName "$($EnvironmentName)mgtkv1" -Name $VM.Name -SecretValue  $securepassword -ContentType "lokalniAdministrator"
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

$VMs = Get-AzureRmVM -status | where {($_.Tags).count -gt 0 -and ($_.tags.Environment -eq "prd" -or $_.tags.Environment -eq "uat") -and $_.PowerState -eq "VM Running" }

write-output "Finding VMs to change local Admin Password..."

if ($VMs.count -gt 0){
    write-Output "VMs currently Running to reset local admin password...`n`n"
	Write-Output $VMs.Name
	foreach ($VM in $VMs)
	{
		write-warning "Changing local admin password for $($VM.Name)...`n"
		$password = ResetVMPassword $VM
		AddSecretsToKeyVault $password $VM
	}
}
else
{
    write-warning "All existing VMs are not available for password change at this moment"
    break;
}

#endregion