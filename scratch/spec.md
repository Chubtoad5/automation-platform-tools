# RKE2 upgrade Feature

Referencing the rke2_installer.sh, which has been downloaded from companian repository, update the ap-tools script to support the "upgrade" functionality for RKE2. Ask me if there are any questions or clarity needed. Analyze the scratch/rke2_installer.sh to under stand that capabilities and analyze ap-tools script to determine the best way to implement this update.

# Goal
ap-tools will support the rke2 upgrade functionality from calling the rke2_intaller.sh script, leveraging similar workflow as `./ap-tools install rke2`

# New syntax usage

- `./ap-tools upgrade rke2 [arg1] [ar2] [-registry <url>:<port> <username> <password>]`
- `[arg1]` required, one of `server|agent|both`
- `[arg2]` required, one of `stable` or `<rke2 release version>`
- `[-registry <url>:<port> <username> <password>]` optional, pulls/pushes containers to the target registry.

# Requirements
- All rke2 upgrade functionality is fully implemented in the rke2_installer.sh helper script, therefore the ap-tools script should simply call the script. For example `./ap-tools upgrade rke2 server stable` would call `ap-install/rke2/rke2_installer.sh upgrade server stable`
- upgrade usage and README.md with new feature support
- `upgrade` should only work for rke2, no other commands support upgrade at this time.
