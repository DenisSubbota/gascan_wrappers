# Gascan Onboarding Wrapper

`monitor_onboarding_wrapper.sh` automates the initial Gascan monitor onboarding flow.
It installs the correct Gascan binary for the host OS, configures SN inventory access,
prepares local environment settings, and runs the required Gascan playbooks for PMM
server/client setup.

## What It Does

- Installs `gascan` into `~/bin/gascan`.
- Extracts the Gascan bundle into `~/gascan_bundle`.
- Creates or updates `~/.config/gascan/inventory-config.json`.
- Validates SN inventory access before running onboarding automation.
- Adds default PMM database credentials to `~/.config/gascan/secrets.yaml` when needed.
- Detects external PMM server settings and stores validated PMM admin credentials.
- Handles missing passwordless sudo by storing the sudo password for Ansible use.
- Adds useful Gascan aliases and environment variables to `~/.bashrc`.
- Works around `/tmp` mounted with `noexec` by using `~/tmp`.
- Optionally sets SELinux to permissive when SELinux may block automation.
- Enables user linger with `loginctl enable-linger`.
- Runs the monitor onboarding playbooks in order and supports resume after failure.

## Supported Operating Systems

The wrapper downloads the Gascan binary for these Linux distributions:

- CentOS Stream / RHEL / Oracle Linux / Rocky Linux 9
- Ubuntu 22.04
- Ubuntu 24.04
- Debian 11
- Debian 12
- Debian 13

Unsupported distributions exit before installation.

## Requirements

- Linux host with `/etc/os-release`.
- `bash`, `curl`, `sudo`, and standard system utilities.
- Network access to:
  - `https://cdba.percona.com`
  - `https://cdba2.percona.com`
  - GitHub releases, if `yq` must be installed automatically.
- SN monitor node already created.
- SN `client_identifier` and `api_key`.
- Recommended minimum of 100 GB free disk space for PMM data.

Optional but used when available:

- `jq` for inventory parsing and external PMM detection.
- `yq` for safe updates to `~/.config/gascan/secrets.yaml`.
- `loginctl` for enabling user linger.
- SELinux tools such as `getenforce`, `sestatus`, and `setenforce`.

## Quick Start

Run the latest public wrapper directly:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/DenisSubbota/gascan_wrappers/main/monitor_onboarding_wrapper.sh)"
```

If you already cloned this repository, run it locally:

```bash
chmod +x monitor_onboarding_wrapper.sh
./monitor_onboarding_wrapper.sh
```

The script prompts for:

- Gascan version, defaulting to `v1.24.0`.
- Monitor node name as created in SN.
- SN `client_identifier`.
- SN `api_key`.
- PMM admin credentials, only when an external PMM server is detected.
- Sudo password, only when passwordless sudo is not available.
- Confirmation before running Gascan automation.

## Non-Interactive Usage

Prompt values can be provided with environment variables:

```bash
GASCAN_VERSION="v1.24.0" \
MONITOR_NODE="my-monitor-node" \
CLIENT_IDENTIFIER="64-character-client-identifier" \
API_KEY="64-character-api-key" \
GASCAN_CONFIRM_AUTOMATION=1 \
./monitor_onboarding_wrapper.sh
```

`CLIENT_IDENTIFIER` and `API_KEY` must each be exactly 64 characters and must be
different values.

Non-interactive runs require `GASCAN_CONFIRM_AUTOMATION=1`. If a playbook step fails
without an interactive TTY, the script exits and prints the resume command.

## Resume After Failure

The wrapper saves progress in:

```text
~/.config/gascan/.onboarding_step
```

After fixing the failed condition, continue from the saved step:

```bash
./monitor_onboarding_wrapper.sh --resume
```

For the remote one-command runner, pass `--resume` after a placeholder `$0` value:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/DenisSubbota/gascan_wrappers/main/monitor_onboarding_wrapper.sh)" gascan-wrapper --resume
```

Resume mode skips fresh setup and continues the onboarding playbook phase. It still
performs idempotent runtime checks such as SELinux handling and user linger setup.

## Onboarding Playbooks

The script runs these Gascan commands in order:

```bash
gascan --limit=monitors --playbook=pmm-server.yaml
gascan --limit=monitors --playbook=pmm-client.yaml
gascan --limit=monitors --playbook=tools.yaml
gascan --playbook configs.yaml --tags=connect,netrc --limit=monitors
```

In an interactive terminal, a failed step offers:

- `r` to retry the same step.
- `s` to skip the step and continue.
- `q` to quit and resume later.

Skipped steps are summarized at the end with the exact `gascan` commands needed to
complete recovery later.

## Files Created Or Updated

- `~/bin/gascan`
- `~/gascan_bundle`
- `~/.config/gascan/inventory-config.json`
- `~/.config/gascan/secrets.yaml`
- `~/.config/gascan/.onboarding_step`
- `~/.bashrc`
- `~/tmp`, only when `/tmp` is mounted with `noexec`

The script also creates timestamped backups of `secrets.yaml` before editing it.

## Environment Added To `.bashrc`

The wrapper adds Gascan-related shell customizations, including:

- `ANSIBLE_VAULT_PASSWORD_FILE`
- `GASCAN_DEFAULT_INVENTORY`
- `GASCAN_INVENTORY_CONFIG_FILE`
- `GASCAN_FLAG_PASSWORDLESS_SUDO`, when applicable
- `PATH` extension for `~/bin`
- Useful aliases such as `avv`, `db_tree`, `db_connect`, and `ssh_connect`
- A monitor-specific prompt using `SSH_MS_NAME`

After onboarding, the script can open a new login shell automatically. Otherwise, run:

```bash
source ~/.bashrc
```

## Security Notes

- SN credentials are written to `~/.config/gascan/inventory-config.json`.
- Sudo and PMM credentials may be written to `~/.config/gascan/secrets.yaml`.
- The script warns that `secrets.yaml` can be unencrypted until the first automation run.
- `secrets.yaml` permissions are set to `600` after updates.
- If `secrets.yaml` is already Ansible Vault encrypted, the script skips direct edits.

## Help

```bash
./monitor_onboarding_wrapper.sh --help
```

Available options:

- `--resume`: continue from `~/.config/gascan/.onboarding_step`.
- `--help` or `-h`: show usage details.
