#!/bin/bash 

get_batch_options() {
    local arguments=("$@")

    command_line_specified_study_folder=""
    command_line_specified_subj=""
    command_line_specified_run_local="FALSE"

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
            --Subjlist=*)
                command_line_specified_subj=${argument#*=}
                index=$(( index + 1 ))
                ;;
            --runlocal)
                command_line_specified_run_local="TRUE"
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

RawDataFolder="${HOME}/Documents/Data/ucl/gos_ich/verb_gen_krishnan/raw"
StudyFolder="${HOME}/Documents/Data/ucl/gos_ich/verb_gen_krishnan/processed" #Location of Subject folders (named by subjectID)
Subjlist=$(ls "${RawDataFolder}" | grep -v '^\.' | sort | tr '\n' ' ')  #All Krishnan subjects
EnvironmentScript="${HOME}/Apps/Programming/matlab-proj/HCPpipelines_MHVerbGen/Examples/Scripts/SetUpHCPPipeline.sh" #Pipeline environment script

if [ -n "${command_line_specified_study_folder}" ]; then
    StudyFolder="${command_line_specified_study_folder}"
fi

if [ -n "${command_line_specified_subj}" ]; then
    Subjlist="${command_line_specified_subj}"
fi

# Requirements for this script
#  installed versions of: FSL, Connectome Workbench (wb_command)
#  environment: HCPPIPEDIR, FSLDIR, CARET7DIR 

#Set up pipeline environment variables and software
source "$EnvironmentScript"

# Log the originating call
echo "$@"

#NOTE: syntax for QUEUE has changed compared to earlier pipeline releases,
#DO NOT include "-q " at the beginning
#default to no queue, implying run local
QUEUE=""
#QUEUE="hcp_priority.q"

########################################## INPUTS ########################################## 

#Scripts called by this script do assume they run on the results of the HCP minimal preprocesing pipelines from Q2

######################################### DO WORK ##########################################

# Krishnan data has a single fMRI run processed with single-run ICA-FIX (bandpass=2000).
# Use single-run FIX mode: populate fMRINames, leave MR FIX variables empty.
fMRINames="rfMRI_VERBGEN_AP"
mrfixNames=""
mrfixConcatName=""
mrfixNamesToUse=""
OutfMRIName="rfMRI_VERBGEN_AP"

# HighPass must match the bandpass value used in IcaFixProcessingBatch.sh (2000 s for single-run FIX)
HighPass="2000"
# fMRIProcSTRING must match: _Atlas_hp${HighPass}_clean
fMRIProcSTRING="_Atlas_hp2000_clean"
MSMAllTemplates="${HCPPIPEDIR}/global/templates/MSMAll"
MyelinTargetFile="${MSMAllTemplates}/Q1-Q6_RelatedParcellation210.MyelinMap_BC_MSMAll_2_d41_WRN_DeDrift.32k_fs_LR.dscalar.nii"
RegName="MSMAll_InitalReg"
HighResMesh="164"
LowResMesh="32"
InRegName="MSMSulc"
MatlabMode="1" #Mode=0 compiled Matlab, Mode=1 interpreted Matlab, Mode=2 Octave

fMRINames=`echo ${fMRINames} | sed 's/ /@/g'`

for Subject in $Subjlist ; do
    echo "    ${Subject}"

    if [[ "${command_line_specified_run_local}" == "TRUE" || "$QUEUE" == "" ]] ; then
        echo "About to locally run ${HCPPIPEDIR}/MSMAll/MSMAllPipeline.sh"
        queuing_command=("$HCPPIPEDIR"/global/scripts/captureoutput.sh)
    else
        echo "About to use fsl_sub to queue ${HCPPIPEDIR}/MSMAll/MSMAllPipeline.sh"
        queuing_command=("$FSLDIR/bin/fsl_sub" -q "$QUEUE")
    fi

    "${queuing_command[@]}" "$HCPPIPEDIR"/MSMAll/MSMAllPipeline.sh \
        --path="$StudyFolder" \
        --subject="$Subject" \
        --fmri-names-list="$fMRINames" \
        --multirun-fix-names="$mrfixNames" \
        --multirun-fix-concat-name="$mrfixConcatName" \
        --multirun-fix-names-to-use="$mrfixNamesToUse" \
        --output-fmri-name="$OutfMRIName" \
        --high-pass="$HighPass" \
        --fmri-proc-string="$fMRIProcSTRING" \
        --msm-all-templates="$MSMAllTemplates" \
        --myelin-target-file="$MyelinTargetFile" \
        --output-registration-name="$RegName" \
        --high-res-mesh="$HighResMesh" \
        --low-res-mesh="$LowResMesh" \
        --input-registration-name="$InRegName" \
        --matlab-run-mode="$MatlabMode"
done


