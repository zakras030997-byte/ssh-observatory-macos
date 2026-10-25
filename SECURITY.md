# Security policy

## Scope

SSH Observatory observes hosts you own or are authorized to monitor. It uses the existing SSH account authority; it is not an SSH sandbox or a VPN repair service. Use a dedicated least-privilege monitoring account where practical. Never disable host-key checking to fix a connection error.

## Trust boundaries

Local SSH configurations and the application build are trusted. An authenticated remote endpoint controls its stdout/stderr and reported values. The client bounds record sizes, byte/record admission and pending UI work, but cannot prove that a compromised host reports truthful data. A lost monitoring channel does not prove a service outage.

Host metadata and resource history stay in the local application-support directory. Files use private permissions. The app does not read private-key contents itself; system OpenSSH handles authentication. Do not place credentials, node inventories or production telemetry in the source repository.

## Reporting

Do not include secrets, private hosts, personal paths or production logs in public issues. Use GitHub's private vulnerability reporting if enabled on the repository, or request a private reporting channel without disclosing exploit-sensitive details. Describe the affected version, trust boundary and a synthetic reproduction.

## Validation limits

The code includes tests for excessive input, stalled UI delivery, protocol validation, authentication errors, retries, pause/resume, retention and collector heartbeat expiry. A passing local suite does not establish real-network, physical sleep, Linux kernel, deployment or long-run performance guarantees.
