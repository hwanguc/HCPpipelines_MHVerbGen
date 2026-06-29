#!/bin/bash

# ExtractRestBlocksBatch.sh
#
# Extracts rest/fixation-period timepoints from ICA-FIX-cleaned fMRI CIFTI files
# and concatenates them into a rest-only dtseries file for functional connectivity
# analysis. No pipeline stages need to be re-run; extraction is applied directly to
# the fully preprocessed and denoised output.
#
# Strategy: post-processing extraction from rfMRI_VERBGEN_AP_Atlas_hp2000_clean.dtseries.nii
#   Per subject, extract the fixation-block timepoints directly from the
#   ICA-FIX-cleaned file with wb_command -cifti-merge. Task-evoked spillover into
#   the fixation blocks is reduced by a short HRF trim at the start of each block
#   (--hrf-trim, default 10s). No task-component regression is applied, so every
#   subject is treated identically (no per-subject component selection).
#
#   The acquired series retains the first N "noise-cancellation learning" volumes
#   (--initial-discard, default 25 for this ABCD-matched acquisition; Krishnan et
#   al. 2021, first 25 of 325 volumes discarded). The events file is timed relative
#   to the first usable volume, so all fixation-block columns are shifted by N to
#   align the task design with the retained (un-trimmed) data.
#
# Output: rfMRI_VERBGEN_AP_rest_Atlas_hp2000_clean.dtseries.nii
#         (placed in MNINonLinear/Results/rfMRI_VERBGEN_AP_rest/)

get_batch_options() {
    local arguments=("$@")

    command_line_specified_study_folder=""
    command_line_specified_subj=""
    command_line_specified_hrf_trim="10"
    command_line_specified_initial_discard="25"

    local index=0
    local numArgs=${#arguments[@]}
    local argument

    while [ ${index} -lt ${numArgs} ]; do
        argument=${arguments[index]}

        case ${argument} in
            --StudyFolder=*)
                command_line_specified_study_folder=${argument#*=}
                index=$(( index + 1 ))
                ;;
            --Subject=*)
                command_line_specified_subj=${argument#*=}
                index=$(( index + 1 ))
                ;;
            --hrf-trim=*)
                # Seconds to trim from the start of each rest block (to reduce HRF spillover
                # from the preceding task block). Default 10. This is the only mechanism
                # removing task-evoked signal, so do not set it to 0 for this dataset.
                command_line_specified_hrf_trim=${argument#*=}
                index=$(( index + 1 ))
                ;;
            --initial-discard=*)
                # Number of initial volumes discarded at acquisition (noise-cancellation
                # learning period; 25 for this acquisition). The events file is timed from
                # the first usable volume, so fixation-block columns are shifted by this
                # amount to align with the retained data. Default 25.
                command_line_specified_initial_discard=${argument#*=}
                index=$(( index + 1 ))
                ;;
            --runlocal)
                index=$(( index + 1 ))
                ;;
            *)
                echo ""
                echo "ERROR: Unrecognized Option: ${argument}"
                echo ""
                exit 1
                ;;
        esac
    done
}

get_batch_options "$@"

StudyFolder="${HOME}/Documents/Data/ucl/gos_ich/verb_gen_krishnan/processed"
EnvironmentScript="${HOME}/Apps/Programming/matlab-proj/HCPpipelines_MHVerbGen/Examples/Scripts/SetUpHCPPipeline.sh"

if [ -n "${command_line_specified_study_folder}" ]; then
    StudyFolder="${command_line_specified_study_folder}"
fi

DataRoot="$(dirname "${StudyFolder}")"
RawDataFolder="${DataRoot}/raw"
EventsFile="${DataRoot}/other/task-verbgen_events.tsv"

Subjlist=$(ls "${RawDataFolder}" | grep -v '^\.' | sort | tr '\n' ' ')

if [ -n "${command_line_specified_subj}" ]; then
    Subjlist="${command_line_specified_subj}"
fi

HRFTrimSec="${command_line_specified_hrf_trim}"
InitialDiscard="${command_line_specified_initial_discard}"

source "$EnvironmentScript"

