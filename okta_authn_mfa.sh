#! /bin/bash

QRCODE_URL=https://qrcode-term.herokuapp.com/qr

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

## functions

usage () {
  echo "Usage: okta_authn_mfa -u <username> -o <okta org subdomain>"
  exit 1
}

requirements () {
  local jqFound="FOUND"

  hash jq 2>/dev/null || jqFound="NOT FOUND"

  if [[ ${jqFound} != "FOUND" ]]
    then
      echo "Some requirements are not met:"
      echo
      echo "jq is ${jqFound}"
      echo
      echo "These tools can be installed with brew on mac."
      echo "for more information, go to: https://brew.sh"
      exit 1
  fi
}

## sets global: sessionToken
authn () {
  echo "Doing primary authentication..."

  local username=$1
  local password=$2
  local orgUrl=$3

  local raw=`curl -s -H "Content-Type: application/json" -d "{\"username\": \"${username}\", \"password\": \"${password}\"}" ${orgUrl}/api/v1/authn`

  local status=`echo $raw | jq -r '.status'`

  if [[ "${status}" == "SUCCESS" ]]
    then
      sessionToken=`echo ${raw} | jq -r '.sessionToken'`
  elif [[ "${status}" == "MFA_ENROLL" ]]
    then
      handle_enroll ${raw} ${orgUrl}
  elif [[ "${status}" == "MFA_REQUIRED" ]]
    then
      handle_push ${raw} ${orgUrl}
  else
    echo "Something went wrong. Here's some raw output:"
    echo ${raw} | jq
    exit 1
  fi
  echo -e "Congratulations! You got a ${GREEN}sessionToken${NC}: ${RED}${sessionToken}${NC}. That will be exchanged for a ${GREEN}sessionId${NC} next."
}

handle_enroll () {
  local raw=$1
  local orgUrl=$2
  
  factorType=`echo ${raw} | jq -r '._embedded.factors[] | select(.factorType == "push") | .factorType'`
  
  if [[ "${factorType}" != "push" ]]
    then
      echo "Only Okta Verify Push factor is supported. Here's some raw output:"
      echo ${raw} | jq
      exit 1
  fi
  
  local stateToken=`echo $raw | jq -r '.stateToken'`
  
  echo -e "Congratulations! You got a ${GREEN}stateToken${NC}: ${RED}${stateToken}i${NC}. That's used in a multi-step authentication flow, like MFA."
  echo

  echo "Sending Okta Verify enroll request..."
  
  local enroll=`curl -s -H "Content-Type: application/json" -d "{\"stateToken\": \"${stateToken}\", \"factorType\": \"push\", \"provider\": \"OKTA\"}" ${orgUrl}/api/v1/authn/factors`
  
  local status=`echo ${enroll} | jq -r '.status'`
  local factorId=`echo ${enroll} | jq -r '._embedded.factor.id'`
  
  if [[ "${status}" != "MFA_ENROLL_ACTIVATE" ]]
    then
      echo "Unexpected status: ${status}. Here's some raw output:"
      echo ${enroll} | jq
      exit 1
  fi
  
  local qrUrl=`echo $enroll | jq -r '._embedded.factor._embedded.activation._links.qrcode.href'`
    
  ## show qrcode in terminal
  curl -s -H "Content-Type: application/json" -d "{\"qrUrl\": \"${qrUrl}\"}" ${QRCODE_URL}
  
  if [[ $? -ne 0 ]]
    then
      echo
      echo "Display QR Code failed."
      exit 1
  fi
  
  echo
  echo -n "Scan the QR code with the Okta Verify app and then hit enter"
  read -s
  echo
  
  local factorEnroll=`curl -s -H "Content-Type: application/json" -d "{\"stateToken\": \"${stateToken}\", \"factorType\": \"push\", \"provider\": \"OKTA\"}" ${orgUrl}/api/v1/authn/factors/${factorId}/lifecycle/activate/poll`
  local enrollStatus=`echo ${factorEnroll} | jq -r '.status'`
  
  if [[ "${enrollStatus}" != "SUCCESS" ]]
    then
      echo "Unexpected status: ${enrollStatus}. Here's some raw output:"
      echo ${factorEnroll} | jq
      exit 1
  fi
  
  sessionToken=`echo ${factorEnroll} | jq -r '.sessionToken'`
}

handle_push () {
  local raw=$1
  local orgUrl=$2

  local stateToken=`echo $raw | jq -r '.stateToken'`
  local pushFactorId=`echo $raw | jq -r '._embedded.factors[] | select(.factorType == "push") | .id'`

  echo -e "Congratulations! You got a ${GREEN}stateToken${NC}: ${RED}${stateToken}i${NC}. That's used in a multi-step authentication flow, like MFA."
  echo

  echo "Sending Okta Verify push notification..."

  local status="MFA_CHALLENGE"
  local tries=0
  while [[ ${status} == "MFA_CHALLENGE" && ${tries} -lt 10 ]]
    do
      local verifyAndPoll=`curl -s -H "Content-Type: application/json" -d "{\"stateToken\": \"${stateToken}\"}" ${orgUrl}/api/v1/authn/factors/${pushFactorId}/verify`
      local status=`echo ${verifyAndPoll} | jq -r .status`
      local tries=$((tries+1))
      echo "Polling for push approve..."
      sleep 6
  done

  if [[ ${status} != "SUCCESS" ]]
    then
      echo "MFA failed. Try again."
      exit 1
  fi

  sessionToken=`echo ${verifyAndPoll} | jq -r '.sessionToken'`
}

## sets global: sessionId
session () {
  echo "Exchanging sessionToken for sessionId..."

  local sessionToken=$1
  local orgUrl=$2
  
  sessionId=`curl -si -D - "${orgUrl}/login/sessionCookieRedirect?checkAccountSetupComplete=true&token=${sessionToken}&redirectUrl=https%3A%2F%2F${ORGPREFIX}.${ORGSUFFIX}%2Fuser%2Fnotifications" | grep -m1 '.*sid=[^";]*;.*' | sed -n 's/.*sid=\([^;]*\);.*/\1/p'`
}

## script start

## check that system requirements are met
requirements

## parse command line options
while getopts ":u:o:" opt; do
  case ${opt} in
    u )
      UNAME=$OPTARG
      ;;
    o ) 
      ORGPREFIX=$OPTARG
      ;;
    : )
      echo "Invalid option: -$OPTARG requires and argument" 1>&2
      echo
      usage
      ;;
    \? ) usage
      ;;
  esac
done
shift $((OPTIND -1))

if [ -z ${UNAME} ]
  then 
    echo "-u <username> is required";  echo;  usage 
fi

if [ -z ${ORGPREFIX} ]
  then
    echo "-o <okta org prefix> is required"; echo; usage
fi

ORGSUFFIX="oktapreview.com"
ORGURL="https://${ORGPREFIX}.${ORGSUFFIX}"

## get password
echo -n "Enter Password for ${UNAME} on ${ORGURL}: "
read -s PASSWORD
echo
echo

## returns sessionToken
authn ${UNAME} ${PASSWORD} ${ORGURL}

## returns sessionId
session ${sessionToken} ${ORGURL}

echo -e "Congratulations! You've established a session with ${ORGURL}. Here's your ${GREEN}sessionId${NC}: ${RED}${sessionId}${NC}"
