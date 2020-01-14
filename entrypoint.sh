#!/bin/bash

ASPACE_ROOT_PATH="/home/archivesspace/archivesspace"
ASPACE_CONFIG_FILE=~/config.rb
AS_EXT_PLUGIN_URL_PREFIX="ASPACE_EXT_PLUGIN_URL_"
BACKUP_CMD="/backup.sh"
MINIO_ALIAS=archivesspace
MINIO_BUCKET_BACKUP=backup
MINIO_BUCKET_INFO=info
SETUP_LOG_FILE_NAME="setup.log"
SETUP_LOG_FILE="/home/archivesspace/${SETUP_LOG_FILE_NAME}"
MYSQL_CNF_FILE=~/.my.cnf

USE_MYSQL="Y"
ASPACE_SKIP_RESTORE_DATABASE="N"
ASPACE_SKIP_SETUP_DATABASE="N"
ASPACE_SKIP_START_SERVER="N"

if [ ! -z "${SKIP_RESTORE_DATABASE}" ]
then
    if [[ ${SKIP_RESTORE_DATABASE} == "Y" ]]
    then
        ASPACE_SKIP_RESTORE_DATABASE="Y"
    fi
fi

if [ ! -z "${SKIP_SETUP_DATABASE}" ]
then
    if [[ ${SKIP_SETUP_DATABASE} == "Y" ]]
    then
        ASPACE_SKIP_SETUP_DATABASE="Y"
    fi
fi

if [ ! -z "${SKIP_START_SERVER}" ]
then
    if [[ ${SKIP_START_SERVER} == "Y" ]]
    then
        ASPACE_SKIP_START_SERVER="N"
    fi
fi

if [ ! -z "${MYSQL_ROOT_PASSWORD_FILE}" ]
then
    MYSQL_ROOT_PASSWORD=`cat ${MYSQL_ROOT_PASSWORD_FILE}`
fi

if [ ! -z "${MYSQL_PASSWORD_FILE}" ]
then
    MYSQL_PASSWORD=`cat ${MYSQL_PASSWORD_FILE}`
fi

if [ ! -z "${MINIO_ACCESS_KEY_FILE}" ]
then
    MINIO_ACCESS_KEY=`cat ${MINIO_ACCESS_KEY_FILE}`
fi

if [ ! -z "${MINIO_SECRET_KEY_FILE}" ]
then
    MINIO_SECRET_KEY=`cat ${MINIO_SECRET_KEY_FILE}`
fi

if [[ -z ${MYSQL_HOST} || -z ${MYSQL_DATABASE} || -z ${MYSQL_USER} || -z ${MYSQL_PASSWORD} ]]
then
    USE_MYSQL="N"
fi

# Configure Minio Client
echo "Installing minio client..." | tee -a ${SETUP_LOG_FILE}
cd minio
wget -nv https://dl.minio.io/client/mc/release/linux-amd64/mc
chmod +x mc
cd ~

echo "Configuring minio ..." | tee -a ${SETUP_LOG_FILE}
MINIO_HOST_ADDED=`mc config host ls | grep ${MINIO_ALIAS} | wc -l`
until [[ ${MINIO_HOST_ADDED} > 0 ]]
do
    mc config host add ${MINIO_ALIAS} http://${MINIO_HOST}:9000 ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} S3v4
    if [[ $? == 0 ]]
    then
        MINIO_HOST_ADDED=`mc config host ls | grep ${MINIO_ALIAS} | wc -l`
        break
    else
        sleep 5
    fi
done

# Wait for MINIO container ready
MINIO_READY="N"
until [[ ${MINIO_READY} == "Y" ]]
do
    MINIO_ENDPOINT_READY=`curl -s -o /dev/null -w "%{http_code}" http://${MINIO_HOST}:9000/minio/health/ready | grep 200 | wc -l`
    if [[ ${MINIO_ENDPOINT_READY} > 0 ]]
    then
        MINIO_READY="Y"
        break
    else
        echo "Waiting for MINIO Server startup..."
        sleep 5
    fi
done

BACKUP_BUCKET_EXISTS=`mc ls ${MINIO_ALIAS} | grep ${MINIO_BUCKET_BACKUP} | wc -l`
if [ ${BACKUP_BUCKET_EXISTS} -le 0 ]
then
    mc mb ${MINIO_ALIAS}/${MINIO_BUCKET_BACKUP}
fi

INFO_BUCKET_EXISTS=`mc ls ${MINIO_ALIAS} | grep ${MINIO_BUCKET_INFO} | wc -l`
if [ ${INFO_BUCKET_EXISTS} -le 0 ]
then
    mc mb ${MINIO_ALIAS}/${MINIO_BUCKET_INFO}
fi

