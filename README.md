# DNS Auto Installer

An automated Bash script to configure a DNS Server using BIND9 on Ubuntu Server 20.04+.
This script simplifies the setup process by automating network configuration, BIND9 installation, and zone file creation.

## Features
- **Network Configuration**: Sets up Static IP via Netplan and disables cloud-init network config.
- **BIND9 Setup**: Installs and configures BIND9, including named options and local zones.
- **Zone Management**: Automatically creates Forward and Reverse zone files based on your input.
- **Resolver Config**: Installs and configures `resolvconf`.
- **Validation**: Runs `named-checkconf` and `named-checkzone` to ensure validity.

## Prerequisites
- A fresh installation of Ubuntu Server 20.04 or newer.
- Active internet connection (required for package installation).
- Root privileges (sudo).

## Installation Guide

You can perform these steps from a TTY (terminal) or SSH session.

### 1. Install Git
On a fresh Ubuntu installation, `git` might not be installed. Install it first:

```bash
sudo apt update
sudo apt install git -y
```

### 2. Clone Repository
Clone the repository to your server:

```bash
git clone https://github.com/mumtazka/dns.git
cd dns
```
*(Note: Replace the URL above with your actual repository URL if different)*

### 3. Make Executable
Grant execution permissions to the script:

```bash
chmod +x dnsinstaller.sh
```

### 4. Run the Installer
Run the script with `sudo` privileges:

```bash
sudo ./dnsinstaller.sh
```

## Usage
The script is interactive and will prompt you for the following information:

| Prompt | Example | Description |
|--------|---------|-------------|
| **Static IP Address** | `10.10.5.1` | The static IP you want to assign to this DNS server. |
| **Network Interface** | `ens33` | The network interface name (run `ip a` to check). |
| **Gateway IP** | `10.10.5.254` | Your network router/gateway address. |
| **Domain Name** | `kelompok5.sch.id` | The main domain name for the zone. |
| **Zone Label** | `kelompok5` | A short label for the zone database file. |
| **Secondary/WWW IP** | `10.10.5.11` | The IP address that `www.yourdomain.com` will point to. |

## Troubleshooting
- **No Internet after IP Change**: If you lose connectivity after the network step, check if the Gateway IP and Interface name were correct.
- **Permission Denied**: Ensure you run the script with `sudo`.
- **Invalid Interface**: The script checks if the interface exists. Use `ip a` to list valid interfaces if unsure.
