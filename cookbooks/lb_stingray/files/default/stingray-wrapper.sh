#!/usr/bin/env bash
#
# Cookbook Name:: lb_stingray
#
# Copyright Riverbed, Inc.  All rights reserved.
# Written for the RightScale 12H1 branch.

set -x
#shopt -s nullglob

ZEUSHOME=/opt/riverbed
CONF_DIR=/etc/stingray/lb_stingray.d
PATH=${PATH}:${ZEUSHOME}/zxtm/bin
ZCLI=${ZEUSHOME}/zxtm/bin/zcli
SAVEIFS=$IFS
IFS=$(echo -en "\n\b")

function catArray {

for item in "${@}"
do
    printf "%s\n" "${item}"
done

}

function arrayToString {

    j=0
    declare -a array=("${@}")
    #echo "Array to string: ${array[@]}"
    for item in "${array[@]}"
    do
        printf "\"%s\"" "$item"
        if [ "$j" -lt "${#array[@]}" ]; then
            printf ","
        fi
        let "j += 1"
    done

}

function getChefNodeListAsLines {
	if [[ $(ls -1 "${CONF_DIR}"/services/"${1}"/servers | wc -l) -gt 0 ]]
	then
	    j=0
		local chefNodeArray=( $( cat "${CONF_DIR}"/services/"${1}"/servers/* | sort ) ) 
	    for i in "${chefNodeArray[@]}"
	    do
		printf "%s" "$i"
		if [ "$j" -lt "${#chefNodeArray[@]}" ]; then
		    printf "\n"
		fi
		let "j += 1"
	    done
	fi
}

function getChefNodeListAsJson {
# FIXME: Do this in chef/ruby rather than here.
    if [[ $(ls -1 "${CONF_DIR}"/services/"${1}"/servers | wc -l) -gt 0 ]]
    then
        j=0
        chefNodeArray=( $( cat "${CONF_DIR}"/services/"${1}"/servers/* | sort ) ) 

        for i in "${chefNodeArray[@]}"
        do
            printf "\"%s\"" "$i"
            if [ "$j" -lt "${#chefNodeArray[@]}" ]; then
                printf ","
            fi
            let "j += 1"
        done
    fi
}

stingray_config=( $(ls -1 /opt/riverbed/zxtm/conf/vservers | sort) )
chef_config=( $(ls -1 ${CONF_DIR}/services | sort) )

# Services to be created.
ADDED_SERVICE_NAMES=( $(comm -1 -3 <( catArray ${stingray_config[@]} ) <( catArray ${chef_config[@]} ) ) )
CURRENT_SERVICE_NAMES=( $(comm -1 -2 <( catArray ${stingray_config[@]} ) <( catArray ${chef_config[@]} ) ) )
DELETED_SERVICE_NAMES=( $(comm -2 -3 <( catArray ${stingray_config[@]} ) <( catArray ${chef_config[@]} ) ) )

# Delete undesired services.
for deleted_service_name in "${DELETED_SERVICE_NAMES[@]}"
do
    echo "${deleted_service_name}"

    # Delete virtual server
	${ZCLI} <<- EOF
	VirtualServer.deleteVirtualServer ["${deleted_service_name}"]
	EOF

	${ZCLI} <<- EOF
	Pool.deletePool ["${deleted_service_name}"]
	EOF

	${ZCLI} <<- EOF
	Catalog.Monitor.deleteMonitors ["${deleted_service_name}"]
	EOF

	${ZCLI} <<- EOF
	Catalog.Persistence.deletePersistence ["${deleted_service_name}"]
	EOF

done

# Create desired services.
for added_service_name in "${ADDED_SERVICE_NAMES[@]}";do
	sticky=false
	echo "Creating new service for $added_service_name."

	# Create health monitor
	${ZCLI} <<- EOF
		Catalog.Monitor.addMonitors ["${added_service_name}"]
		Catalog.Monitor.setType ["${added_service_name}"], ["http"]
		Catalog.Monitor.setNote ["${added_service_name}"], ["Created by RightScale - do not modify."]
	EOF

	
	if [[ -f "${CONF_DIR}/services/${added_service_name}/health_check_uri" ]];then
		uri=$( sed -e 's/http:\/\///' "${CONF_DIR}/services/${added_service_name}/health_check_uri" )
		hostheader="${uri%%/*}"
		path="/${uri#*/}"
		${ZCLI} <<- EOF
			Catalog.Monitor.setPath ["${added_service_name}"],["${path}"]
			Catalog.Monitor.setHostHeader ["${added_service_name}"], ["${hostheader}"]
		EOF
	fi

	# Test to see if service should be sticky.
	if [[ $(grep "session_sticky true" "${CONF_DIR}/services/${added_service_name}/config") -eq 0 ]];then
		# Set variable to true.
		sticky=true
	fi

	if ( ${sticky} ); then
	# Create persistence class
		${ZCLI} <<- EOF
			Catalog.Persistence.addPersistence ["${added_service_name}"]
			Catalog.Persistence.setNote ["${added_service_name}"], ["Created by RightScale - do not modify."]
		EOF
	fi

	# Compile a list of nodes
	chefnodes=$(getChefNodeListAsJson "${added_service_name}")

	# Create a pool
	# FIXME: Do only if there are actually servers in this pool.
	${ZCLI} <<- EOF
		Pool.addPool ["${added_service_name}"], [${chefnodes}]
		Pool.setMonitors ["${added_service_name}"], [["${added_service_name}"]]
		Pool.setNote ["${added_service_name}"], ["Created by RightScale - do not modify."]
	EOF

	if ( ${sticky} );then
		echo "Assigning persistence class to pool."
		${ZCLI} <<- EOF
			Pool.setPersistence ["${added_service_name}"], ["${added_service_name}"]
		EOF
	fi

	# Create a virtual server.
	${ZCLI} <<- EOF
		VirtualServer.addVirtualServer ["${added_service_name}"], { "default_pool": "${added_service_name}", "port": 80, "protocol": "http" }
		VirtualServer.setEnabled ["${added_service_name}"], [ "true" ]
		VirtualServer.setNote ["${added_service_name}"], ["Created by RightScale - do not modify."]
	EOF
done

for current_service_name in "${CURRENT_SERVICE_NAMES[@]}"
do
	chefnodes=( $(getChefNodeListAsJson "${current_service_name}") )
	poolname=$( sed -e 's/[]["]//g' <( ${ZCLI} <<- EOF
		VirtualServer.getDefaultPool ["${current_service_name}"]
	EOF
	) )

	if [[ "${#chefnodes[@]}" == 0  ]];then

		if [[ "${poolname}" != "discard" ]];then
		# The virtual server should be configured to discard traffic.
		# The pool should be deleted.
			${ZCLI} <<- EOF
				VirtualServer.setDefaultPool ["${current_service_name}"], ["discard"]
				Pool.deletePool ["${current_service_name}"]
			EOF
		fi
	else

		# Check to see if the virtual server is currently discarding traffic.
		if [[ "${poolname}" == "discard"  ]];then

			# Create a pool.
			${ZCLI} <<- EOF
				Pool.addPool ["${current_service_name}"], [${chefnodes}]
				Pool.setMonitors ["${current_service_name}"], [["${current_service_name}"]]
				Pool.setNote ["${current_service_name}"], ["Created by RightScale - do not modify."]
				EOF

			# Check to see if session_sticky was true.
			# FIXME: Replace session stickiness test with a function.
			if [[ $( grep "session_sticky true"  "${CONF_DIR}/service/${current_service_name}/config" ) -eq 0  ]];then
				# Create persistence class and associate it with the pool.
				${ZCLI} <<- EOF
					Catalog.Persistence.addPersistence ["${current_service_name}"]
					Catalog.Persistence.setNote ["${current_service_name}"], ["Created by RightScale - do not modify."]
					Pool.setPersistence ["${current_service_name}"], ["${current_service_name}"]
				EOF
			fi
			
			# Change the default pool for the virtual server to the pool (which should now have nodes in it).
			${ZCLI} <<- EOF
				VirtualServer.setDefaultPool ["${current_service_name}"], [ "${current_service_name}" ]
			EOF
		else

			chefnodesaslines=( $(getChefNodeListAsLines "${current_service_name}") )
			# FIXME: This is ugly, and doesn't quite work when you're removing more than 1 node!
			zclinodes=( $( sort <( sed -e 's/[]["]//g;s/,/\n/g' <( ${ZCLI} <<- EOF
					Pool.getNodes ["${current_service_name}"]
				EOF
			))))

			if [[ ${chefnodesaslines[@]} != ${zclinodes[@]} ]];then

				# Build a list of nodes to add.
				nodes_to_add=$(arrayToString $(comm -2 -3 <( catArray ${chefnodesaslines[@]} ) <( catArray ${zclinodes[@]} ) ) )

				# Build a list of nodes to remove.
				nodes_to_remove=$(arrayToString $(comm -1 -3 <( catArray ${chefnodesaslines[@]} ) <( catArray ${zclinodes[@]} ) ) )

				# Add or remove nodes.
				# FIXME: Need to add logical tests, since there may be no nodes to either add or remove.
				${ZCLI} <<- EOF
					Pool.addNodes [ "${current_service_name}" ], [ ${nodes_to_add} ]
					Pool.removeNodes [ "${current_service_name}" ], [ ${nodes_to_remove} ]
				EOF
			fi
		fi
	fi

done

exit 0
