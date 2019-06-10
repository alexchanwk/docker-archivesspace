#!/bin/bash


MYSQL_DUMP_FILE="mysqldump.sql"
MYSQL_DUMP_FILE_TMP=".mysqldump.tmp.sql"
ASPACE_PATH="/home/archivesspace/archivesspace"
ASPACE_SCRIPTS_PATH="${ASPACE_PATH}/scripts"
ASPACE_DATA_PATH="${ASPACE_PATH}/data"

MINIO_ALIAS=archivesspace
MINIO_BUCKET_BACKUP=backup
BACKUP_FILE_PREFIX=aspace_backup_
LATEST_BACKUP_ZIP=`mc find ${MINIO_ALIAS}/${MINIO_BUCKET_BACKUP} --name "${BACKUP_FILE_PREFIX}_*.zip" --print {base} | sort -r | head -n 1`

if [ ! -z "${MYSQL_HOST_FILE}" ]
then
    MYSQL_HOST=`cat ${MYSQL_HOST_FILE}`
fi

if [ ! -z "${MYSQL_DATABASE_FILE}" ]
then
    MYSQL_DATABASE=`cat ${MYSQL_DATABASE_FILE}`
fi

if [ ! -z "${MYSQL_USER_FILE}" ]
then
    MYSQL_USER=`cat ${MYSQL_USER_FILE}`
fi

if [ ! -z "${MYSQL_PASSWORD_FILE}" ]
then
    MYSQL_PASSWORD=`cat ${MYSQL_PASSWORD_FILE}`
fi

if [ ! -z "${MYSQL_ROOT_PASSWORD_FILE}" ]
then
    MYSQL_ROOT_PASSWORD=`cat ${MYSQL_ROOT_PASSWORD_FILE}`
fi

USE_MYSQL="Y"

if [[ -z ${MYSQL_HOST}} || -z ${MYSQL_DATABASE} || -z ${MYSQL_USER} || -z ${MYSQL_PASSWORD} ]]
then
    USE_MYSQL="N"  
fi

# Must run from home directory
cd ~

# Wait if no backup file found
BACKUP_FILE_EXISTS="N"
until [[ ${BACKUP_FILE_EXISTS} == "Y" ]]
do
    LATEST_BACKUP_ZIP=`mc find ${MINIO_ALIAS}/${MINIO_BUCKET_BACKUP} --name "${BACKUP_FILE_PREFIX}*.zip" --print {base} | sort -r | head -n 1`
    if [ ! -z ${LATEST_BACKUP_ZIP} ]
    then
        BACKUP_FILE_EXISTS="Y"
        break
    else
        echo "Waiting for backup file at ${MINIO_ALIAS}/${MINIO_BUCKET_BACKUP}..."
        sleep 5
    fi
done

if [ ! -z "${LATEST_BACKUP_ZIP}" ]
then
    BACKUP_FOLDER=`echo ${LATEST_BACKUP_ZIP} | cut -d"." -f1`
    rm -f ~/${LATEST_BACKUP_ZIP}
    rm -rf ~/${BACKUP_FOLDER}
    mkdir ~/${BACKUP_FOLDER}
    mc -q cp ${MINIO_ALIAS}/${MINIO_BUCKET_BACKUP}/${LATEST_BACKUP_ZIP} ~/
    unzip -q ${LATEST_BACKUP_ZIP} -d ~/${BACKUP_FOLDER}

    cd ~/${BACKUP_FOLDER}

    # Restore database
    if [[ ${USE_MYSQL} == "Y" ]]
    then
        if [ -f ${MYSQL_DUMP_FILE} ]
        then
            echo "Restoring from mysqldump..."
            echo
            sed 's/\sDEFINER=`[^`]*`@`[^`]*`//g' -i ${MYSQL_DUMP_FILE}
            mysql -h ${MYSQL_HOST} -u${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DATABASE} < ${MYSQL_DUMP_FILE}
            
            # Cleanup deleted_records table since frontend indexes will be regenerated
            echo "Purging deleted_records table..."
            echo
            mysql -h ${MYSQL_HOST} -u${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DATABASE} -e "DELETE FROM deleted_records"
            
            echo "mysqldump restore completed!"
            echo
        fi
    else
        DEMO_DB_BACKUP_PATH=`find ~/${BACKUP_FOLDER} -type d -name "demo_db_backup_*" | sort -r | head -n 1`
        if [ -d ${DEMO_DB_BACKUP_PATH} ]
        then
            cp -a ${DEMO_DB_BACKUP_PATH}/archivesspace_demo_db ${ASPACE_DATA_PATH}
        fi
    fi

    # Restore search indexes
    SOLR_BACKUP_BASE_PATH=`find ~/${BACKUP_FOLDER} -type d -name "solr.backup-*"`
    SOLR_BACKUP_PATH=`find ~/${BACKUP_FOLDER} -type d -name "snapshot.*"`
    if [ ! -z ${SOLR_BACKUP_PATH} ]
    then
        if [ -f ${ASPACE_SCRIPTS_PATH}/checkindex.sh ]
        then
            echo "Checking backup indexes..."
            ${ASPACE_SCRIPTS_PATH}/checkindex.sh ${SOLR_BACKUP_PATH}
        fi

        echo "Restoring search indexes..."
        echo
        rm -rf ${ASPACE_DATA_PATH}/solr_index
        mkdir -p ${ASPACE_DATA_PATH}/solr_index/index
        cp -a ${SOLR_BACKUP_PATH}/* ${ASPACE_DATA_PATH}/solr_index/index
        rm -rf ${ASPACE_DATA_PATH}/indexer_state
        cp -a ${SOLR_BACKUP_BASE_PATH}/indexer_state ${ASPACE_DATA_PATH}

        if [ -f ${ASPACE_SCRIPTS_PATH}/checkindex.sh ]
        then
            echo "Checking restored indexes..."
            ${ASPACE_SCRIPTS_PATH}/checkindex.sh ${ASPACE_DATA_PATH}/solr_index/index
        fi

        echo "Search index restore completed!"
        echo
    fi

    # Clean up
    rm -f ~/${LATEST_BACKUP_ZIP}
    rm -rf ~/${BACKUP_FOLDER}
fi
