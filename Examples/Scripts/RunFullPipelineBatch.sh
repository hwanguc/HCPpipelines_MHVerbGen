#!/bin/bash

# RunFullPipelineBatch.sh
#
# Master batch script for the HCP Minimal Preprocessing Pipeline on
# Krishnan et al. (2021) verb generation fMRI data (T1w-only, LegacyStyleData).
#
# Runs all pipeline stages in sequence for each subject:
#   PreFreeSurfer → FreeSurfer → PostFreeSurfer →
#   fMRIVolume → fMRISurface → IcaFix → RestExtraction → FullExtraction
#
# Progress is logged to ${StudyFolder}/logs/pipeline_progress.log (TSV).
# Stages already marked DONE in the log are skipped unless --ForceOverwrite is set.
# If a stage fails, remaining stages for that subject are skipped.
#
# Usage:
#   ./RunFullPipelineBatch.sh [options]
#
# Options:
#   --Subjects="sub-538BT sub-532BT"  Space-separated subject IDs
#                                     Default: all 44 subjects from the subsample CSV
#   --Stages="all"                    Stages to run (default: all)
#                                     Valid: PreFreeSurfer FreeSurfer PostFreeSurfer
#                                            fMRIVolume fMRISurface IcaFix RestExtraction
#                                            FullExtraction
#   --Parallel=N                      Number of subjects to process concurrently (default: 1)
#   --MoveToExternal=PATH             After each parallel batch completes, copy processed
#                                     outputs to PATH (resolving all symlinks for exFAT
#                                     compatibility) and remove them from the internal drive,
#                                     leaving only unprocessed/ on the internal drive.
#                                     Switches parallel dispatch to batched mode.
#   --ForceOverwrite                  Re-run stages already marked DONE in the log
#   --StudyFolder=PATH                Override default processed data folder
#   --DryRun                          Print commands without executing them
#   --Computer=home|lab               Machine profile (default: home)
#                                     home: ~/Documents/Data/ucl/gos_ich/verb_gen_krishnan/...
#                                     lab:  ~/Documents/Data/verb_gen_krishnan/...

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EnvironmentScript="${SCRIPTS_DIR}/SetUpHCPPipeline.sh"
Computer="home"

ALL_STAGES=("PreFreeSurfer" "FreeSurfer" "PostFreeSurfer" "fMRIVolume" "fMRISurface" "IcaFix" "RestExtraction" "FullExtraction")

Subjlist=""
Stages="all"
Parallel=1
ForceOverwrite="FALSE"
DryRun="FALSE"
ExternalFolder=""

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "${arg}" in
        --Subjects=*)
            Subjlist="${arg#*=}"
            ;;
        --Stages=*)
            Stages="${arg#*=}"
            ;;
        --Parallel=*)
            Parallel="${arg#*=}"
            ;;
        --StudyFolder=*)
            StudyFolder="${arg#*=}"
            ;;
        --ForceOverwrite)
            ForceOverwrite="TRUE"
            ;;
        --DryRun)
            DryRun="TRUE"
            ;;
        --MoveToExternal=*)
            ExternalFolder="${arg#*=}"
            ;;
        --Computer=*)
            Computer="${arg#*=}"
            ;;
        *)
            echo "ERROR: Unrecognized option: ${arg}"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Set machine-specific paths based on --Computer
# ---------------------------------------------------------------------------
case "${Computer}" in
    home)
        StudyFolder="${StudyFolder:-${HOME}/Documents/Data/ucl/gos_ich/verb_gen_krishnan/processed}"
        SUBSAMPLE_CSV="${SUBSAMPLE_CSV:-${HOME}/Documents/Data/ucl/gos_ich/verb_gen_krishnan/behavioural_scq_sdq/dat_verbgen_scqsdq_subsample.csv}"
        ;;
    lab)
        StudyFolder="${StudyFolder:-${HOME}/Documents/Data/verb_gen_krishnan/processed}"
        SUBSAMPLE_CSV="${SUBSAMPLE_CSV:-${HOME}/Documents/Data/verb_gen_krishnan/behavioural_scq_sdq/dat_verbgen_scqsdq_subsample.csv}"
        ;;
    *)
        echo "ERROR: Unknown --Computer value '${Computer}'. Valid: home, lab"
        exit 1
        ;;
