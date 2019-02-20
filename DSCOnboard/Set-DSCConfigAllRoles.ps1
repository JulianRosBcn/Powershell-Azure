#region 0_HEADER

#endregion HEADER


#region Properties
param (
	$EnvironmentName = "",						#customer name based in 3chars nameconvention
	$MgmtRGName = " ",								#Default Management. RG where Automation account is located
	$DSCMode = "ApplyAndAutoCorrect",				#ApplyAndAutoCorrect | ApplyOnly | ApplyAndMonitor
	$DSCFrequency = 15,								#Default 15
	$targetVMs = @(), 								#Do not assign value
	$Role = "All",									#Select role to assign DSC
	$DSCAccountName = "DSCAccount"					#Default in all customer is DSCAccount, for PROD|Other and other internal
)

#endregion


#region methods
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function AssignDSCConfig ([string] $VMName , [string] $VMRGName , [string]$AutomationAccountName , [string] $DSCConfiguration) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{	

    write-output "Applying DSC Template $($DSCConfiguration) to $($VMName)"

	Register-AzureRmAutomationDscNode  	-ResourceGroupName $MgmtRGName -AutomationAccountName $AutomationAccountName -AzureVMName $VMName -ConfigurationModeFrequencyMins $DSCFrequency -verbose -RebootNodeIfNeeded $true -ConfigurationMode $DSCMode -AzureVMResourceGroup $VMRGName -NodeConfigurationName $DSCConfiguration
	
	write-output "DSC Template $($DSCConfiguration) applied to $($VMName)"
}

#endregion methods



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

write-output "Reviewing VMs to apply DSC Config..."

$VMs = Get-AzureRmVM | where {($_.Tags).count -gt 0 -and $_.tags.ServerFeatures -eq $Role -and $_.Name -like "$($EnvironmentName.toUpper())*"}

foreach($vm in $vms)
{
    if (-not (Get-AzureRmVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $vm.Name -Name Microsoft.Powershell.DSC -ErrorAction silentlycontinue))
    {
        $targetVMs += $vm
    }
}

if ($targetVMs.count -gt 0){
    write-output "Current VMs deployed without DSC Assignation..."
    write-output $targetVMs | select ResourceGroupName, Name, Tags | fl
}
else
{
    write-output "All existing VMs have been correctly assigned to DSC"
    break;
}


foreach ($VM in $targetVMs)
{
	#Parsing hostname from VMName
	$Hostname = $VM.name.replace("-","").tolower()	
	AssignDSCConfig $VM.Name $VM.ResourceGroupName $DSCAccountName "DSC$($EnvironmentName)Dev.$($Hostname)"                          
}
	
#endregion Entry Point


