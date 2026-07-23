param (
    [string]$Version,
    [string]$BuildNumber,
    [string]$Action
)

# Unpacks or removes a BlizzardInterfaceCode archive created by
# PackageBlizzardInterfaceCode.ps1. The code/ directory is gitignored, so this
# is purely a local reference checkout.

$rootDir = "$(Get-Location)"
$targetDir = "$rootDir\code"

$zipFileName = "BlizzardInterfaceCode-$Version.$BuildNumber.zip"
$zipFilePath = "$targetDir\$zipFileName"
$unpackedFolderPath = "$targetDir\BlizzardInterfaceCode-$Version.$BuildNumber"

if ($Action -eq "unpack") {
    if (Test-Path $zipFilePath) {
        Expand-Archive -Path $zipFilePath -DestinationPath $unpackedFolderPath
        Write-Output "Folder unpacked to $unpackedFolderPath"
    } else {
        Write-Output "Zip file $zipFilePath does not exist."
    }
} elseif ($Action -eq "delete") {
    if (Test-Path $unpackedFolderPath) {
        Remove-Item -Recurse -Force -Path $unpackedFolderPath
        Write-Output "Folder $unpackedFolderPath deleted."
    } else {
        Write-Output "Folder $unpackedFolderPath does not exist."
    }
} else {
    Write-Output "Invalid action. Use 'unpack' or 'delete'."
}
