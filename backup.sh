#!/bin/bash

MINIO_ALIAS=archivesspace
MINIO_BUCKET_BACKUP=backup
BACKUP_FILE_NAME=aspace_backup_`date +%y%m%d%H%M%S`.zip

/home/archivesspace/archivesspace/scripts/backup.sh --mysqldump --output ${BACKUP_FILE_NAME}

if [ -f ${BACKUP_FILE_NAME} ]
then
    mc -q cp ${BACKUP_FILE_NAME} ${MINIO_ALIAS}/${MINIO_BUCKET_BACKUP}
    UPLOAD_SUCCESS=`mc ls ${MINIO_ALIAS} | grep ${BACKUP_FILE_NAME} | wc -l`
    if [ ${UPLOAD_SUCCESS} -gt 0 ]
    then
        rm ${BACKUP_FILE_NAME}
    fi
fi
