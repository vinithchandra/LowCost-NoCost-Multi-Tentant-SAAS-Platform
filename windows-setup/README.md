# Windows-side setup notes

## .wslconfig (RAM/CPU caps for WSL2)
On Windows 8 GB systems, configure WSL2 BEFORE first cluster creation:

```powershell
# In PowerShell:
Copy-Item "windows-setup\.wslconfig" "$env:USERPROFILE\.wslconfig"
wsl --shutdown
```

Then re-open Ubuntu. Verify inside Ubuntu:
```bash
free -h         # MemTotal should now show ~5 GB
nproc           # should print 6
```

## Docker Desktop settings
- Settings -> Resources -> WSL Integration -> Ubuntu = ON
- Settings -> General -> "Use the WSL 2 based engine" = checked
- Do NOT also set Docker Desktop's own memory cap; with WSL2 backend Docker uses the WSL2 VM's resources.
