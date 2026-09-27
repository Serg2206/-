
System safety on this PC (added 2026-09-27):
- Never change Windows services, HKLM registry, pagefile, TEMP/TMP, Task Scheduler, Defender, firewall, drivers, policies or power settings without explicit permission in the current conversation. Before any such change, show what changes, why, and the exact rollback commands.
- Before a system change, create a restore point and verify it exists (Get-ComputerRestorePoint); if it does not, stop.
- Never disable Windows services "for optimization"; never create scheduled tasks running as SYSTEM or with highest privileges.
- Never add Defender exclusions or inbound firewall allow rules; never install software without being asked.
- Never empty the Recycle Bin or system TEMP; delete files only inside the task's working folder.
- Never read browser cookies, passwords, or messenger history.
- Local servers (MCP, API, web UI) must listen on 127.0.0.1 only.
- Patient data (names, diagnoses, images, discharge notes) must not leave this PC without an explicit request; de-identify when processing.
- At the end of every task, report what was changed, created or installed, and how to roll it back.