if [[ ${USE_MYSQL} == "Y" ]]
then
    # Configure MYSQL Client
    if [ ! -f ${MYSQL_CNF_FILE} ]
    then
        echo "[client]" > ${MYSQL_CNF_FILE}
        echo "host=${MYSQL_HOST}" >> ${MYSQL_CNF_FILE}
        echo "database=${MYSQL_DATABASE}" >> ${MYSQL_CNF_FILE}
        echo "user="${MYSQL_USER} >> ${MYSQL_CNF_FILE}
        echo "password="${MYSQL_PASSWORD} >> ${MYSQL_CNF_FILE}
    fi

    # Wait for MySQL container ready
    MYSQL_READY="N"
    until [[ ${MYSQL_READY} == "Y" ]]
    do
        mysql -e "EXIT" 1>/dev/null 2>&1
        if [[ $? == 0 ]]
        then
            MYSQL_READY="Y"
            break
        else
            echo "Waiting for MySQL startup..."
            sleep 5
        fi
    done
fi

# Setup ArchivesSpace
START_TIME=`date "+%Y-%m-%d %H:%M:%S"`
echo "Setup ArchivesSpace started at ${START_TIME} ..." | tee -a ${SETUP_LOG_FILE}
echo | tee -a ${SETUP_LOG_FILE}

echo "Configure timezone ..." | tee -a ${SETUP_LOG_FILE}
if [ ! -z "${TIME_ZONE}" ]
then
    if [ -d /usr/share/zoneinfo/${TIME_ZONE} ]
    then
        rm -f /etc/localtime
        ln -s /usr/share/zoneinfo/${TIME_ZONE} /etc/localtime
    fi
fi

# MYSQL configurations
if [[ ${USE_MYSQL} == "Y" ]]
then
    echo "Configure database UTF8..." | tee -a ${SETUP_LOG_FILE}
    MYSQL_CHAR_SET=`mysql -Ns -e "show variables like \"character_set_database\";" | awk '{print $2}'`
    MYSQL_COLAT=`mysql -Ns -e "show variables like \"collation_database\";" | awk '{print $2}'`
    if [[ ${MYSQL_CHAR_SET} == "utf8" && ${MYSQL_COLAT} == "utf8_general_ci" ]]
    then
        echo "Database character set already UTF8!" | tee -a ${SETUP_LOG_FILE}
        echo
    else
        mysql -e "ALTER DATABASE ${MYSQL_DATABASE} CHARACTER SET utf8 COLLATE utf8_general_ci"
        if [[ $? == 0 ]]
        then
            echo "Database character set to UTF8 successfully!" | tee -a ${SETUP_LOG_FILE}
            echo
        else
            echo "Failed to set MYSQL character set!" | tee -a ${SETUP_LOG_FILE}
            exit 1
        fi
    fi
fi

# Generate ArchivesSpace config file
echo "Generating config file ..." | tee -a ${SETUP_LOG_FILE}
set -f
cat /dev/null > ${ASPACE_CONFIG_FILE}
exec 3>&1 1>>${ASPACE_CONFIG_FILE}

# Database connection string
if [[ ${USE_MYSQL} == "Y" ]]
then
    echo "AppConfig[:db_url] = \"jdbc:mysql://${MYSQL_HOST}:3306/${MYSQL_DATABASE}?user=${MYSQL_USER}&password=${MYSQL_PASSWORD}&useUnicode=true&characterEncoding=UTF-8\""
fi

# Configurations
if [ ! -z "${ASPACE_APP_CONFIG_FILES}" ]
then
    find / -maxdepth 1 -type f -name ${ASPACE_APP_CONFIG_FILES} | xargs cat && echo && echo
fi

if [ ! -z "${ASPACE_APP_CONFIG_SECRETS_FILES}" ]
then
    find /run/secrets -maxdepth 1 -type f -name ${ASPACE_APP_CONFIG_SECRETS_FILES} | xargs cat && echo && echo
fi

exec 1>&3 3>&-
set +f
echo "ArchivesSpace config file generated successfully!" | tee -a ${SETUP_LOG_FILE}
echo

echo "Applying config file and clean up ..." | tee -a ${SETUP_LOG_FILE}
cd ~
mv ${ASPACE_ROOT_PATH}/config/config.rb ${ASPACE_ROOT_PATH}/config/config.rb.original
cp -f ${ASPACE_CONFIG_FILE} ${ASPACE_ROOT_PATH}/config/config.rb
rm -f ${ASPACE_CONFIG_FILE}
echo

