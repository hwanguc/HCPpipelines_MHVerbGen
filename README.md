# HCP Pipelines — Krishnan et al. (2021) Verb Generation fMRI

Adapted by **Han Wang (2025)** for re-processing T1w-only fMRI data from Krishnan et al. (2021).

Scripts for running the HCP Minimal Preprocessing Pipeline on the Krishnan verb generation dataset are under `Examples/Scripts/`. The pipeline runs seven stages in sequence — PreFreeSurfer, FreeSurfer, PostFreeSurfer, fMRIVolume, fMRISurface, ICA-FIX, and RestExtraction — coordinated by a single master batch script.

---

## Quick Start

```bash
cd ~/Apps/Programming/matlab-proj/HCPpipelines_MHVerbGen

bash Examples/Scripts/RunFullPipelineBatch.sh \
    --Computer=lab \
    --Subjects="sub-587BH sub-555BH" \
    --Parallel=2
```

---

## RunFullPipelineBatch.sh

Master script that runs all pipeline stages for one or more subjects. Stages already marked `DONE` in the log are skipped automatically, so it is safe to re-run after a crash.

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--Computer=home\|lab` | `home` | Machine profile. Sets `StudyFolder`, `SUBSAMPLE_CSV`, and Python interpreter paths for the specified machine. Use `--Computer=lab` on the lab workstation (TR-PH-234-10). |
| `--Subjects="sub-A sub-B"` | all 44 from CSV | Space-separated list of subject IDs to process. If omitted, reads all subjects from the subsample CSV. |
| `--Parallel=N` | `1` | Number of subjects to process concurrently. `--Parallel=4` is stable on the home machine (Ryzen 7 5800X, 32 GB RAM). `--Parallel=2` recommended for initial runs on the lab machine (Core Ultra 9 285, 32 GB RAM). |
| `--Stages="StageA StageB"` | `all` | Run only specific stages. Valid values: `PreFreeSurfer FreeSurfer PostFreeSurfer fMRIVolume fMRISurface IcaFix RestExtraction`. |
| `--MoveToExternal=PATH` | off | After each parallel wave completes, archive processed outputs to `PATH` (resolving symlinks for exFAT compatibility) and remove them from the internal drive. Switches dispatch to batched (wave) mode. Use on the home machine when the external drive is mounted. Do **not** use on the lab machine. |
| `--StudyFolder=PATH` | machine-specific | Override the default processed data folder. |
| `--ForceOverwrite` | off | Re-run stages already marked `DONE` in the log. |
| `--DryRun` | off | Print all commands that would be run without executing them. Always do a dry run first when testing new setups. |

### Machine-specific defaults

| Setting | `--Computer=home` | `--Computer=lab` |
|---------|-------------------|-----------------|
| `StudyFolder` | `~/Documents/Data/ucl/gos_ich/verb_gen_krishnan/processed` | `~/Documents/Data/verb_gen_krishnan/processed` |
| `SUBSAMPLE_CSV` | `~/Documents/Data/ucl/gos_ich/verb_gen_krishnan/behavioural_scq_sdq/...` | `~/Documents/Data/verb_gen_krishnan/behavioural_scq_sdq/...` |
| Python interpreter | `~/x64py-ml` venv | `~/neuroimaging-hcp-pfm` venv |
| MSM libs | `MSMPackage/lib` symlinks (FreeSurfer 8.2.0) | `HCPpipelines_MHVerbGen_local-add-on/MSMPackage/lib` |

### Example commands

Run two subjects in parallel on the lab machine:
```bash
nohup bash Examples/Scripts/RunFullPipelineBatch.sh \
    --Computer=lab \
    --Subjects="sub-587BH sub-555BH" \
    --Parallel=2 \
    > ~/Documents/Data/verb_gen_krishnan/processed/logs/run_587BH_555BH.log 2>&1 &
```

Run a batch on the home machine with archiving to external drive:
```bash
nohup bash Examples/Scripts/RunFullPipelineBatch.sh \
    --Subjects="sub-XXX sub-YYY sub-ZZZ sub-WWW" \
    --Parallel=4 \
    --MoveToExternal="/media/hanwang/Data/Data/ucl/gos_ich/verb_gen_krishnan/processed" \
    > ~/Documents/Data/ucl/gos_ich/verb_gen_krishnan/processed/logs/run_batch.log 2>&1 &
