# powershell-dsc
How to run it

Open PowerShell (Admin) in the folder where you saved it and choose one of these:

Typical (WSL2 + Ubuntu, no Hyper-V, only restore point):

.\BuildMachine.ps1


Also enable Hyper-V (if you plan to use Windows containers):

.\BuildMachine.ps1 -EnableHyperV


Add a full image backup to external drive E:\ before installing:

.\BuildMachine.ps1 -ImageBackupTarget "E:\"


(This uses wbAdmin to capture C: and all critical volumes. It can take a while.)

Skip installing Ubuntu distro:

.\BuildMachine.ps1 -SkipUbuntu
