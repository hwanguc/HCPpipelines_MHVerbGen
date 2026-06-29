#!/bin/bash

# TrimInitialVolumesBatch.sh
#
# Produces the "full-run" product for network analyses (e.g. salience-network
# size / MS-HBM functional mapping) by discarding the initial noise-cancellation
# "learning" volumes from the ICA-FIX-cleaned CIFTI dtseries.
#
# This acquisition (matched to ABCD; Krishnan et al. 2021) acquires 325 volumes,
# of which the first 25 are acquired while the scanner noise-cancellation
# algorithm is learning the sequence and are discarded. Our pipeline runs ICA-FIX
# on the full 325-volume series; this script trims the first N volumes from the
# cleaned output so the full product matches the 300 usable task volumes.
#
# No pipeline stages are re-run; trimming is applied directly to the cleaned file.
#
# Strategy: wb_command -cifti-merge -column (N+1) -up-to <last>
#
# Output: rfMRI_VERBGEN_AP_full_Atlas_hp2000_clean.dtseries.nii
#         (placed in MNINonLinear/Results/rfMRI_VERBGEN_AP_full/)

get_batch_options() {
    local arguments=("$@")

    command_line_specified_study_folder=""
    command_line_specified_subj=""
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
            --initial-discard=*)
                # Number of initial volumes to discard (noise-cancellation learning
                # period). Default 25 for this acquisition.
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

Subjlist=$(ls "${RawDataFolder}" | grep -v '^\.' | sort | tr '\n' ' ')

if [ -n "${command_line_specified_subj}" ]; then
    Subjlist="${command_line_specified_subj}"
fi

InitialDiscard="${command_line_specified_initial_discard}"

source "$EnvironmentScript"

fMRIName="rfMRI_VERBGEN_AP"
FullfMRIName="rfMRI_VERBGEN_AP_full"

echo "Initial volumes to discard: ${InitialDiscard}"
echo ""

# ---------------------------------------------------------------------------
# Process each subject
# ---------------------------------------------------------------------------
for Subject in $Subjlist; do
    echo "${Subject}"

    ResultsDir="${StudyFolder}/${Subject}/MNINonLinear/Results"
    CleanedFile="${ResultsDir}/${fMRIName}/${fMRIName}_Atlas_hp2000_clean.dtseries.nii"
    OutputDir="${ResultsDir}/${FullfMRIName}"
    OutputFile="${OutputDir}/${FullfMRIName}_Atlas_hp2000_clean.dtseries.nii"

    if [ ! -f "${CleanedFile}" ]; then
        echo "  WARNING: ICA-FIX output not found, skipping: ${CleanedFile}"
        continue
    fi

    # Total number of volumes (maps) in the cleaned file
    NMaps=$(wb_command -file-information "${CleanedFile}" 2>/dev/null | grep -i "Number of Maps" | awk '{print $NF}')
    if [ -z "${NMaps}" ]; then
        echo "  ERROR: could not read volume count from ${CleanedFile}"
        continue
    fi

    StartCol=$(( InitialDiscard + 1 ))
    if [ "${StartCol}" -gt "${NMaps}" ]; then
        echo "  ERROR: initial-discard (${InitialDiscard}) >= number of volumes (${NMaps}) for ${Subject}"
        continue
    fi

    mkdir -p "${OutputDir}"

    # Keep volumes (InitialDiscard+1) .. NMaps
    wb_command -cifti-merge "${OutputFile}" \
        -cifti "${CleanedFile}" -column "${StartCol}" -up-to "${NMaps}"

    if [ $? -eq 0 ]; then
        out_cols=$(wb_command -file-information "${OutputFile}" 2>&1 | grep "Number of Maps" | awk '{print $NF}')
        echo "  Done. Output: ${OutputFile} (${out_cols} volumes; discarded first ${InitialDiscard})"
    else
        echo "  ERROR: wb_command -cifti-merge failed for ${Subject}"
        continue
    fi
done
