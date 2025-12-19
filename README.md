# Zerto Volume Locator (VM Guest Drive → vSphere Disk/LUN Map)

This PowerShell/PowerCLI script maps Windows VM drive letters to their corresponding vSphere virtual disks and storage details, helping identify TempDB and page file volumes for VPG creation.

## Features
- Maps guest drives to VMware disks and LUNs.
- Outputs CSV and failure log.

## Prerequisites
- PowerShell 5.1 or 7.x
- VMware.PowerCLI module
- Network access to vCenter (443) and ESXi hosts (902)
- VMware Tools running on Windows VMs

## How to Run
1. Launch PowerShell as Administrator.
2. Import PowerCLI: `Import-Module VMware.PowerCLI`
3. Run script: `C:\Path\To\Zerto Volume Locator.ps1`
4. Follow prompts for vCenter and guest credentials.

## Output
- CSV: `C:\VM_Drive_to_vSphere_LUN_Map.csv`
- Failures: `C:\VM_Drive_to_vSphere_LUN_Failures.log`

## Security Notes
- vCenter credentials can be saved locally.
- Guest credentials are prompted at runtime.

## Troubleshooting
See failure log for details.

## Legal Disclaimer

This script is provided as an **example only** and is **not supported** under any Zerto support program or service.

> The author and Zerto disclaim all implied warranties, including merchantability and fitness for a particular purpose.  
> In no event shall Zerto or the author be liable for damages arising from the use or inability to use this script.  
> Use at your own risk.

---

**Author:** AJ Lastoff

**Company:** Zerto (HPE)  
**Version:** 1.0  
**Date:** December 2025