# Add custom plugins
for env in $(compgen -v)
do
    if [[ ${env} == ${AS_EXT_PLUGIN_URL_PREFIX}* ]]
    then
        PLUGIN_NAME_UNNORMALIZED=${env:22}
        PLUGIN_NAME=${PLUGIN_NAME_UNNORMALIZED//_/-}
        PLUGIN_URL=`echo ${!env} | xargs`

        echo "Adding external plugin ${PLUGIN_NAME} from ${PLUGIN_URL}..."
        if [[ ! -z ${PLUGIN_NAME} && ! -z ${PLUGIN_URL} ]]
        then
            cd ${ASPACE_ROOT_PATH}/plugins
            rm -rf ${PLUGIN_NAME}
            mkdir ${PLUGIN_NAME}
            cd ${PLUGIN_NAME}
            wget -nv -O ${PLUGIN_NAME}.tar.gz ${PLUGIN_URL}
            if [ -f ${PLUGIN_NAME}.tar.gz ]
            then
                tar -zxf ${PLUGIN_NAME}.tar.gz
                rm -f ${PLUGIN_NAME}.tar.gz
            fi
        fi
    fi
done

# Restore database from latest backup
if [[ "${ASPACE_SKIP_RESTORE_DATABASE}" == "Y" ]]
then
    echo "Restore Database skipped!" | tee -a ${SETUP_LOG_FILE}
else
    if [[ ${USE_MYSQL} == "Y" ]]
    then
        DB_TABLE_COOUNT=`mysql -Ns -e "show tables;" | wc -l`
        if [[ ${DB_TABLE_COOUNT} > 0 ]]
        then
            echo "Table already exists in database! Database restore skipped!" | tee -a ${SETUP_LOG_FILE}
            echo
        else
            mysql -h ${MYSQL_HOST} -uroot -p${MYSQL_ROOT_PASSWORD} -e "SET GLOBAL log_bin_trust_function_creators = 1"
            if [[ $? != 0 ]]
            then
                echo "Failed to set log_bin_trust_function_creators!" | tee -a ${SETUP_LOG_FILE}
                exit 1
            fi

            echo "Restoring database from latest backup..." | tee -a ${SETUP_LOG_FILE}
            /restore.sh

            mysql -h ${MYSQL_HOST} -uroot -p${MYSQL_ROOT_PASSWORD} -e "SET GLOBAL log_bin_trust_function_creators = 0"
            if [[ $? != 0 ]]
            then
                echo "Failed to reset log_bin_trust_function_creators!" | tee -a ${SETUP_LOG_FILE}
                exit 1
            fi
        fi
    else
        DEMO_DB_LS=`ls ${ASPACE_ROOT_PATH}/data/archivesspace_demo_db/ | wc -l`
        if [[ ${DEMO_DB_LS} > 0 ]]
        then
            echo "Table already exists in database! Database restore skipped!" | tee -a ${SETUP_LOG_FILE}
            echo
        else
            echo "Restoring database from latest backup..." | tee -a ${SETUP_LOG_FILE}
            /restore.sh
        fi
    fi

    # ArchivesSapce migration database setup
    if [[ "${ASPACE_SKIP_SETUP_DATABASE}" == "Y" ]]
    then
        echo "Setup Database skipped!" | tee -a ${SETUP_LOG_FILE}
    else
        echo "Setup Database..." | tee -a ${SETUP_LOG_FILE}
        ${ASPACE_ROOT_PATH}/scripts/setup-database.sh
    fi
fi

# Clean up .my.cnf
if [[ ${USE_MYSQL} == "Y" ]]
then
    if [ -f ${MYSQL_CNF_FILE} ]
    then
        rm -f ${MYSQL_CNF_FILE}
    fi
fi

END_TIME=`date "+%Y-%m-%d %H:%M:%S"`
echo "ArchivesSpace setup completed at ${END_TIME} !" | tee -a ${SETUP_LOG_FILE}
echo | tee -a ${SETUP_LOG_FILE}

# Minio upload setup.log
if [ -f ${SETUP_LOG_FILE} ]
then
    mc -q cp ${SETUP_LOG_FILE} ${MINIO_ALIAS}/${MINIO_BUCKET_INFO}
    UPLOAD_SUCCESS=`mc ls ${MINIO_ALIAS} | grep ${SETUP_LOG_FILE} | wc -l`
    if [ ${UPLOAD_SUCCESS} -gt 0 ]
    then
        rm -f ${SETUP_LOG_FILE}
    fi
fi

# Start sendmail
sudo /etc/init.d/sendmail start

# Start ArchivesSpace
if [[ "${ASPACE_SKIP_START_SERVER}" == "Y" ]]
then
    echo "Start ArchivesSpace server skipped!"
    echo
else
    echo "Starting ArchivesSpace server..."
    echo
    /home/archivesspace/archivesspace/archivesspace.sh start
fi

while ! tail -f /home/archivesspace/archivesspace/logs/archivesspace.out ; do sleep 5 ; done

