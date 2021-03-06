# This script is located in the home folder of the solve-rd-ateambot on the Fender cluster.
# It receives the newest samples from the EGA and uploads it to the catalogue if they do not yet exist.


#!/bin/bash

set -e
set -u

# Create required directories
mkdir -p "${HOME}/logs/"
mkdir -p "${HOME}/files/"

# Variables
header="EGA\tname\tmd5\ttypeFile\texperimentID\tdateCreated\tflag\textraInfo\tfilepath_sandbox"
path_to_files="${HOME}/files/"
file_to_be_uploaded="${path_to_files}/rd3_file.tsv"

TIMESTAMP=$(date +%Y-%m-%d)
TIMESTAMP_LAST_WEEK=$(date +%Y-%m-%d -d "${TIMESTAMP} -7 days")

FILE_TODAY="list_ega.${TIMESTAMP}"
FILE_LAST_WEEK="list_ega.${TIMESTAMP_LAST_WEEK}"

logFile="${HOME}/logs/log_${TIMESTAMP}"

# Cleanup files and logs older than 50 days, except for .tsv file
# Print files that will be deleted to log file
find "${HOME}/files/"* ! -path "${file_to_be_uploaded}" -type f -mtime +50 -print > "${logFile}";
find "${HOME}/files/"* ! -path "${file_to_be_uploaded}" -type f -mtime +50 -exec rm {} \;

find "${HOME}/logs/"* -type f -mtime +50 -print > "${logFile}";
find "${HOME}/logs/"* -type f -mtime +50 -exec rm {} \;

# Load modules 
module load PythonPlus/3.7.4-foss-2018b-v19.08.1
module load pyEGA3/v3.0.44-Python-3.7.4
module list


# Get EGA file
if [[ -e "${HOME}/credentials.hpc.json" ]]
then
	pyega3 -cf ${HOME}/credentials.hpc.json files 'EGAD00001005352' >> "${path_to_files}/${FILE_TODAY}_original"	
else
	echo "Missing file: credentials.hpc.json" > ${logFile}
	exit 1
fi

# Remove header and footer from original file
if [[ -e "${path_to_files}/${FILE_TODAY}_original" ]]
then
	grep '^EGA*' "${path_to_files}/${FILE_TODAY}_original" > "${path_to_files}/${FILE_TODAY}"
else
	echo "File ${path_to_files}/${FILE_TODAY}_original does not exist" >> ${logFile}
	exit 1
fi


# Get diffs between sorted and unique files of today and last week
if [[ -e "${path_to_files}/${FILE_LAST_WEEK}" ]]
then
	comm -13 <(sort -u "${path_to_files}/${FILE_LAST_WEEK}") <(sort -u "${path_to_files}/${FILE_TODAY}") > "${path_to_files}/new_samples_${TIMESTAMP}"
else
        echo "File to compare with: ${path_to_files}/${FILE_LAST_WEEK} does not exist" >> ${logFile}
        exit 1
fi

# Get only the sample name column to compare
if [[ -s "${path_to_files}/new_samples_${TIMESTAMP}" ]]
then
	cat "${path_to_files}/new_samples_${TIMESTAMP}" | awk '{print $1}' > "${path_to_files}/new_samples_${TIMESTAMP}_col1"
else
	echo "No changes between the files of ${TIMESTAMP_LAST_WEEK} and ${TIMESTAMP}. Nothing to upload..." >> ${logFile}
	exit 0
fi

# Fill array with new samples
index=0

while read line
do
    samples[$index]="${line}"
    index=$(($index+1))

done<"${path_to_files}/new_samples_${TIMESTAMP}_col1"


# Remove lines from file and Print header + new samples with all extra columns to new file
> "${file_to_be_uploaded}"
> "${path_to_files}/new_samples_input"
echo -e "${header}" > "${file_to_be_uploaded}"

for i in "${samples[@]}"
do
	grep "${i}" "${path_to_files}/new_samples_${TIMESTAMP}" >> "${path_to_files}/new_samples_input"
done


#Add all extra info to the file and upload to molgenis
while read LINE
do
	filename=$(basename -- "${LINE}")
	filepath=$(echo "${LINE}" | awk '{print $5}')
  	EGANO=$(echo "${LINE}" | awk '{print $1}')
        NAME=$(echo "${LINE}" | awk '{print $5}' | sed 's!.*/!!')

	if [[ "${NAME}" =~ ((E|P|FAM)[0-9]+).(.+)$ ]]
	then
		fileID="${BASH_REMATCH[1]}"
		extention="${BASH_REMATCH[3]}"
	else
		echo "unable to parse string $NAME"
		fileID=''
                extention=''
		continue
	fi	

        EXTENTION="${filename##*.}"
	if [[ "${extention}" =~ "g.vcf" ]]
	then
		ext="vcf"
		filepath_sandbox="/releases/freeze1/vcf/"
        elif [[ "${extention}" =~ "bam" ]]
	then
		ext="bam"
		filepath_sandbox="/releases/freeze1/bam/"
	elif [[ "${extention}" =~ "ped" ]]
        then
                ext="ped"
		filepath_sandbox="/releases/freeze1/ped/"
		fileID=''
        elif [[ "${extention}" =~ "cram" ]]
        then
            	ext="cram"
		filepath_sandbox="/releases/freeze1/cram/"
        elif [[ "${extention}" =~ "fastq" ]]
        then
            	ext="fastq"
		filepath_sandbox="/releases/freeze1/fastq/"
        elif [[ "${extention}" =~ "json" ]]
        then
            	ext="json"
		filepath_sandbox="/releases/freeze1/phenopacket/"
		fileID=''
        fi
	
	MD5="$(echo "${LINE}" | awk '{print $4}')"
	echo -e "${EGANO}\t${filepath}\t${MD5}\t${ext}\t${fileID}\t${TIMESTAMP}\t\t\t${filepath_sandbox}" >> "${file_to_be_uploaded}"

done <"${path_to_files}/new_samples_input"


# Upload new samples to catalogue
source "${HOME}/molgenis.cfg"

if curl -H "Content-Type: application/json" -X POST -d "{"username"="${USERNAME}", "password"="${PASSWORD}"}" https://${MOLGENISSERVER}/api/v1/login
then
	CURLRESPONSE=$(curl -H "Content-Type: application/json" -X POST -d "{"username"="${USERNAME}", "password"="${PASSWORD}"}" https://${MOLGENISSERVER}/api/v1/login)
        TOKEN=${CURLRESPONSE:10:32}
        curl -H "x-molgenis-token:${TOKEN}" -X POST -F"file=@${file_to_be_uploaded}" -FentityTypeId='rd3_freeze1_file' -Faction=add_update_existing -Fnotify=false -FmetadataAction=ignore https://${MOLGENISSERVER}/plugin/importwizard/importFile
else
	echo "curl couldn't connect to host, skipped the uploading of the rd3 file to ${MOLGENISSERVER}" >> ${logFile}
fi