esac
export COMPUTER="${Computer}"

# ---------------------------------------------------------------------------
# Build subject list from CSV if not specified on command line
# ---------------------------------------------------------------------------
if [ -z "${Subjlist}" ]; then
    if [ ! -f "${SUBSAMPLE_CSV}" ]; then
        echo "ERROR: Subsample CSV not found: ${SUBSAMPLE_CSV}"
        echo "       Specify subjects explicitly with --Subjects=\"sub-XXX sub-YYY\""
        exit 1
    fi
    Subjlist=$(awk -F',' 'NR>1 {gsub(/"/, "", $2); print "sub-" $2}' "${SUBSAMPLE_CSV}" | tr '\n' ' ')
fi

# ---------------------------------------------------------------------------
# Validate --MoveToExternal path is accessible
# ---------------------------------------------------------------------------
if [ -n "${ExternalFolder}" ] && [ "${DryRun}" = "FALSE" ]; then
    ext_parent=$(dirname "${ExternalFolder}")
    if [ ! -d "${ext_parent}" ]; then
        echo "ERROR: External drive not accessible — parent directory not found: ${ext_parent}"
        echo "       Check that the drive is plugged in and mounted."
        exit 1
    fi
    mkdir -p "${ExternalFolder}" || {
        echo "ERROR: Cannot create external folder: ${ExternalFolder}"
        echo "       Check that the drive is plugged in and mounted."
        exit 1
    }
fi

# ---------------------------------------------------------------------------
# Build list of stages to run
# ---------------------------------------------------------------------------
if [ "${Stages}" = "all" ]; then
    StageList=("${ALL_STAGES[@]}")
else
    IFS=' ' read -r -a StageList <<< "${Stages}"
    for stage in "${StageList[@]}"; do
        valid=0
        for s in "${ALL_STAGES[@]}"; do
            [ "${stage}" = "${s}" ] && valid=1 && break
        done
        if [ ${valid} -eq 0 ]; then
            echo "ERROR: Unknown stage '${stage}'. Valid stages: ${ALL_STAGES[*]}"
            exit 1
        fi
    done
fi

# ---------------------------------------------------------------------------
# Set up environment and log file
# ---------------------------------------------------------------------------
source "${EnvironmentScript}"

LogDir="${StudyFolder}/logs"
LogFile="${LogDir}/pipeline_progress.log"
mkdir -p "${LogDir}"

if [ ! -f "${LogFile}" ]; then
    echo -e "Subject\tStage\tTimestamp\tStatus" > "${LogFile}"
fi

