# NTNX-vm-write-stats-collector

A read-only Bash collector for Prism Central VM write-I/O statistics. It resolves VMs from Prism Central categories, queries historical VM statistics through the Nutanix v4 REST APIs, and produces capacity, sampled-volume, and optional cost-scenario reports.

[Deutsche Dokumentation](README.de.md)

This is an independent utility. It is not an official Nutanix product, support tool, or statement of product supportability.

## Features

* Resolve VMs from one or more Prism Central categories.
* Query VM write-bandwidth statistics through the Categories, VMM, and Stats APIs.
* Run interactively or in parameter mode without configuration prompts.
* Keep password entry hidden; passwords are never accepted as command-line arguments.
* Calculate aggregate average, P95, and peak write-rate indicators.
* Calculate observed sampled volume and optional cost scenarios.
* Report multiple volume windows such as `1h`, `24h`, `7d`, or `4w` in one run.
* Preserve detailed per-VM samples, mappings, diagnostics, and raw API responses.
* Export CSV output using locale-independent `us` or German `de` formatting.

## Important interpretation

The script uses the `controllerWriteIoBandwidthKbps` VM metric as a workload-write sizing proxy. It does not evaluate provisioned or used storage capacity in GB/TB. The results describe write bandwidth in kB/s plus derived sampled volume and scenarios. The metric is not a direct Azure network, SyncRep, billing, or replication-byte counter. Data reduction, replication overhead, metadata, retransmissions, and protocol overhead are not derived by this utility.

The option `--capacity-aggregation PEAK` is a technical name retained by the script. It selects `MAX` aggregation for the write-bandwidth rate; it does not measure storage capacity.

Missing VM statistics are reported as missing; they are not silently converted to zero. A volume window is marked `partial` when the requested period is longer than the data returned by Prism Central. The script does not extrapolate missing time.

## Requirements

* Bash 4 or newer.
* `curl`.
* `jq`.
* Standard command-line tools: `awk`, `sed`, `sort`, `date`, and `mktemp`.
* A Prism Central account with permission to read the selected VM configuration and historical statistics.

On macOS, the system Bash may be older than Bash 4. With Homebrew, install the required tools for example with:

```bash
brew install bash jq
```

## Quick start

Clone the repository and make the scripts executable:

```bash
git clone https://github.com/mheistruevers/NTNX-vm-write-stats-collector.git
cd NTNX-vm-write-stats-collector
chmod +x nutanix_category_vm_write_stats_v1.4.1.sh
```

Show the available options:

```bash
./nutanix_category_vm_write_stats_v1.4.1.sh --help
```

Run interactively:

```bash
./nutanix_category_vm_write_stats_v1.4.1.sh
```

## Non-interactive parameter mode

Parameter mode still asks for the Prism Central password through a hidden prompt. The password must not be placed in the command line, a script, or a repository file.

```bash
./nutanix_category_vm_write_stats_v1.4.1.sh \
  --host pc.example.com \
  --port 9440 \
  --categories-api-version v4.4 \
  --vmm-api-version v4.3 \
  --user 'admin@example.com' \
  --category 'DR=Critical' \
  --match-mode OR \
  --lookback 7d \
  --sampling-interval 60 \
  --capacity-aggregation PEAK \
  --calculate-cost yes \
  --price-per-gb 0.009 \
  --volume-windows '1h,24h,7d' \
  --csv-format us \
  --verify-tls yes \
  --confirm-read-only
```

The `--confirm-read-only` flag is required in parameter mode because the script performs potentially numerous read-only API calls.

For a validation-only run:

```bash
./nutanix_category_vm_write_stats_v1.4.1.sh \
  --dry-run \
  --host pc.example.com \
  --user 'admin@example.com' \
  --category 'DR=Critical' \
  --lookback 24h \
  --confirm-read-only
```

Dry-run mode validates the configuration, authenticates, and performs the script's preflight checks; it does not perform the complete statistics collection.

A sanitized environment-variable launcher is included for repeatable local runs:

```bash
export PRISM_CENTRAL_HOST='pc.example.com'
export PRISM_CENTRAL_USER='admin@example.com'
export VM_CATEGORY='DR=Critical'
./examples/non-interactive-example.sh
```

The launcher does not store or pass a password. The collector still requests it through a hidden prompt.

## Time ranges and volume windows

`--lookback` controls how much historical data is requested, for example `24h`, `7d`, or `4w`.

`--volume-windows` controls which report windows are calculated from the returned samples. Multiple windows are comma-separated:

```bash
--lookback 7d --volume-windows '1h,24h,7d'
```

If `--volume-windows '4w'` is used together with `--lookback 7d`, the 4-week report can only use the available 7-day data and is marked `partial`. To calculate a complete four-week window, request at least `--lookback 28d`.

Alternatively, use an explicit RFC 3339 range:

```bash
--start '2026-11-23T00:00:00Z' \
--end '2026-11-24T00:00:00Z'
```

Do not combine `--lookback` with `--start`/`--end`.

## Output layout

Each run creates a timestamped output directory unless `--output-dir` is supplied:

```text
nutanix-category-stats-YYYYMMDDTHHMMSSZ/
├── run_summary.txt
├── calculation_methodology.txt
├── aggregate_capacity_summary.csv
├── aggregate_volume_summary.csv
├── volume_windows.csv
├── details/
│   ├── write_samples_capacity.csv
│   ├── write_samples_volume.csv
│   ├── selected_vms.tsv
│   └── category_matches.tsv
└── diagnostics/
    ├── run.log
    ├── stats_diagnostics.txt
    └── raw_api_responses/
```

See [docs/output-format.md](docs/output-format.md) for field descriptions and interpretation guidance.

## TLS and credentials

Keep TLS verification enabled whenever Prism Central presents a trusted certificate. Use `--verify-tls no` only when required for a controlled lab or self-signed certificate and understand the security implications.

Never commit:

* Prism Central passwords.
* API tokens.
* Private keys or certificates.
* Real customer output files.
* Local `.env` files or shell history containing secrets.

The repository `.gitignore` excludes common generated data, logs, and local secret files. Review `git status` and `git diff --cached` before every commit.

## Validation

Run the local syntax and executable checks:

```bash
./tests/validate.sh
```

The GitHub Actions workflow runs the same checks for pushes and pull requests.

## Repository status and licensing

The repository packages the current project state as version `1.4.1`. The supplied script is intentionally kept as provided; its internal banner may use the source script version.

The repository is licensed under the MIT License. See [LICENSE](LICENSE) for the full license text. The software is provided without warranty. See [SECURITY.md](SECURITY.md) for security reporting guidance and [CONTRIBUTING.md](CONTRIBUTING.md) for contribution expectations.