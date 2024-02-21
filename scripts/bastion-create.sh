#!/bin/bash

# Script to add a bastion and related resources to an existing VPC environment
# It adds:
# - a subnet
# - a bastion and a maintenance security group with rules
# - a VSI for the bastion
# - a floating IP
#
# It needs the following environment variables set
# - VPCID
# - BASENAME
# - BASTION_SSHKEY
# - BASTION_IMAGE (optional, default Ubuntu)
# - BASTION_NAME (optional, default "bastion")
# - BASTION_ZONE
#
# It exports the following variables
# - BASTION_IP_ADDRESS
# - SGBASTION
# - SGMAINT
# (C) 2019 IBM
#
# Written by Henrik Loeser, hloeser@de.ibm.com

# Exit on errors
set -e
set -o pipefail

# include common functions
. $(dirname "$0")/../scripts/common.sh

# Some checks before getting started...
#
# check that we know the VPC id
if [ -z "$VPCID" ]; then
    echo "Bastion: VPCID required"
    exit
fi

# check that IDs for SSH keys have been provided
if [ -z "$BASTION_SSHKEY" ]; then
    echo "Bastion: SSH key required (BASTION_SSHKEY)"
    exit
fi

# we need to have the zone to provision to
if [ -z "$BASTION_ZONE" ]; then
    echo "Bastion: zone required (BASTION_ZONE)"
    exit
fi

# check for the basename
if [ -z "$BASENAME" ]; then
    echo "Bastion: basename required"
    exit
fi

# check for the optional image ID
if [ -z "$BASTION_IMAGE" ]; then
    echo "Bastion: no image specified, using Ubuntu"
    ImageName=$(ubuntu2204)
    BASTION_IMAGE=$(ibmcloud is images --output json | jq -r '.[] | select (.name=="'${ImageName}'") | .id')
fi

# check for the optional bastion name
if [ -z "$BASTION_NAME" ]; then
    echo "Bastion: no bastion name specified, using 'bastion'"
    BASTION_NAME="bastion"
fi


if ! SUB_BASTION=$(ibmcloud is subnet-create ${BASENAME}-${BASTION_NAME}-subnet $VPCID $BASTION_ZONE --ipv4-address-count 256 --output json)
then
    code=$?
    echo ">>> ibmcloud is subnet-create ${BASENAME}-${BASTION_NAME}-subnet $VPCID $BASTION_ZONE --ipv4-address-count 256 --output json"
    echo "${SUB_BASTION}"
    exit $code
fi
SUB_BASTION_ID=$(echo "$SUB_BASTION" | jq -r '.id')

vpcResourceAvailable subnets ${BASENAME}-${BASTION_NAME}-subnet

# Bastion SG
echo "Bastion: Creating security groups"
if ! SGBASTION_JSON=$(ibmcloud is security-group-create ${BASENAME}-${BASTION_NAME}-sg $VPCID --output json)
then
    code=$?
    echo ">>> ibmcloud is security-group-create ${BASENAME}-${BASTION_NAME}-sg $VPCID --output json"
    echo "${SGBASTION_JSON}"
    exit $code
fi
export SGBASTION=$(echo "${SGBASTION_JSON}" | jq -r '.id')

# Maintenance / admin SG
if ! SGMAINT_JSON=$(ibmcloud is security-group-create ${BASENAME}-maintenance-sg $VPCID --output json)
then
    code=$?
    echo ">>> ibmcloud is security-group-create ${BASENAME}-maintenance-sg $VPCID --output json"
    echo "${SGMAINT_JSON}"
    exit $code
fi
export SGMAINT=$(echo "${SGMAINT_JSON}" | jq -r '.id')

sleep 20

#ibmcloud is security-group-rule-add GROUP_ID DIRECTION PROTOCOL
echo "Bastion: Creating rules"

#echo "bastion"
# inbound
ibmcloud is security-group-rule-add $SGBASTION inbound tcp --remote "0.0.0.0/0" --port-min 22 --port-max 22 > /dev/null
ibmcloud is security-group-rule-add $SGBASTION inbound icmp --remote "0.0.0.0/0" --icmp-type 8 > /dev/null
# outbound
ibmcloud is security-group-rule-add $SGBASTION outbound tcp --remote $SGMAINT --port-min 22 --port-max 22 > /dev/null

#echo "maintenance"
# inbound
ibmcloud is security-group-rule-add $SGMAINT inbound tcp --remote $SGBASTION --port-min 22 --port-max 22 > /dev/null
# outbound
ibmcloud is security-group-rule-add $SGMAINT outbound tcp --remote "0.0.0.0/0" --port-min 443 --port-max 443 > /dev/null
ibmcloud is security-group-rule-add $SGMAINT outbound tcp --remote "0.0.0.0/0" --port-min 80 --port-max 80 > /dev/null
ibmcloud is security-group-rule-add $SGMAINT outbound tcp --remote "0.0.0.0/0" --port-min 53 --port-max 53 > /dev/null
ibmcloud is security-group-rule-add $SGMAINT outbound udp --remote "0.0.0.0/0" --port-min 53 --port-max 53 > /dev/null

# Bastion server
echo "Bastion: Creating bastion VSI"
if ! BASTION_VSI=$(ibmcloud is instance-create ${BASENAME}-${BASTION_NAME}-vsi $VPCID $BASTION_ZONE $(instance_profile) $SUB_BASTION_ID --image-id $BASTION_IMAGE --key-ids $BASTION_SSHKEY --security-group-ids $SGBASTION --output json)
then
    code=$?
    echo ">>> ibmcloud is instance-create ${BASENAME}-${BASTION_NAME}-vsi $VPCID $BASTION_ZONE $(instance_profile) $SUB_BASTION_ID --image-id $BASTION_IMAGE --key-ids $BASTION_SSHKEY --security-group-ids $SGBASTION --output json"
    echo "${BASTION_VSI}"
    exit $code
fi

BASTION_VSI_NIC_ID=$(echo "$BASTION_VSI" | jq -r '.primary_network_interface.id')

vpcResourceRunning instances ${BASENAME}-${BASTION_NAME}-vsi

# Floating IP for bastion
BASTION_IP_JSON=$(ibmcloud is floating-ip-reserve ${BASENAME}-${BASTION_NAME}-ip --nic-id $BASTION_VSI_NIC_ID --output json)
BASTION_IP_ID=$(echo "${BASTION_IP_JSON}" | jq -r '.id')

vpcResourceAvailable floating-ips ${BASENAME}-${BASTION_NAME}-ip

BASTION_IP_ADDRESS_JSON=$(ibmcloud is floating-ip $BASTION_IP_ID --output json)
export BASTION_IP_ADDRESS=$(echo "${BASTION_IP_ADDRESS_JSON}" | jq -r '.address')

echo "Bastion: Your bastion IP address: $BASTION_IP_ADDRESS"
export BASTION_MESSAGE="Your bastion IP address: $BASTION_IP_ADDRESS"
