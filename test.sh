#!/bin/bash +xe
if [ -z "${REPO_NAME}" ]; then
  REPO_NAME=`pushd ${WORKSPACE}/build >/dev/null && git remote show origin -n | grep "Fetch URL:" | sed "s#^.*/\(.*\).git#\1#" && popd > /dev/null`
fi

REPOS=("on-http" "on-taskgraph" "on-dhcp-proxy" "on-tftp" "on-syslog")

VCOMPUTE="${VCOMPUTE}"
if [ -z "${VCOMPUTE}" ]; then
  VCOMPUTE=("quanta_d51")
fi

TEST_GROUP="${TEST_GROUP}"
if [ -z "${TEST_GROUP}" ]; then
   TEST_GROUP="smoke-tests"
fi

HTTP_STATIC_FILES="${HTTP_STATIC_FILES}"
TFTP_STATIC_FILES="${TFTP_STATIC_FILES}"
if [ ! -z "${1}" ]; then
  HTTP_STATIC_FILES=$1
fi
if [ ! -z "${2}" ]; then
  TFTP_STATIC_FILES=$2
fi

dlHttpFiles() {
  if [ -n "${MULTI}" ]; then
    dir=${WORKSPACE}/on-http/static/http/common
  else
    dir=${WORKSPACE}/build/static/http/common
  fi
  if [[ "${REPO_NAME}" != *"on-http"* ]]; then
      dir=${WORKSPACE}/build-deps/on-http/static/http/common
  fi
  mkdir -p ${dir} && cd ${dir}
  # pull down index from bintray repo and parse files from index
  wget --no-check-certificate https://dl.bintray.com/rackhd/binary/builds/ && \
      exec grep 'href=' index.html | awk '{print $3}' | cut -c8-200 | sed -e "s/\"//g" > files
  for i in `cat ./files`; do
    wget --no-check-certificate https://dl.bintray.com/rackhd/binary/builds/${i}
  done
  # attempt to pull down user specified static files
  for i in ${HTTP_STATIC_FILES}; do
     wget --no-check-certificate https://bintray.com/artifact/download/rackhd/binary/builds/${i}
  done
}

dlTftpFiles() {
  if [ -n "${MULTI}" ]; then
    dir=${WORKSPACE}/on-tftp/static/tftp
  else
    dir=${WORKSPACE}/build/static/tftp
  fi
  if [[ "${REPO_NAME}" != *"on-tftp"* ]]; then
      dir=${WORKSPACE}/build-deps/on-tftp/static/tftp
  fi
  mkdir -p ${dir} && cd ${dir}
  # pull down index from bintray repo and parse files from index
  wget --no-check-certificate https://dl.bintray.com/rackhd/binary/ipxe/ && \
      exec grep 'href=' index.html | awk '{print $3}' | cut -c8-200 | sed -e "s/\"//g" > files
  for i in `cat ./files`; do
    wget --no-check-certificate https://dl.bintray.com/rackhd/binary/ipxe/${i}
  done
  # attempt to pull down user specified static files
  for i in ${TFTP_STATIC_FILES}; do
    wget --no-check-certificate https://bintray.com/artifact/download/rackhd/binary/ipxe/${i}
  done
}

prepareDeps() {
  rm -rf ${WORKSPACE}/build-deps
  if [ -z "${MULTI}" ]; then
    mkdir -p ${WORKSPACE}/build-deps/${REPO_NAME} 
  else
    mkdir -p ${WORKSPACE}/build-deps
    mkdir -p ${WORKSPACE}/build
  fi
  for i in ${REPOS[@]}; do
     cd ${WORKSPACE}/build-deps
     if [[ "${REPO_NAME}" != *"${i}"* ]]; then
         git clone https://github.com/RackHD/${i}.git
         cd ${i}
         git checkout ${GIT_REFSPEC}
         npm install --production
     fi
  done
  dlTftpFiles
  dlHttpFiles
  apiPackageModify
}