```

Dry run to preview without executing:
```bash
bash Examples/Scripts/RunFullPipelineBatch.sh \
    --Computer=lab \
    --Subjects="sub-587BH" \
    --DryRun
```

Re-run only the IcaFix and RestExtraction stages:
```bash
bash Examples/Scripts/RunFullPipelineBatch.sh \
    --Computer=lab \
    --Subjects="sub-587BH" \
    --Stages="IcaFix RestExtraction" \
    --ForceOverwrite
```

---

## Monitoring progress

### Log file (TSV)
```
~/Documents/Data/[ucl/gos_ich/]verb_gen_krishnan/processed/logs/pipeline_progress.log
```
Each completed or failed stage is written as a tab-separated row: `Subject`, `Stage`, `Timestamp`, `Status`.

### Timing summary script
Reports per-subject, per-stage durations. Pass `RUN_START` as the wall-clock time the run was launched:

```bash
RUN_START="2026-06-11T17:02:50" bash \
    ~/Documents/Data/verb_gen_krishnan/processed/logs/timing_summary.sh \
    sub-587BH sub-555BH
```

---

## Pipeline stages

| # | Stage | Script | Typical duration |
|---|-------|--------|-----------------|
| 1 | PreFreeSurfer | `PreFreeSurferPipelineBatch.sh` | ~20–26 min |
| 2 | FreeSurfer | `FreeSurferPipelineBatch.sh` | ~3.5–5 h (requires FreeSurfer 6.0.0) |
| 3 | PostFreeSurfer | `PostFreeSurferPipelineBatch.sh` | ~50–80 min |
| 4 | fMRIVolume | `GenericfMRIVolumeProcessingPipelineBatch.sh` | ~31 min |
| 5 | fMRISurface | `GenericfMRISurfaceProcessingPipelineBatch.sh` | ~4–9 min |
| 6 | IcaFix | `IcaFixProcessingBatch.sh` | ~30–54 min |
| 7 | RestExtraction | `ExtractRestBlocksBatch.sh` | ~12 min |

Total per subject: ~7–10 h depending on FreeSurfer complexity.

The RestExtraction stage identifies task-correlated ICA components, regresses them out, then extracts fixation-period timepoints into a rest-only dtseries file:
`MNINonLinear/Results/rfMRI_VERBGEN_AP_rest/rfMRI_VERBGEN_AP_rest_Atlas_hp2000_clean.dtseries.nii`

---

## Software requirements

| Software | Version | Location (home) | Location (lab) |
|----------|---------|-----------------|----------------|
| FSL | 6.x | `~/fsl` | `~/fsl` |
| FreeSurfer | 6.0.0 | via `.bashrc` | `/usr/local/freesurfer/6.0.0` |
| Connectome Workbench | any | `/opt/workbench/bin_linux64` | `/opt/workbench/bin_linux64` |
| MATLAB Runtime | R2025a + v93 | `/usr/local/MATLAB/MATLAB_Runtime/` | `/usr/local/MATLAB/MATLAB_Runtime/` |
| tcsh | any | system | `sudo apt-get install tcsh` |
| Python venv | 3.x + nibabel/numpy/scipy | `~/x64py-ml` | `~/neuroimaging-hcp-pfm` |

---

## Original HCP Pipelines documentation

The HCP Pipelines product is a set of tools for processing MRI images for the [Human Connectome Project][HCP], implementing the Minimal Preprocessing Pipeline described in [Glasser et al. 2013][GlasserEtAl].

* [Release Notes, Installation, and Usage][release-install-use]
* [FAQ][FAQ]
* [Project Wiki][wiki]

<!-- References -->
[HCP]: http://www.humanconnectome.org
[GlasserEtAl]: http://www.ncbi.nlm.nih.gov/pubmed/23668970
[release-install-use]: https://github.com/Washington-University/HCPpipelines/wiki/Installation-and-Usage-Instructions
[FAQ]: https://github.com/Washington-University/Pipelines/wiki/FAQ
[wiki]: https://github.com/Washington-University/Pipelines/wiki
