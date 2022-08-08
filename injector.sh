#!/usr/bin/env bash

#source /etc/injector/injector.conf
source ./injector.conf

#TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
TOKEN=$(oc whoami -t)

### Fix GIT unknow user error by exporting variables, set ssh-agent, load the key
export GIT_COMMITTER_EMAIL='user_email'
export GIT_COMMITTER_NAME='root'
export GIT_SSL_NO_VERIFY=true
if [[ "${GIT_PROTOCOL}" == "ssh" ]]; then
	export GIT_SSH_COMMAND="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
    eval $(ssh-agent -s) 
	ssh-add /.ssh/id_rsa_git
fi

WORK_DIR=$(mktemp -d)
PROJECTS_ENDPOINT='/apis/project.openshift.io/v1/projects'
PROJECTS_JQ_LIST='jq -S -r .items[].metadata.name'
GRAFANA_FOLDER_ENDPOINT='/api/folders'
GRAFANA_FOLDER_JQ_LIST='jq -S -r .[].title'
GRAFANA_USERS_ENDPOINT='/api/users'
GRAFANA_DASHBOARD_ENDPOINT='/api/dashboards/db'
INTERNALS_DASHBOARDS_FOLDER='Openshift-Internals'
INTERNALS_FOLDER_UID='666666'
ROLEBINDIGS_ENDPOINT='/apis/authorization.openshift.io/v1/rolebindings'
ROLEBINDINGS_NAMESPACE_ENDPOINT="/apis/rbac.authorization.k8s.io/v1/namespaces"
ROLEBINDINGS_JQ_LIST='jq -r .items[].metadata.name'
ROLES=(grafana-access-admin grafana-access-edit grafana-access-view)
GIT_CLONED=false



