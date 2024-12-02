# This script organises game-related folders in "Documents" by moving them to "My Games".
# It then creates symlinks in "Documents" so the original paths still work for games or apps. (hopefully)

$source = "C:\Users\User\OneDrive\Documents"  # The folder where your game folders currently live.
$target = "$source\My Games"                  # The organised folder where game folders will be moved.

# Add the names of the folders you want to organise here.
# For example, game folders that make your "Documents" look cluttered.
$folders = @("Diablo IV", "Call of Duty")

Write-Host "Starting folder management process..." -ForegroundColor Green

foreach ($folder in $folders) {
    Write-Host "-------------------------------------------------------"
    Write-Host "Processing folder: $folder" -ForegroundColor Yellow

    # Build full paths for where the folder currently is and where it will be moved.
    $sourcePath = Join-Path -Path $source -ChildPath $folder
    $targetPath = Join-Path -Path $target -ChildPath $folder

    # Check if the folder actually exists and isn't already a symlink.
    # We only want to move real folders—not symlinks that might already point elsewhere.
    if ((Test-Path -Path $sourcePath) -and !(Get-Item -Path $sourcePath).Attributes.ToString().Contains("ReparsePoint")) {
        Write-Host "Found folder $folder in $source. Moving to $target." -ForegroundColor Cyan

        # Move the folder to "My Games" to tidy up "Documents".
        Move-Item -Path $sourcePath -Destination $targetPath -Force
        Write-Host "Folder moved successfully. Creating symlink..." -ForegroundColor Cyan

        # Create a symlink in "Documents" so any apps looking for the original path can still find it.
        New-Item -ItemType SymbolicLink -Path $sourcePath -Target $targetPath
        Write-Host "Symlink for $folder created successfully." -ForegroundColor Green
    }

    # If a symlink already exists at the original location, handle it here.
    if ((Test-Path -Path $sourcePath) -and (Get-Item -Path $sourcePath).Attributes.ToString().Contains("ReparsePoint")) {
        # Ask if you want to hide the symlink. This keeps it out of sight in "Documents".
        $hideResponse = Read-Host "Do you want to hide the symlink for $folder? (yes/no)"
        if ($hideResponse -eq "yes") {
            Set-ItemProperty -Path $sourcePath -Name Attributes -Value ([System.IO.FileAttributes]::Hidden)
            Write-Host "Symlink $folder hidden successfully." -ForegroundColor Green
        } else {
            Write-Host "Skipped hiding the symlink for $folder." -ForegroundColor Yellow
        }

        # Ask if you want to mark the symlink as a system file. This hides it even more effectively.
        # It will only show up if 'Hide protected operating system files' is turned off in File Explorer.
        $systemResponse = Read-Host "Do you want to mark the symlink for $folder as a system file? (yes/no)"
        if ($systemResponse -eq "yes") {
            # Add the "System" attribute to the symlink, while keeping any existing attributes like "Hidden".
            Set-ItemProperty -Path $sourcePath -Name Attributes -Value `
                ((Get-ItemProperty -Path $sourcePath -Name Attributes).Attributes -bor [System.IO.FileAttributes]::System)
            Write-Host "Symlink $folder marked as system file successfully." -ForegroundColor Green
        } else {
            Write-Host "Skipped marking the symlink for $folder as a system file." -ForegroundColor Yellow
        }
    } else {
        # If there's no symlink where expected, just let the user know and move on.
        Write-Host "WARNING: $folder is not a valid symlink in $source. Skipping additional steps..." -ForegroundColor Red
    }
}

Write-Host "Folder management process completed. Verify the setup!" -ForegroundColor Green
