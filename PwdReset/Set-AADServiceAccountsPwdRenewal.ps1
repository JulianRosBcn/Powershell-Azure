#region 0_HEADER

#endregion HEADER


[CmdletBinding()]
	param(
			[Parameter(Position=0,mandatory=$true)]
            [string]  $AzureADConfigFilePath,
			[Parameter(Position=0,mandatory=$true)]
            [bool]  $IsProdSubscription,
			[ValidateSet("tst","uat","prd")] 		
			[Parameter(Position=0,mandatory=$false)]
            [string]  $EnvironmentName,
			[Parameter(Position=0,mandatory=$true)]
            [string]  $EnvTagName
			
        )
		
		
#region methods

# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function UpdateUserAccountsPwd ([object] $Users) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{	

	$userinfo = @()
	
	
	
	if ($IsProdSubscription -eq $true)
	{
		$userCollection = $Users.CustomerEnvs
	}
	else
	{
		$userCollection = $Users.internalEnvs
	}

	#----User creation with random password and store in KV -----
	try
	{
		foreach ($User in $userCollection)
		{
		
			#Check if User exists before to avoid execution errors. Changes will apply, in case of customer subscription to this env only
			 
			if ($EnvironmentName -eq $user.DisplayName.Substring(0,3)) 
			{ 
				write-output "`nProcessing user $($User.DisplayName) in $($EnvironmentName)`n"
				$exists = get-AzureADUser -SearchString $User.DisplayName
			
				if ($exists)
				{
					write-output "`nModifying password for user $($User.DisplayName)`n"
					$PasswordProfile = New-Object -TypeName Microsoft.Open.AzureAD.Model.PasswordProfile
					$password = ([System.Web.Security.Membership]::GeneratePassword(16,1)) 
					$securePassword = ConvertTo-SecureString $password -AsPlainText  -Force
					
					Set-AzureADUserPassword -ObjectId  $exists.ObjectId -Password $securePassword -ForceChangePasswordNextLogin $false
					
					$userinfo += New-Object -TypeName psobject -Property @{User=$user.DisplayName; Password=$password; UserType=$User.KeyVaultUserType}
				}
				else
				{
					write-warning "`nUser $($User.DisplayName) does not exist, password change cannot be executed`n"
				}
			}
			else
			{
				write-warning "`User $($User.DisplayName) in $($EnvironmentName) password won't be changed!`n"
			}
			start-sleep 1
		}
	}
	Catch
	{
		$ErrorMessage = $_.Exception.Message
		write-error -exception $_.Exception -Message "Error exception message $($ErrorMessage)" 
		Break
	}
	
	#---------------------
	
	#Export User&Password information to Keyvault
	
	if ($userinfo.count -gt 0)
	{
		ReplaceKVSecretsValue $userinfo
	}
	
}


# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function ReplaceKVSecretsValue ([object] $Users) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{	
	
	if ($IsProdSubscription -eq $true)
	{
		$KVName = "$($EnvTagName)$($EnvironmentName)kv1"
	}
	else
	{
		$KVName = "$($EnvTagName)dlvkv1"
	}
		
	foreach ($user in $users)
	{
		try 
		{	
			#First disable all values for specific secret, assuming secret name -eq $user.DisplayName
			write-output "Disabling previous secret values for $($User.DisplayName) Secret in Keyvault $($KVName)"
			$OldSecrets = Get-AzureKeyVaultSecret -VaultName $KVName -Name $User.User -IncludeVersions
			foreach($secret in $OldSecrets){
				$secret | Set-AzureKeyVaultSecretAttribute -Enable $false
			}
		
			
			#Now insert the new Secrets
			write-output "Adding new secret value for $($User.DisplayName) Secret in Keyvault $($KVName)"
			$Secret = ConvertTo-SecureString -String $User.password -AsPlainText -Force
			$ExpirationDate = (Get-Date).AddYears(2).ToUniversalTime()
			$ValidFromDate =(Get-Date).ToUniversalTime()
			
			Set-AzureKeyVaultSecret -VaultName $KVName -Name $User.User -SecretValue $Secret -Expires $ExpirationDate -NotBefore $ValidFromDate -contentType $user.UserType -verbose
		}
		Catch
		{
			$ErrorMessage = $_.Exception.Message
			write-error -exception $_.Exception -Message "Error exception message $($ErrorMessage)" 
			Break;
		}
	}
}

#endregion methods


#region EntryPoint

if ($IsProdSubscription -eq $false){$EnvironmentName = $false}

$AADInfo = Get-Content -Raw $AzureADConfigFilePath | Out-String | ConvertFrom-Json

UpdateUserAccountsPwd $AADInfo.AzureADObjects.Users

#endregion EntryPoint