### Functions
###
### Create number from string - for folderId generation
### Return unique number based on Project name
num-from-string() {
    local out i a
    for ((i=0;i<${#1};++i)); do
        printf -v a "%d\n" "'${1:i:1}"
        out+=$((a%10))
    done
    echo "$out"
}

function contains() {
    local n=$#
    local value=${!n}
    for ((i=1;i < $#;i++)) {
        if [ "${!i}" == "${value}" ]; then
            echo "y"
            return 0
        fi
    }
    echo "n"
    return 1
}

### Read from Openshift API
### Params:
###	${1} - api endpoint url with params included 
### Return curl response 

read-openshift-api() {
echo -e "curl -k -X GET -H \"Authorization: Bearer ${TOKEN}\"  -H 'Content-Type: application/json' ${1}" >&2

	curl -k -s \
		 -X GET \
		 -H "Authorization: Bearer ${TOKEN}" \
		 -H 'Content-Type: application/json' \
		${1}
}

### Write to Grafana API - from file
### Params:
### 	${1} - api endpoint url with params included
###		${2{ - path to json file with payload 
### Return curl response 

write-grafana-api() {
	curl -k -s  \
		 -X POST \
		 -u "${GRAFANA_API_USER}:${GRAFANA_API_PASS}" \
		 -H 'Accept: application/json' \
		 -H 'Content-Type: application/json' \
		 -d "@${2}" \
		${1}
}

### Write to Grafana API - from variable
### Params:
### 	${1} - api endpoint url with params included
###		${2{ - path to json file with payload 
### Return curl response 

write-grafana-var-api() {
    curl -k -s  \
         -X POST \
         -u "${GRAFANA_API_USER}:${GRAFANA_API_PASS}" \
         -H 'Accept: application/json' \
         -H 'Content-Type: application/json' \
         -d "${2}" \
        ${1}
}

### Read from Grafana API
### Params:
###     ${1} - api endpoint url with params included 
### Return curl response 
 
read-grafana-api() {
	curl -k -s \
		 -X GET \
		 -u "${GRAFANA_API_USER}:${GRAFANA_API_PASS}" \
		 -H 'Accept: application/json' \
		 -H 'Content-Type: application/json' \
		${1}
}

delete-grafana-api() {
	curl -k -s \
         -X DELETE \
         -u "${GRAFANA_API_USER}:${GRAFANA_API_PASS}" \
         -H 'Accept: application/json' \
         -H 'Content-Type: application/json' \
        ${1}
}

refresh-dashboards() {
    if [ $GIT_CLONED = false ]; then
        [[ "${GIT_PROTOCOL}" == "https" ]] && git clone ${GIT_PROTOCOL}://${GIT_DASHBOARD_REPO} ${WORK_DIR}/dashboards
        [[ "${GIT_PROTOCOL}" == "ssh" ]]   && git clone ${GIT_PROTOCOL}://${GIT_DASHBOARD_REPO} ${WORK_DIR}/dashboards
		GIT_CLONED=true
    else
        cd $WORK_DIR/dashboards
        [[ "${GIT_PROTOCOL}" == "https" ]] && git pull ${GIT_PROTOCOL}://${GIT_DASHBOARD_REPO}
        [[ "${GIT_PROTOCOL}" == "ssh" ]]   && git pull ${GIT_PROTOCOL}://${GIT_DASHBOARD_REPO}
    fi
}

### Pre-read some items from Grafana and Openshift 
### so we can query them later without calling API again 
preread-items() {
	### Pre-read Project with label ${PROJECTS_LABEL_SELECTOR} from Openshift
	NAMESPACES_LIST_JSON=$(read-openshift-api ${API_URL}:${API_PORT}${PROJECTS_ENDPOINT}?labelSelector=${PROJECTS_LABEL_SELECTOR})
	NAMESPACES_LIST=$(echo "${NAMESPACES_LIST_JSON}" | ${PROJECTS_JQ_LIST})
	NAMESPACE_LIST_ARRAY=($NAMESPACES_LIST)
	echo "Current # of namespaces with correct label: ${#NAMESPACE_LIST_ARRAY[@]}"

	### Pre-read all users from Grafana
	USER_ID_LIST=$(read-grafana-api ${GRAFANA_API_URL}:${GRAFANA_API_PORT}${GRAFANA_USERS_ENDPOINT})
	USER_ID_LIST_ARRAY=($USER_ID_LIST)
	echo "Current # of Grafana users: ${#USER_ID_LIST_ARRAY[@]}"
  
	### Pre-read all folders from Grafana
	GRAFANA_FOLDER_JSON=$(read-grafana-api ${GRAFANA_API_URL}:${GRAFANA_API_PORT}${GRAFANA_FOLDER_ENDPOINT})
	GRAFANA_FOLDER_LIST=$(echo "${GRAFANA_FOLDER_JSON}" | ${GRAFANA_FOLDER_JQ_LIST})
	GRAFANA_FOLDER_ARRAY=($GRAFANA_FOLDER_LIST)
	echo "Current # of Grafana folders: ${#GRAFANA_FOLDER_ARRAY[@]}"
}

### Set permission on folder $INTERNALS_DASHBOARDS_FOLDER
### All users with role $INTERNALS_ROLE in project $THANOS_HOME will get access to folder $INTERNALS_DASHBOARDS_FOLDER
set-perm-on-internal-folder() {
	### Read RoleBindings from Project $THANOS_HOME
    local INTERNALS_ROLE_ID=4
	local INTERNALS_UID_LIST=('')
	local INTERNALS_FIRST_RECORD='1'
	local INTERNALS_ROLE=(grafana-access-internals)

	# Open payload structure
	echo "{ \"items\": [" > ${WORK_DIR}/${INTERNALS_DASHBOARDS_FOLDER}-folder-permission.json
	### Read user list from all RoleBindings refering role defined in $INTERNALS_ROLE
    for ROLE in ${INTERNALS_ROLE[@]}; do
	    local USER_LIST_JSON=$(read-openshift-api ${API_URL}:${API_PORT}${ROLEBINDINGS_NAMESPACE_ENDPOINT}/${THANOS_HOME}/rolebindings)
        echo "${API_URL}:${API_PORT}${ROLEBINDINGS_NAMESPACE_ENDPOINT}/${THANOS_HOME}/rolebindings"
    	local USER_LIST=$(echo "${USER_LIST_JSON}" | jq -r ".items[] | select(.roleRef.name==\"${ROLE}\") | .subjects[].name" | sort | uniq)
        echo "User in ${INTERNALS_ROLE}: {$USER_LIST}"

    	### Create payload for folder permission
	    for USER in $USER_LIST; do
			# Find userId based on login name
			echo -n -e "Namespace: ${THANOS_HOME}, Role: ${ROLE}, User: ${USER},"

            ESCAPED_USER="$(echo $USER|sed 's/\\/\\\\/')"
			USER_ID=$(echo "${USER_ID_LIST}" | jq -r ".[] | select( .email==\"${ESCAPED_USER}\" or .login==\"${ESCAPED_USER}\") | .id")
			[[ "${USER_ID}" -eq "null" ]] && echo " Status: User not found, Apply: false" && continue # Skip if empty response
			echo -n " Status: Found with id ${USER_ID},"

			### Add user record to payload
			### Dont add if userId is already in payload
			if [[ $(contains "${INTERNALS_UID_LIST[@]}" "${USER_ID}") == "n" ]]; then

				### Dont add "," before first record
                [ ${INTERNALS_FIRST_RECORD} == '0' ] && echo ',' >> ${WORK_DIR}/${INTERNALS_DASHBOARDS_FOLDER}-folder-permission.json
 
				### Add to payload
				echo  "{\"userId\": ${USER_ID},\"permission\": ${INTERNALS_ROLE_ID}}" >> ${WORK_DIR}/${INTERNALS_DASHBOARDS_FOLDER}-folder-permission.json
				echo " Apply: true"

				### Add ID to the list of already added ID
				INTERNALS_UID_LIST=(${NS_UID_LIST[@]} $USER_ID)

				### Unset first record mark
				INTERNALS_FIRST_RECORD='0'
			else
				echo " Already in payload - skipping, Apply: false"
			fi
		done
	done
	### Finish payload structure
	echo "] }" >> ${WORK_DIR}/${INTERNALS_DASHBOARDS_FOLDER}-folder-permission.json

	### Apply folder permissions payload from file
	echo "Apply permission on folder: ${INTERNALS_DASHBOARDS_FOLDER}"
	cat "${WORK_DIR}/${INTERNALS_DASHBOARDS_FOLDER}-folder-permission.json" | jq -c .
	APPLY_STATUS=$(write-grafana-api ${GRAFANA_API_URL}:${GRAFANA_API_PORT}${GRAFANA_FOLDER_ENDPOINT}/${INTERNALS_FOLDER_UID}/permissions ${WORK_DIR}/${INTERNALS_DASHBOARDS_FOLDER}-folder-permission.json)
	echo "Response: $APPLY_STATUS"
}

# Prune folders in Grafana 
prune-folders() {
	for FOLDER in ${GRAFANA_FOLDER_ARRAY[@]}; do
		if [[ "${FOLDER}" != "${INTERNALS_DASHBOARDS_FOLDER}" ]]; then 
			if [[ $(contains "${NAMESPACE_LIST_ARRAY[@]}" "${FOLDER}") == "n" ]]; then
				local folder_uid=$(num-from-string ${FOLDER})
				echo "Deleting folder ${FOLDER}:${folder_uid}"
				APPLY_STATUS=$(delete-grafana-api ${GRAFANA_API_URL}:${GRAFANA_API_PORT}${GRAFANA_FOLDER_ENDPOINT}/${folder_uid})
				echo "Response: $APPLY_STATUS"
			else 
				echo "Folder $FOLDER has matching project in Openshift"
			fi
		else 
			echo "Folder ${INTERNALS_DASHBOARDS_FOLDER} is internal folder - skipping"
		fi 
	done
}

###############################################################################

### Workaround for GIT with debilni znaky in username
### All special characters like "%-.<>\^_`{|}~ in pass or user name must be
### url encoded !!!
echo "${GIT_PROTOCOL}://${GIT_USER}:${GIT_PASS}@${GIT_DASHBOARD_REPO}" > /tmp/credentials

### Wait for containers ...
echo -e "[$(date +"%T")]:Waiting ${START_DELAY}s for containers to start ... "
sleep ${START_DELAY}

while true; do
 	
	echo -e "[$(date +"%T")]: Starting ..."
	preread-items

	for NAMESPACE in ${NAMESPACES_LIST}; do

		### Set array of Grafana UID per folder - will use later for detecting duplicity 	
		NS_UID_LIST=("") 

	  	### Set Folder uid from Project name
  		FOLDER_UID=$(num-from-string ${NAMESPACE})
  
	  	### Prepare json payload for Folder definition
  		echo " {\"title\": \"${NAMESPACE}\", \"uid\": \"${FOLDER_UID}\"}" > ${WORK_DIR}/folder.json
  
	  	### Create Folder for the Project, set title and uid
  		echo "Create folder: ${NAMESPACE}"
	  	cat "${WORK_DIR}/folder.json" | jq -c .
	  	APPLY_STATUS=$(write-grafana-api ${GRAFANA_API_URL}:${GRAFANA_API_PORT}${GRAFANA_FOLDER_ENDPOINT} ${WORK_DIR}/folder.json)
		echo  "Response: $APPLY_STATUS"
  
  		# Open payload structure
	  	echo "{ \"items\": [" > ${WORK_DIR}/${NAMESPACE}-folder-permission.json
  
  		### Read user list from all RoleBindings refering role defined in ROLES[]
		FIRST_RECORD='1'
  		for ROLE in ${ROLES[@]}; do
  			USER_LIST_JSON=$(read-openshift-api ${API_URL}:${API_PORT}${ROLEBINDINGS_NAMESPACE_ENDPOINT}/${NAMESPACE}/rolebindings)
	  		USER_LIST=$(echo "${USER_LIST_JSON}" | jq -r ".items[] | select(.roleRef.name==\"${ROLE}\") | .subjects[].name" | sort | uniq)
		
  			case ${ROLE} in
  				grafana-access-view) ROLE_ID=1;;
	  			grafana-access-edit) ROLE_ID=2;;
	  			grafana-access-admin) ROLE_ID=4;;
		  	esac
  	
  			### Create payload for folder permission
  	    	for USER in $USER_LIST; do
  
  				# Find userId based on login name
	  			echo -n -e "Namespace: ${NAMESPACE}, Role: ${ROLE}, User: ${USER},"
 
				# Workaround '\' in username - need add one more '\'
				# Example: "dmz\xxxx" need to be converted to "dmz\\xxxx"
				ESCAPED_USER="$(echo $USER|sed 's/\\/\\\\/')"

  				USER_ID=$(echo "${USER_ID_LIST}" | jq -r ".[] | select( .email==\"${ESCAPED_USER}\" or .login==\"${ESCAPED_USER}\") | .id")
  				[[ "${USER_ID}" -eq "null" ]] && echo " Status: User not found, Apply: false" && continue # Skip if empty response
  				echo -n " Status: found with id ${USER_ID},"
  			
				### Add user record to payload
				### Dont add if userId is already in payload
				if [[ $(contains "${NS_UID_LIST[@]}" "${USER_ID}") == "n" ]]; then 
			
					### Dont add "," before first record
	 				[ ${FIRST_RECORD} == '0' ] && echo ',' >> ${WORK_DIR}/${NAMESPACE}-folder-permission.json

					### Add to payload
  					echo  "{\"userId\": ${USER_ID},\"permission\": ${ROLE_ID}}" >> ${WORK_DIR}/${NAMESPACE}-folder-permission.json
					echo " Apply: true"
					### Add ID to the list of already added ID
					NS_UID_LIST=(${NS_UID_LIST[@]} $USER_ID)

					### Unset first record mark
					FIRST_RECORD='0'
				else 
					echo " Already in payload - skipping, Apply: false"
				fi
	  		done
		done
  
	  	### Finish payload structure
  		echo "] }" >> ${WORK_DIR}/${NAMESPACE}-folder-permission.json
  
	  	### Apply folder permissions payload from file
		echo "Apply permission on folder: ${NAMESPACE}"
	  	cat "${WORK_DIR}/${NAMESPACE}-folder-permission.json" | jq -c .
		APPLY_STATUS=$(write-grafana-api ${GRAFANA_API_URL}:${GRAFANA_API_PORT}${GRAFANA_FOLDER_ENDPOINT}/${FOLDER_UID}/permissions ${WORK_DIR}/${NAMESPACE}-folder-permission.json)
		echo "Response: $APPLY_STATUS"

	done
	echo -e  "[$(date +"%T")]: Folders and permissions finished."

	echo -e  "[$(date +"%T")]: Starting with dashboards injection."
	### Re-read folder list from Grafana
	preread-items

	### Clone or pull dashboards from Git
	refresh-dashboards

	### Load dashboards from Git only for existing folders in Grafana 
	for FOLDER in ${GRAFANA_FOLDER_ARRAY[@]}; do
		echo "SEARCHING dashboards for folder ${FOLDER} in ${WORK_DIR}/dashboards/${FOLDER}"
		if [[ -d "${WORK_DIR}/dashboards/${FOLDER}" ]]; then
			for FILE in $(ls ${WORK_DIR}/dashboards/${FOLDER}); do

				### Internal folder have static ID - workaround
				if  [[ "${FOLDER}" == "${INTERNALS_DASHBOARDS_FOLDER}" ]]; then
					FOLDER_UID="${INTERNALS_FOLDER_UID}"
				else
					FOLDER_UID=$(num-from-string ${FOLDER})
				fi 

				### Get folderId by folderUid
				FOLDER_ID=$(echo $GRAFANA_FOLDER_JSON | jq -r ".[] | select(.uid==\"${FOLDER_UID}\") | .id")

				### Set FolderID and overwrite atributes
				DASH_WITH_FOLDERID=$(cat ${WORK_DIR}/dashboards/${FOLDER}/${FILE} | jq ". | .folderId = ${FOLDER_ID} | .overwrite = true")
			
				### Send to Grafana API
				echo "Sending to Grafana ${FOLDER}:${FILE}"
				APPLY_STATUS=$(write-grafana-var-api ${GRAFANA_API_URL}:${GRAFANA_API_PORT}${GRAFANA_DASHBOARD_ENDPOINT} "${DASH_WITH_FOLDERID}")
				echo "Response: ${APPLY_STATUS}"
			done
		fi
	done
	echo -e  "[$(date +"%T")]: Finished with dashboards injection."
	
	### Set permission on internal folder
	echo -e  "[$(date +"%T")]: Starting with internal folder permissions."
	set-perm-on-internal-folder
	echo -e  "[$(date +"%T")]: Finished with internal folder permissions."


	### Prune folders in Grafana if PRUNE_FOLDERS is set to true
	### Delete folder only if there is no matching project in Openshift
	if [[ "${PRUNE_FOLDERS}" == "true" ]]; then  
		echo -e  "[$(date +"%T")]: Starting with folder prunning."
		prune-folders
		echo -e  "[$(date +"%T")]: Finished  with folder prunning."
	else
		echo "PRUNE_FOLDERS set to false ... skipping."		
	fi 

	### Print last message and wait for next round
	echo -e "[$(date +"%T")]: Waiting ${INTERVAL}s for next round."
	sleep ${INTERVAL}
done
