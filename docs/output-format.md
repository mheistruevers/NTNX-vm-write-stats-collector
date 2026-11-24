# Output format

The collector creates one timestamped output directory per run. Generated output should normally remain local and should not be committed to the repository.

## Main result files

* `run_summary.txt`: run parameters, selected VM counts, coverage, aggregate rates, observed volume, scenario volume, and cost calculations.
* `calculation_methodology.txt`: formulas, aggregation choices, coverage behavior, and metric limitations used for the run.
* `aggregate_capacity_summary.csv`: timestamp-level aggregate write-bandwidth path using the configured rate aggregation, normally API `MAX` when `PEAK` is selected. The filename is a legacy technical name and does not represent storage capacity.
* `aggregate_volume_summary.csv`: timestamp-level aggregate volume path using API `AVG` samples. The `interval_GB` field represents one configured sampling interval.
* `volume_windows.csv`: one row per requested `--volume-windows` value.

## Detail files

* `details/write_samples_capacity.csv`: parsed per-VM write-bandwidth samples for the `MAX`/`PEAK` aggregation path. The filename is a legacy technical name.
* `details/write_samples_volume.csv`: parsed per-VM volume samples.
* `details/selected_vms.tsv`: selected and resolved VM inventory.
* `details/category_matches.tsv`: category-to-VM association results.

## Diagnostic files

* `diagnostics/run.log`: API requests, parser decisions, warnings, and progress details.
* `diagnostics/stats_diagnostics.txt`: response-shape and metric extraction diagnostics.
* `diagnostics/raw_api_responses/`: raw API responses retained for troubleshooting.

Raw API responses can contain infrastructure metadata. Treat the complete output directory as sensitive operational data.

## Volume-window fields

`volume_windows.csv` contains:

* `requested_window`: configured value such as `1h`, `24h`, `7d`, or `4w`.
* `requested_seconds`: requested duration in seconds.
* `first_sample` and `last_sample`: first and last sample timestamps used.
* `covered_seconds`: timestamp span covered by the returned samples.
* `sample_count`: number of aggregate samples included.
* `average_write_bandwidth_kBps`: average aggregate write rate for the selected samples.
* `observed_sampled_volume_GB`: sum of the returned average-rate intervals.
* `coverage`: `complete` or `partial`.

A `partial` row is not an error by itself. It means that Prism Central returned less history than the requested window or that the available sample range did not exactly cover the requested boundaries. Missing time is not extrapolated.

## Interpretation limits

The primary metric is a workload-write proxy. It should not be presented as a direct measurement of:

* Azure VNet or peering traffic.
* Nutanix SyncRep network bytes.
* Billed cloud-network volume.
* Replication traffic after data reduction.

Use the detailed diagnostics to investigate missing VM metrics or unexpected coverage before using the result for sizing or cost discussions.
