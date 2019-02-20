#region 0_HEADER

#endregion HEADER

#region Properties

$EnvironmentName 	= ""								#customer name based in 3chars nameconvention
$MgmtRGName 		= "$($EnvironmentName)-mgt-rg"		#Default Management. RG where Automation account is located
$Role 				= "bho"								#Role Tag for VM (always bho so don't modify)

#endregion


#region modules and dependencies

	Add-Type -AssemblyName System.web

#endregion


#region methods

# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function UpdateVMTags ([object] $VM ) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{	
	write-warning "Updating Tag information for bastion host $($VM.Name)..."
    
	$timestamp = get-date -f "MM-dd-yy HH:mm:ss"
	$tags = @{"Roles" = $Role ; "LastProvision" = $timestamp}
	
	Set-AzureRmResource -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -ResourceType "Microsoft.Compute/VirtualMachines" -Tag $tags -confirm:$false -force
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

write-output "Checking available bastion hosts for $($EnvironmentName)..."

$IdleVMs = Get-AzureRmVM -ResourceGroupName $MgmtRGName -status | where {($_.Tags).count -gt 0 -and $_.tags.Roles -eq $Role -and $_.PowerState -eq "VM deallocated"}

if ($IdleVMs.count -gt 0){
    write-warning "Bastian hosts currently available  $($IdleVMs.Name)...`n`n"
	write-warning "You will be assigned $($IdleVMs[0].Name)"
}
else
{
    write-warning "All existing BastionHosts are busy at this moment, please wait some minutes and try again"
    break;
}


#Reset Password for VM and recreate VM

start-azurermvm -Name $IdleVMs[0].Name -ResourceGroupName $MgmtRGName -verbose 

UpdateVMTags $IdleVMs[0] 


write-output "The bastion Host $($IdleVMs[0].Name) provision is complete"
write-output "Server has been redeployed and hardened from scratch"
write-output "The information about new credentials has been updated in the KV $($EnvironmentName)mgtkv1"
write-output "VM will be decomissioned in 3h. DO NOT store anything as it will be reprovisioned after decomission"


#endregion Entry Point