apiPackageModify() {
  if [[ "${REPO_NAME}" == *"on-http"* ]] && [[ "${REPO_NAME}" == *"rackhd"* ]]; then
    pushd ${WORKSPACE}/on-http/extra
    sed -i "s/.*git symbolic-ref.*/ continue/g" make-deb.sh
    sed -i "/build-package.bash/d" make-deb.sh
    sed -i "/mkdir/d" make-deb.sh
    sudo bash make-deb.sh
    popd
    for package in ${API_PACKAGE_LIST}; do
      sudo pip uninstall -y ${package//./-}
      pushd ${WORKSPACE}/on-http/$package
        fail=true
        while $fail; do
          sudo python setup.py install
          if [ $? -eq 0 ];then
        	  fail=false
          fi
        done
      popd
    done
  fi
}

nodesOff() {
  cd ${WORKSPACE}/build-config/deployment/
  if [ "${USE_VCOMPUTE}" != "false" ]; then
    for i in ${VCOMPUTE[@]}; do
      ./vm_control.sh "${ESXI_HOST},${ESXI_USER},${ESXI_PASS},power_off,1,${i}_*"
    done
  else
     ./telnet_sentry.exp ${SENTRY_HOST} ${SENTRY_USER} ${SENTRY_PASS} off ${OUTLET_NAME}
     sleep 5
  fi
}

nodesOn() {
  cd ${WORKSPACE}/build-config/deployment/
  if [ "${USE_VCOMPUTE}" != "false" ]; then
    for i in ${VCOMPUTE[@]}; do
      ./vm_control.sh "${ESXI_HOST},${ESXI_USER},${ESXI_PASS},power_on,1,${i}_*"
    done
  else
     ./telnet_sentry.exp ${SENTRY_HOST} ${SENTRY_USER} ${SENTRY_PASS} on ${OUTLET_NAME}
     sleep 5
  fi
}

CONFIG_PATH=${CONFIG_PATH-build-config/vagrant/config/mongo}
vagrantUp() {
  cd ${WORKSPACE}/RackHD/example
  cp -rf ${WORKSPACE}/build-config/vagrant/* .
  MODIFIED_REPO_NAME=${REPO_NAME// /,}
  CONFIG_DIR=${CONFIG_PATH} WORKSPACE=${WORKSPACE} REPO_NAME=${MODIFIED_REPO_NAME} MULTI=${MULTI} vagrant up --provision
  if [ $? -ne 0 ]; then 
      echo "Vagrant up failed."
      exit 1
  fi

}

vagrantDestroy() {
  cd ${WORKSPACE}/RackHD/example
  vagrant destroy -f
}

vagrantHalt() {
  cd ${WORKSPACE}/RackHD/example
  vagrant halt
}

vagrantSuspendAll() {
  for box in `vagrant global-status --prune | awk '/running/{print $1}'`; do
    vagrant suspend ${box}
  done
}

virtualBoxDestroyRunning() {
  for uuid in `vboxmanage list runningvms | awk '{print $2}' | tr -d '{}'`; do
    echo "shutting down vm ${uuid}"
    vboxmanage controlvm ${uuid} poweroff
    echo "deleting vm ${uuid}"
    vboxmanage unregistervm ${uuid}
  done
}

generateSolLog(){
  cd ${WORKSPACE}/RackHD/example
  vagrant ssh -c 'cd /home/vagrant/src/build-config/; \
        bash generate-sol-log.sh' > ${WORKSPACE}/sol.log &
}

BASE_REPO_URL="${BASE_REPO_URL}"
runTests() {
  read array<<<"${TEST_GROUP}"
  args=()
  group=" --group="
  for item in $array; do
    args+="${group}${item}"
  done
  cp -f ${WORKSPACE}/build-config/config.ini ${WORKSPACE}/RackHD/test/config
  cd ${WORKSPACE}/RackHD/test
  RACKHD_BASE_REPO_URL=${BASE_REPO_URL} RACKHD_TEST_LOGLVL=INFO \
      python run.py ${args} --with-xunit 
  mkdir -p ${WORKSPACE}/xunit-reports
  cp *.xml ${WORKSPACE}/xunit-reports
}

waitForAPI() {
  timeout=0
  maxto=60
  url=http://localhost:9090/api/1.1/nodes
  while [ ${timeout} != ${maxto} ]; do
    wget --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=15 -t 1 --continue ${url}
    if [ $? = 0 ]; then 
      break
    fi
    sleep 10
    timeout=`expr ${timeout} + 1`
  done
  if [ ${timeout} == ${maxto} ]; then
    echo "Timed out waiting for RackHD API service (duration=`expr $maxto \* 10`s)."
    exit 1
  fi
}

# Prepare the latest dependent repos to be shared with vagrant
prepareDeps

# Power off nodes and shutdown vagrant box
vagrantDestroy
nodesOff

# Suspend any other running vagrant boxes
vagrantSuspendAll

# Delete any running VMs
virtualBoxDestroyRunning

# Power on vagrant box and nodes 
vagrantUp
waitForAPI
nodesOn
generateSolLog
# Run tests
runTests