ScriptsDir="${HCPPIPEDIR}/Examples/Scripts"
fMRIName="rfMRI_VERBGEN_AP"
RestfMRIName="rfMRI_VERBGEN_AP_rest"
TR=0.8

# ---------------------------------------------------------------------------
# Parse events file to find rest/fixation block column ranges.
# Returns space-separated "start_col:end_col" pairs (1-indexed, for wb_command).
#
# Column n (1-indexed) represents time t = (n-1) * TR, measured from the first
# USABLE volume. Because the acquired series still contains DISC initial volumes
# (discarded at acquisition), task time 0 corresponds to acquired column DISC+1,
# so every column is shifted by DISC.
# For a fixation block starting at onset O and ending at O+dur:
#   start_col = floor(O / TR) + 1 + DISC
#   end_col   = floor((O+dur) / TR) + DISC
# ---------------------------------------------------------------------------
get_rest_block_ranges() {
    local events_file="$1"
    local tr="$2"
    local hrf_trim_sec="$3"
    local initial_discard="$4"

    awk -v TR="$tr" -v HRF="$hrf_trim_sec" -v DISC="$initial_discard" '
    NR > 1 && $3 == "fixation" {
        onset    = $1 + HRF
        end_time = $1 + $2
        start_col = int(onset / TR) + 1 + DISC
        end_col   = int(end_time / TR) + DISC
        if (start_col <= end_col) {
            printf "%d:%d ", start_col, end_col
        }
    }
    ' "$events_file"
}

REST_RANGES=$(get_rest_block_ranges "$EventsFile" "$TR" "$HRFTrimSec" "$InitialDiscard")

if [ -z "$REST_RANGES" ]; then
    echo "ERROR: No fixation blocks found in ${EventsFile}"
    exit 1
fi

echo "TR: ${TR}s  |  HRF trim: ${HRFTrimSec}s  |  Initial volumes discarded: ${InitialDiscard}"
echo "Rest block ranges (1-indexed CIFTI columns): ${REST_RANGES}"

total_rest=0
for range in $REST_RANGES; do
    s="${range%%:*}"
    e="${range##*:}"
    total_rest=$(( total_rest + e - s + 1 ))
done
echo "Total rest volumes to extract: ${total_rest}"
echo ""

# ---------------------------------------------------------------------------
# Process each subject
# ---------------------------------------------------------------------------
for Subject in $Subjlist; do
    echo "${Subject}"

    ResultsDir="${StudyFolder}/${Subject}/MNINonLinear/Results"
    CleanedFile="${ResultsDir}/${fMRIName}/${fMRIName}_Atlas_hp2000_clean.dtseries.nii"
    OutputDir="${ResultsDir}/${RestfMRIName}"
    OutputFile="${OutputDir}/${RestfMRIName}_Atlas_hp2000_clean.dtseries.nii"

    if [ ! -f "${CleanedFile}" ]; then
        echo "  WARNING: ICA-FIX output not found, skipping: ${CleanedFile}"
        continue
    fi

    mkdir -p "${OutputDir}"

    # Extract fixation blocks directly from the ICA-FIX-cleaned file.
    # Task spillover is reduced by the --hrf-trim applied in the column ranges;
    # no task-component regression is applied (every subject treated identically).
    MergeInputFile="${CleanedFile}"

    # Extract rest blocks via wb_command -cifti-merge
    merge_cmd=(wb_command -cifti-merge "${OutputFile}")
    for range in $REST_RANGES; do
        start_col="${range%%:*}"
        end_col="${range##*:}"
        merge_cmd+=(-cifti "${MergeInputFile}" -column "${start_col}" -up-to "${end_col}")
    done

    "${merge_cmd[@]}"

    if [ $? -eq 0 ]; then
        n_cols=$(wb_command -file-information "${OutputFile}" 2>&1 | grep "Number of Maps" | awk '{print $NF}')
        echo "  Done. Output: ${OutputFile} (${n_cols} volumes)"
    else
        echo "  ERROR: wb_command -cifti-merge failed for ${Subject}"
        continue
    fi
done
