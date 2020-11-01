#!/bin/bash

if [ ${#RAI_CLIENT_ID} -ne 32 ]
then
   echo "Invalid RAI_CLIENT_ID = ${RAI_CLIENT_ID}. Must have 32 bytes long"
   exit 1
fi

CLIENT_RESOURCE="${DEPLOYMENT}_${RAI_CLIENT_ID}"

/run.sh

alias python=python36

PIO_COMMAND=/usr/local/pio/bin/pio

if [ -z ${SNS_TOPIC} ]
then
    SNS_TOPIC="arn:aws:sns:eu-west-1:478423532497:test-client-setup-notification-topic"
fi

if [ -z ${DEFAULT_REGION} ]
then
    DEFAULT_REGION="eu-west-1"
fi

if [ -z ${RAI_PROVISION_ACTION} ]
then
    RAI_PROVISION_ACTION="BUILD_ONLY"
fi

if [ -z ${IMPORT_FILE_PATH} ]
then
    IMPORT_FILE_PATH="/user/rai/data.json"
fi

echo "START Running action=${RAI_PROVISION_ACTION} for clientId=${RAI_CLIENT_ID} resource=${CLIENT_RESOURCE}"

SUCCESS_CODE="BUILD_COMPLETED"
ERROR_CODE="BUILD_FAILED"
ACCESS_KEY="NOT_AVAILABLE"
REDEPLOY_CLIENT="true"

rm -rf /ivy_home/*.lock

# used for the CREATE_AND_BUILD action only
pioAppContext=""

if [ "${RAI_PROVISION_ACTION}" = "CREATE_AND_BUILD" ]
then
    SUCCESS_CODE="CREATE_CLIENT_COMPLETED"
    ERROR_CODE="CREATE_CLIENT_FAILED"
    REDEPLOY_CLIENT="false"
#generate ACCESS_KEY and clientId
    ACCESS_KEY=$(echo "`date +%s`|${RAI_CLIENT_ID}" | sha256sum | base64 | head -c 48; echo)
    clientId=${RAI_CLIENT_ID}
#create new app
    ${PIO_COMMAND} app new --access-key ${ACCESS_KEY} ${CLIENT_RESOURCE}
    if [ $? -ne 0 ]
    then
        aws sns publish \
            --topic-arn ${SNS_TOPIC} \
            --subject ${ERROR_CODE} \
            --message "{\"clientId\":\"${RAI_CLIENT_ID}\",\"action\":\"${RAI_PROVISION_ACTION}\",errorCode:\"ERROR_AT_PIO_APP_NEW_COMMAND\"}"  \
            --region ${DEFAULT_REGION}
        echo "Error creating app ${CLIENT_RESOURCE}"
        exit 1
    fi

    pioAppId=$(pio app show ${CLIENT_RESOURCE} | grep "App ID" | cut -d: -f2)
    pioAppContext=",\"appName\":\"${CLIENT_RESOURCE}\",\"accessKey\":\"${ACCESS_KEY}\",\"appId\":\"${pioAppId}\"";
fi


if [ "${RAI_PROVISION_ACTION}" = "IMPORT_DEFAULT_DATA" ]
then
    echo "Import file ${IMPORT_FILE_PATH}"

    appId=$(pio app show ${CLIENT_RESOURCE} | grep "App ID" | cut -d: -f2)
    if [ -z ${appId} ]
    then
        echo "Client not found: ${CLIENT_RESOURCE}. Exiting ... "
        exit 1;
    fi
    ${PIO_COMMAND} import --appid ${appId} --input ${IMPORT_FILE_PATH}
    importStatus=$?
    subject="IMPORT_DEFAULT_DATA_COMPLETED"


    if [ ${importStatus} -ne 0 ]
    then
        subject="IMPORT_DEFAULT_DATA_FAILED"
    fi
    aws sns publish \
        --topic-arn ${SNS_TOPIC} \
        --subject "IMPORT_DEFAULT_DATA_COMPLETED" \
        --message "{\"clientId\":\"${RAI_CLIENT_ID}\",\"action\":\"${RAI_PROVISION_ACTION}\"}"  \
        --region ${DEFAULT_REGION}
    exit 0
fi

if [ "${RAI_PROVISION_ACTION}" = "CLEAN_CLIENT_DATA" ]
then
    ${PIO_COMMAND} app data-delete ${CLIENT_RESOURCE} --force
    aws sns publish \
        --topic-arn ${SNS_TOPIC} \
        --subject "CLIENT_DATA_DELETED" \
        --message "{\"clientId\":\"${RAI_CLIENT_ID}\",\"action\":\"${RAI_PROVISION_ACTION}\"}"  \
        --region ${DEFAULT_REGION}
    exit 0
fi

if [ "${RAI_PROVISION_ACTION}" = "DELETE_CLIENT" ]
then

    hdfs dfs -rm -r -f ${HDFS_CLIENT_ENGINES}/${CLIENT_RESOURCE}

    ${PIO_COMMAND} app delete ${CLIENT_RESOURCE} --force
    aws sns publish \
        --topic-arn ${SNS_TOPIC} \
        --subject "CLIENT_DELETED" \
        --message "{\"clientId\":\"${RAI_CLIENT_ID}\",\"action\":\"${RAI_PROVISION_ACTION}\"}"  \
        --region ${DEFAULT_REGION}
    exit 0
fi

cd /var/lib/rai/pio/engines/
mv universal-recommender ${RAI_CLIENT_ID}
cd ${RAI_CLIENT_ID}

# Do we have an engine.json defined?


hdfs dfs -ls ${HDFS_CLIENT_ENGINES}/${CLIENT_RESOURCE}/engine.json
exists_in_hdfs=$?

if [ ${exists_in_hdfs} -eq 0 ]
then
#Yes, use it
    echo "engine.json found at hdfs://${HDFS_CLIENT_ENGINES}/${CLIENT_RESOURCE}"
    hdfs dfs -get -f ${HDFS_CLIENT_ENGINES}/${CLIENT_RESOURCE}/engine.json /var/lib/rai/pio/engines/${RAI_CLIENT_ID}/engine.json
else
#No, this is a new setup.
    echo "New setup. Generating engine.json"
    sed -i "s~PLACEHOLDER~${CLIENT_RESOURCE}~g" /var/lib/rai/pio/engines/${RAI_CLIENT_ID}/engine.json
    sed -i "s/%DOMAIN%/${RAI_DOMAIN}/g" /var/lib/rai/pio/engines/${RAI_CLIENT_ID}/engine.json
fi

status=FAILED
${PIO_COMMAND} build --sbt-extra "-Dsbt.ivy.home=/ivy_home"  --no-asm
if [ $? -eq 0 ]
then
    status=SUCCESS

    hdfs dfs -mkdir -p ${HDFS_CLIENT_ENGINES}/${CLIENT_RESOURCE}
    echo "Created hdfs dir $?"
    hdfs dfs -put -f /var/lib/rai/pio/engines/${RAI_CLIENT_ID}/engine.json ${HDFS_CLIENT_ENGINES}/${CLIENT_RESOURCE}/engine.json
    echo "Uploaded engine.json $?"
    hdfs dfs -put -f /var/lib/rai/pio/engines/${RAI_CLIENT_ID}/target/scala-2.11/${UR_CLIENT_JAR} ${HDFS_CLIENT_ENGINES}/${CLIENT_RESOURCE}/${UR_CLIENT_JAR}
    echo "Uploaded jar $?"

    aws sns publish \
        --topic-arn ${SNS_TOPIC} \
        --subject ${SUCCESS_CODE} \
        --message "{\"clientId\":\"${RAI_CLIENT_ID}\",\"action\":\"${RAI_PROVISION_ACTION}\"${pioAppContext},\"redeploy\":${REDEPLOY_CLIENT}, \"sourceVersion\":\"${RAI_UR_VERSION}\"}"  \
        --region ${DEFAULT_REGION}
else
    aws sns publish \
        --topic-arn ${SNS_TOPIC} \
        --subject ${ERROR_CODE} \
        --message "{\"clientId\":\"${RAI_CLIENT_ID}\",\"action\":\"${RAI_PROVISION_ACTION}\",\"errorCode\":\"${ERROR_AT_PIO_BUILD}\",\"accessKey\":\"${ACCESS_KEY}\",\"redeploy\":${REDEPLOY_CLIENT}}"  \
        --region ${DEFAULT_REGION}
fi

echo "END Running action=${RAI_PROVISION_ACTION} for clientId=${RAI_CLIENT_ID} status=$status"


exit 0