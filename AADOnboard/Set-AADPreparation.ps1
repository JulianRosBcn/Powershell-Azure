#region 0_HEADER

# Desc     :  Azure runbook to create all  Accounts initial identities and groups, including membership.

#endregion HEADER


[CmdletBinding()]
	param(
			[Parameter(Position=0,mandatory=$true)]
            [string]  $AzureADConfigFilePath,
			[Parameter(Position=0,mandatory=$true)]
            [bool]  $IsProdEnv,
			[Parameter(Position=0,mandatory=$true)]
            [string]  $CustomerName
			
        )

#region methods


# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function CreateUserAccounts ([object] $Users) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{	

	$userinfo = @()
	
	
	#----Internal Envs / Prod Envs  Users -----
	if ($IsProdEnv -eq $true)
	{
		$userCollection = $Users.ProdEnvs
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
		
			#Check if User exist before to avoid execution errors
			
			$exist = get-AzureADUser -SearchString $User.DisplayName
			
			if ($exist)
			{
				write-warning "`nUser $($User.DisplayName) already exist, creation not allowed`n"
			}
			else
			{
				write-output "`nAdding User Account $($User.DisplayName) for  Internal Envs`n"
				$PasswordProfile = New-Object -TypeName Microsoft.Open.AzureAD.Model.PasswordProfile
				$password = ([System.Web.Security.Membership]::GeneratePassword(16,1)) 
				$PasswordProfile.Password = $password
				$PasswordProfile.EnforceChangePasswordPolicy = 0
				$PasswordProfile.ForceChangePasswordNextLogin = 0
				
				New-AzureADUser 	-DisplayName $User.DisplayName -PasswordProfile $PasswordProfile -AccountEnabled $true -UserPrincipalName $User.UserPrincipalName `
									-UserType $User.UserType -JobTitle $User.JobTitle -MailNickName $user.MailNickName
				$userinfo += New-Object -TypeName psobject -Property @{User=$user.DisplayName; Password=$password; UserType=$User.KeyVaultUserType}
			}
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
		AddSecretsToKeyVault $userinfo
	}
	
}

# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function CreateSecurityGroups ([object] $Groups) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{
	
	#----Internal Envs / Prod Envs  groups -----
	if ($IsProdEnv -eq $true)
	{
		$groupCollection = $Groups.ProdEnvs
	}
	else
	{
		$groupCollection = $Groups.internalEnvs
	}
	
	#----Groups creation and update of membership ----
	try
	{
		foreach ($Group in $groupCollection)
		{	
			#Check if Security Group exist before as in AAD groups with same Name may exist generating duplicated information
			
			$exist = get-AzureADGroup -SearchString $Group.DisplayName
			
			if ($exist)
			{
				write-warning "`nGroup $($Group.DisplayName) already exist, creation not allowed`n"
			}
			else
			{
				#Create AzureADGroup
				write-output "`nAdding group $($Group.DisplayName) for  Security groups...`n"
				New-AzureADGroup 	-DisplayName $Group.DisplayName -MailEnabled $false -SecurityEnabled $true  `
									-MailNickName $Group.MailNickName -Description $Group.Description -verbose
				start-sleep 5 #group take some seconds to be available
				write-output "`nUpdating $($group.DisplayName) membership..."
				$groupmembers = $Group.DefaultMembers.split(",")
				foreach ($groupmember in $groupmembers)
				{
					$UserObj = Get-AzureADUser -SearchString $groupmember
					$GroupObj = Get-AzureADGroup -SearchString  $Group.DisplayName
					Add-AzureADGroupMember -ObjectId $GroupObj.ObjectID -RefObjectId $UserObj.ObjectID -verbose 
				}
			}
		}
	}
	Catch
	{
		$ErrorMessage = $_.Exception.Message
		write-error -exception $_.Exception -Message "Error exception message $($ErrorMessage)" 
		Break
	}
	
	#---------------------
}	

# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function AssignAzureRoleToUsers ([object] $Users) 
{

		#----Internal Envs / Prod Envs  Users -----
	if ($IsProdEnv -eq $true)
	{
		$userCollection = $Users.ProdEnvs
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
			write-warning "`Adding $($User.DisplayName) Azure Security Roles`n"
			$role = Get-AzureADDirectoryRole | Where-Object {$_.displayName -eq $User.AzureADRoles}
			$UserObj = Get-AzureADUser -SearchString $user.DisplayName
					
			if ($role -eq $null) 
			{
				$roleTemplate = Get-AzureADDirectoryRoleTemplate | Where-Object {$_.displayName -eq $User.AzureADRoles}
				Enable-AzureADDirectoryRole -RoleTemplateId $roleTemplate.ObjectId
				$role = Get-AzureADDirectoryRole | Where-Object {$_.displayName -eq $User.AzureADRoles}
				
			}
			
			$members = Get-AzureADDirectoryRoleMember -ObjectId $role.ObjectID
			
			foreach ($member in $members)
			{
				if ($member.DisplayName -eq $User.DisplayName)
				{
					$exist = $true
					break;
				}
				else
				{
					$exist = $false
				}
			}
			
			if ($exist -eq $false)
			{	
				write-warning "`Adding $($User.DisplayName) Azure Security Roles`n"
				Add-AzureADDirectoryRoleMember -ObjectId $role.ObjectId -RefObjectId $UserObj.ObjectId
			}
			else
			{
				write-warning "`User $($User.DisplayName) is already member of Role $($role.DisplayName)`n"
			}
		}
		
	}
	Catch
	{
		$ErrorMessage = $_.Exception.Message
		write-error -exception $_.Exception -Message "Error exception message $($ErrorMessage)" 
		Break
	}
	
	#---------------------
}

# ----------------------------------------------------------------------------------------------------------------------------------------------------------
Function AddSecretsToKeyVault ([object] $UserInfo) 
# ----------------------------------------------------------------------------------------------------------------------------------------------------------
{

	

	if ($IsProdEnv -eq $true)
	{
		foreach ($user in $userinfo)
		{
			$env = $user.user.Substring(0,3)
			Set-AzureKeyVaultSecret -VaultName "$($CustomerName)$($env)kv1" -Name $user.user -SecretValue (ConvertTo-SecureString  $user.Password -AsPlainText -Force) -ContentType $user.UserType
		}
	}
	else
	{
		foreach ($user in $userinfo)
		{
			Set-AzureKeyVaultSecret -VaultName "$($CustomerName)dlvkv1" -Name $user.user -SecretValue (ConvertTo-SecureString  $user.Password -AsPlainText -Force) -ContentType $user.UserType
		}
	}

}
#endregion methods




#region Entry Point
	

$AADInfo = Get-Content -Raw $AzureADConfigFilePath | Out-String | ConvertFrom-Json

CreateUserAccounts $AADInfo.AzureADObjects.Users

AssignAzureRoleToUsers $AADInfo.AzureADObjects.Users

CreateSecurityGroups $AADInfo.AzureADObjects.SecurityGroups




#endregion Entry Point