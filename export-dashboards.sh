#!/bin/bash

source ./injector.conf

set -o errexit
dash_start='{
  "dashboard": {
'
dash_end=', "folderId": 0, "overwrite": true }'

print_help() {
	echo -e "\nUsage:"
	echo -e "export-dashboards -e <path-exporto-to>\n"
}

while getopts 'e:h' flag; do
	case "${flag}" in
		e)  CLUSTER="${OPTARG}";;
		h) print_help; exit 1 ;;
		*) echo "Error - unexpected parameter ${OPTARG}";  exit 1;;
	esac
done

URL="${GRAFANA_API_URL}"
LOGIN="${GRAFANA_API_USER}:${GRAFANA_API_PASS}"
DASHBOARDS_DIRECTORY="./grafana/${CLUSTER}/dashboards"

mkdir -p ${DASHBOARDS_DIRECTORY}




main() {
	 # Print help if no params specified 	
	 if [ ${#} -eq 0 ]; then 
   		print_help
		exit 1
	 fi

	# Exit if jq is not installed
	if ! [ $(jq --version ) ]; then 
		echo -e "Jq is not installed\n"
		exit 1
	fi 
   
	local dashboards=$(list_dashboards)
	local dashboard_json
	echo "Dashboars UIDS: $dashboards"

	echo -e '\n-------------------------------------------------------------'
	echo -e "Cluster URL: \t${URL}"
	echo -e "Directory: \t${DASHBOARDS_DIRECTORY}" 
	echo -e '-------------------------------------------------------------'

	# Wait for user input 
	while true; do
		read -p "Do you wish to continue ? " yn
		case $yn in 
        		[Yy]* ) break;;
			[Nn]* ) echo "Exiting ..."; exit;;
			* ) echo "Please answer yes or no.";;
		esac    
	done    

	# Iterate through dashboards 
	for dashboard in $dashboards; do
		dashboard_json=$(get_dashboard "$dashboard")
		if [[ -z "$dashboard_json" ]]; then
			echo "ERROR: Couldn't retrieve dashboard $dashboard."
			exit 1
		fi
		dashboard_filename=$(echo ${dashboard_json} | jq .title |  sed -e 's/ /_/g' |  sed -e 's/\"//g' | sed -e 's/\///g'| sed -e 's/(//g'| sed -e 's/)//g')	 	

		echo -e "Exporting dashboard to ${DASHBOARDS_DIRECTORY}/api_${dashboard_filename}.json"

    	# Create GUI version 
		echo "$dashboard_json"  > "${DASHBOARDS_DIRECTORY}/gui_${dashboard_filename}.json"

	    # Create API version
		echo "$dashboard_json" | sed -n '/editable/,$p' > "${DASHBOARDS_DIRECTORY}/tmpapi_${dashboard_filename}.json"
		echo ${dash_start} > ${DASHBOARDS_DIRECTORY}/api_${dashboard_filename}.json
		cat "${DASHBOARDS_DIRECTORY}/tmpapi_${dashboard_filename}.json" >> ${DASHBOARDS_DIRECTORY}/api_${dashboard_filename}.json
		echo ${dash_end} >> ${DASHBOARDS_DIRECTORY}/api_${dashboard_filename}.json
		rm "${DASHBOARDS_DIRECTORY}/tmpapi_${dashboard_filename}.json"

  done
}

# As we're getting it right from the database, it'll contain an `id`.
# Given that the ID is potentially different when we import it
# later, to make this dashboard importable we make the `id`
# field NULL.
get_dashboard() {
	local dashboard=$1

	if [[ -z "$dashboard" ]]; then
		echo "ERROR: A dashboard must be specified."
		exit 1
	fi
	
	# Get dashboard $1 and change .id and .editable
	curl -k -s \
		--user "$LOGIN" \
		$URL/api/dashboards/uid/$dashboard |
		jq '.dashboard | .id = null | .editable = "false"'
}


# lists all the dashboards available.
#
# `/api/search` lists all the dashboards and folders
# that exist in our organization.
# Here we filter the response (that also contain folders)
# to gather only the name of the dashboards.
list_dashboards() {
	curl -k -s \
		--user "$LOGIN" \
		$URL/api/search |
		jq -r '.[] | select(.type == "dash-db") | .uid' |
		cut -d '/' -f2
}

main "$@"