# ---------------------------------------------------------------------------
# Helper: check if a stage is already logged as DONE for a subject
# ---------------------------------------------------------------------------
is_done() {
    local subject="$1"
    local stage="$2"
    grep -qP "^${subject}\t${stage}\t.*\tDONE$" "${LogFile}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: write a log entry
# ---------------------------------------------------------------------------
log_entry() {
    local subject="$1"
    local stage="$2"
    local status="$3"
    local ts
    ts=$(date +"%Y-%m-%dT%H:%M:%S")
    [ "${DryRun}" = "FALSE" ] && echo -e "${subject}\t${stage}\t${ts}\t${status}" >> "${LogFile}"
}

# ---------------------------------------------------------------------------
# Helper: run a stage script for a single subject
# ---------------------------------------------------------------------------
run_stage_script() {
    local script="$1"
    local subject="$2"
    local extra_args="${3:-}"

    local cmd="${SCRIPTS_DIR}/${script} --StudyFolder=${StudyFolder} --Subject=${subject} --runlocal ${extra_args}"

    if [ "${DryRun}" = "TRUE" ]; then
        echo "  [DryRun] ${cmd}"
        return 0
    fi

    echo "  Running: ${script}"
    bash ${cmd}
    return $?
}

# ---------------------------------------------------------------------------
# Helper: archive a subject to external drive after successful processing.
#
# Copies all processed output directories to ExternalFolder, resolving
# symlinks so actual file content is stored (exFAT compatible). Also copies
# unprocessed/ with symlinks resolved so the external drive holds the full
# self-contained dataset. Then removes all output directories from the
# internal drive, leaving only unprocessed/ there.
# ---------------------------------------------------------------------------
archive_to_external() {
    local subject="$1"
    local src="${StudyFolder}/${subject}"
    local dst="${ExternalFolder}/${subject}"

    if [ "${DryRun}" = "TRUE" ]; then
        echo "  [DryRun] Would archive ${subject}: ${src} → ${dst} (symlinks resolved)"
        return 0
    fi

    echo "  [ARCHIVE] ${subject}: copying to external drive (resolving symlinks)..."
    mkdir -p "${dst}"

    local failed=0

    # --no-perms/--no-owner/--no-group: exFAT doesn't support Unix permissions
    local rsync_opts=(-a --copy-links --no-perms --no-owner --no-group)

    # Copy unprocessed/ to external with symlinks resolved
    if [ -d "${src}/unprocessed" ]; then
        rsync "${rsync_opts[@]}" "${src}/unprocessed/" "${dst}/unprocessed/" \
            || { echo "  [ARCHIVE ERROR] Failed to copy unprocessed/ for ${subject}"; failed=1; }
    fi

    # Copy each processed output dir to external (symlinks resolved), then delete from internal
    for dir in "${src}"/*/; do
        local dname
        dname=$(basename "${dir}")
        [ "${dname}" = "unprocessed" ] && continue

        rsync "${rsync_opts[@]}" "${src}/${dname}/" "${dst}/${dname}/" \
            && rm -rf "${src:?}/${dname}" \
            || { echo "  [ARCHIVE ERROR] Failed to copy ${dname} for ${subject}"; failed=1; }
    done

    if [ ${failed} -eq 0 ]; then
        echo "  [ARCHIVE] ${subject}: done. Internal drive retains only: ${src}/unprocessed/"
    else
        echo "  [ARCHIVE] ${subject}: completed with errors — check output above."
    fi
    return ${failed}
}

# ---------------------------------------------------------------------------
# Per-subject processing function (all requested stages in sequence)
# ---------------------------------------------------------------------------
process_subject() {
    local Subject="$1"
    local rc

    echo "------------------------------------------------------------"
    echo "Subject: ${Subject}"
    echo "------------------------------------------------------------"

    local subject_failed=0

    for Stage in "${StageList[@]}"; do

        # Skip check
        if [ "${ForceOverwrite}" = "FALSE" ] && is_done "${Subject}" "${Stage}"; then
            echo "  [SKIP] ${Stage} already DONE for ${Subject} (use --ForceOverwrite to re-run)"
            continue
        fi

        if [ ${subject_failed} -eq 1 ]; then
            echo "  [SKIP] ${Stage} — skipped because a prior stage failed"
            continue
        fi

        echo "  [START] ${Stage} — $(date +"%Y-%m-%dT%H:%M:%S")"

        case "${Stage}" in
            PreFreeSurfer)
                run_stage_script "PreFreeSurferPipelineBatch.sh" "${Subject}"
                rc=$?
                ;;
            FreeSurfer)
                run_stage_script "FreeSurferPipelineBatch.sh" "${Subject}"
                rc=$?
                ;;
            PostFreeSurfer)
                run_stage_script "PostFreeSurferPipelineBatch.sh" "${Subject}"
                rc=$?
                ;;
            fMRIVolume)
                run_stage_script "GenericfMRIVolumeProcessingPipelineBatch.sh" "${Subject}"
                rc=$?
                ;;
            fMRISurface)
                run_stage_script "GenericfMRISurfaceProcessingPipelineBatch.sh" "${Subject}"
                rc=$?
                ;;
            IcaFix)
                run_stage_script "IcaFixProcessingBatch.sh" "${Subject}"
                rc=$?
                ;;
            RestExtraction)
                run_stage_script "ExtractRestBlocksBatch.sh" "${Subject}"
                rc=$?
                ;;
            FullExtraction)
                run_stage_script "TrimInitialVolumesBatch.sh" "${Subject}"
                rc=$?
                ;;
        esac

        if [ ${rc} -eq 0 ]; then
            echo "  [DONE]  ${Stage} — $(date +"%Y-%m-%dT%H:%M:%S")"
            log_entry "${Subject}" "${Stage}" "DONE"
        else
            echo "  [FAIL]  ${Stage} — exit code ${rc}"
            log_entry "${Subject}" "${Stage}" "FAILED"
            subject_failed=1
        fi

    done

    echo ""
}

# ---------------------------------------------------------------------------
# Helper: copy the logs directory to the external drive
# ---------------------------------------------------------------------------
sync_logs_to_external() {
    if [ "${DryRun}" = "TRUE" ]; then
        echo "  [DryRun] Would sync logs: ${LogDir} → ${ExternalFolder}/logs/"
        return 0
    fi
    local ext_logs="${ExternalFolder}/logs"
    mkdir -p "${ext_logs}"
    rsync -a --no-perms --no-owner --no-group "${LogDir}/" "${ext_logs}/" \
        && echo "  [LOGS] Synced logs to ${ext_logs}" \
        || echo "  [LOGS ERROR] Failed to sync logs to ${ext_logs}"
}

# ---------------------------------------------------------------------------
# Helper: check if all requested stages are DONE for a subject
# ---------------------------------------------------------------------------
all_stages_done() {
    local subject="$1"
    for stage in "${StageList[@]}"; do
        is_done "${subject}" "${stage}" || return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# Main dispatch
#
# Two modes:
#   Rolling pool  (Parallel > 1, no --MoveToExternal): launch up to N jobs,
#                 start the next as soon as one finishes. Most CPU-efficient.
#
#   Batched       (--MoveToExternal set, any Parallel): process subjects in
#                 waves of N; wait for the entire wave before archiving to
#                 external drive and starting the next wave.
# ---------------------------------------------------------------------------
echo "========================================"
echo "HCP Full Pipeline Batch Run"
echo "Computer : ${Computer}"
echo "Subjects : ${Subjlist}"
echo "Stages   : ${StageList[*]}"
echo "Parallel : ${Parallel}"
echo "Log file : ${LogFile}"
echo "Overwrite: ${ForceOverwrite}"
echo "DryRun   : ${DryRun}"
[ -n "${ExternalFolder}" ] && echo "Archive  : ${ExternalFolder}"
echo "========================================"
echo ""

if [ "${Parallel}" -gt 1 ] && [ -z "${ExternalFolder}" ]; then
    # --- Rolling pool: efficient when archiving is not needed ---
    job_count=0
    for Subject in ${Subjlist}; do
        process_subject "${Subject}" &
        job_count=$(( job_count + 1 ))
        if [ ${job_count} -ge "${Parallel}" ]; then
            wait -n 2>/dev/null || wait
            job_count=$(( job_count - 1 ))
        fi
    done
    wait

else
    # --- Batched dispatch: required for archive-after-wave behaviour ---
    read -r -a SubjArray <<< "${Subjlist}"
    total=${#SubjArray[@]}
    i=0

    while [ ${i} -lt ${total} ]; do
        # Build this wave (up to Parallel subjects)
        wave=()
        for (( j=0; j<Parallel && (i+j)<total; j++ )); do
            wave+=("${SubjArray[$((i+j))]}")
        done

        echo "--- Wave: ${wave[*]} ---"

        # Launch all subjects in the wave
        if [ "${Parallel}" -gt 1 ]; then
            for Subject in "${wave[@]}"; do
                process_subject "${Subject}" &
            done
            wait   # wait for entire wave to finish
        else
            for Subject in "${wave[@]}"; do
                process_subject "${Subject}"
            done
        fi

        # Archive completed subjects in this wave to external drive
        if [ -n "${ExternalFolder}" ]; then
            for Subject in "${wave[@]}"; do
                if all_stages_done "${Subject}"; then
                    archive_to_external "${Subject}"
                else
                    echo "  [ARCHIVE] Skipping ${Subject} — not all stages completed successfully."
                fi
            done
            sync_logs_to_external
        fi

        i=$(( i + Parallel ))
    done
fi

echo "========================================"
echo "Batch run complete. Log: ${LogFile}"
[ -n "${ExternalFolder}" ] && sync_logs_to_external
echo "========================================"
