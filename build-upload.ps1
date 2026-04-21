$RobotIP = "192.168.124.1"

zig build

$LocalFile = "zig-out/bin/botball_user_program"
$RemoteFile = "/home/kipr/Documents/KISS/Default User/Project XBOT/bin/botball_user_program"

$LocalHash = (Get-FileHash $LocalFile -Algorithm SHA256).Hash.ToLower()
$RemoteHash = ssh kipr@$RobotIP "sha256sum '$RemoteFile' 2>/dev/null | cut -d' ' -f1"

if ($LocalHash -eq $RemoteHash) {
    Write-Host "Binary unchanged, skipping upload."
}
else {
    Write-Host "Binary changed, uploading..."
    scp $LocalFile "kipr@${RobotIP}:/home/kipr/"
    ssh kipr@$RobotIP "sudo mv '/home/kipr/botball_user_program' '$RemoteFile'"
    ssh kipr@$RobotIP "sudo chmod +x '$RemoteFile'"
    Write-Host "Upload complete."
}