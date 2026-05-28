#!/bin/bash

# RunFullPipelineBatch.sh
#
# Master batch script for the HCP Minimal Preprocessing Pipeline on
# Krishnan et al. (2021) verb generation fMRI data (T1w-only, LegacyStyleData).
#
# Runs all pipeline stages in sequence for each subject:
#   PreFreeSurfer → FreeSurfer → PostFreeSurfer →
#   fMRIVolume → fMRISurface → IcaFix → RestExtraction
#
# Progress is logged to ${StudyFolder}/logs/pipeline_progress.log (TSV).
# Stages already marked DONE in the log are skipped with a warning unless
# --ForceOverwrite is set. If a stage fails, remaining stages for that subject
# are skipped and the script moves on to the next subject.
#
# Usage:
#   ./RunFullPipelineBatch.sh [options]
#
# Options:
#   --Subjects="sub-538BT sub-532BT"  Space-separated subject IDs
#                                     Default: all 44 subjects from the subsample CSV
#   --Stages="all"                    Stages to run (default: all)
#                                     Valid names: PreFreeSurfer FreeSurfer PostFreeSurfer
#                                                  fMRIVolume fMRISurface IcaFix RestExtraction
#   --Parallel=N                      Number of subjects to process concurrently (default: 1)
#   --ForceOverwrite                  Re-run stages already marked DONE in the log
#   --StudyFolder=<path>              Override default processed data folder
#   --DryRun                          Print commands without executing them

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBSAMPLE_CSV="${HOME}/Documents/Data/ucl/gos_ich/verb_gen_krishnan/behavioural_scq_sdq/dat_verbgen_scqsdq_subsample.csv"
StudyFolder="${HOME}/Documents/Data/ucl/gos_ich/verb_gen_krishnan/processed"
EnvironmentScript="${SCRIPTS_DIR}/SetUpHCPPipeline.sh"

ALL_STAGES=("PreFreeSurfer" "FreeSurfer" "PostFreeSurfer" "fMRIVolume" "fMRISurface" "IcaFix" "RestExtraction")

Subjlist=""
Stages="all"
Parallel=1
ForceOverwrite="FALSE"
DryRun="FALSE"

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
        *)
            echo "ERROR: Unrecognized option: ${arg}"
            exit 1
            ;;
    esac
done

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
# Per-subject processing function (all 7 stages in sequence)
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
# Main loop — sequential or parallel depending on --Parallel=N
# ---------------------------------------------------------------------------
echo "========================================"
echo "HCP Full Pipeline Batch Run"
echo "Subjects : ${Subjlist}"
echo "Stages   : ${StageList[*]}"
echo "Parallel : ${Parallel}"
echo "Log file : ${LogFile}"
echo "Overwrite: ${ForceOverwrite}"
echo "DryRun   : ${DryRun}"
echo "========================================"
echo ""

if [ "${Parallel}" -gt 1 ]; then
    job_count=0
    for Subject in ${Subjlist}; do
        process_subject "${Subject}" &
        job_count=$(( job_count + 1 ))
        if [ ${job_count} -ge "${Parallel}" ]; then
            # Wait for any one child to finish before launching the next
            wait -n 2>/dev/null || wait
            job_count=$(( job_count - 1 ))
        fi
    done
    wait  # drain remaining background jobs
else
    for Subject in ${Subjlist}; do
        process_subject "${Subject}"
    done
fi

echo "========================================"
echo "Batch run complete. Log: ${LogFile}"
echo "========================================"
