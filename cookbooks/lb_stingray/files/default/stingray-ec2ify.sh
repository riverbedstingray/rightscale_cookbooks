#!/bin/bash
# Copyright Riverbed Technology Inc.  All rights reserved.

# stingray-ec2ify.sh:

function usage {

    echo ""
    echo "Usage:"
    echo "stingray-ech2ify.sh <ec2 availability zone> <ec2 instance id>"
    echo ""
    echo "Appends the correctly formatted ec2 details to the global configuration file."
    exit 1

}

if [ $# -ne 2 ]
then
    usage
fi

if [[ -h /opt/riverbed/zxtm/global.cfg ]]
then

    echo "ec2!availability_zone ${1}" >> /opt/riverbed/zxtm/global.cfg
    echo "ec2!instanceid ${2}" >> /opt/riverbed/zxtm/global.cfg
    echo "externalip EC2" >> /opt/riverbed/zxtm/global.cfg

fi
