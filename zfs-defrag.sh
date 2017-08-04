#!/bin/bash
###############################################################################
# Copyright (c) 2016, salesforce.com, inc.
#  * All rights reserved.
#  * Licensed under the BSD 3-Clause license. 
# For full license text, see LICENSE.txt file in the repo root  or https://opensource.org/licenses/BSD-3-Clause
###############################################################################

######## Global Variables
VERSION="0.0.2"
# Set you S3 Bucket name
S3_BUCKET="zfs_data"
# Grab our serial number through dmidecode, or just use the short hostname.
# First let's see if dmidecode is installed
which dmidecode >> /dev/null 2>&1
if [ $? -gt 0 ] ; then
    echo -e "dmidecode could not be found. Using short hostname\n"
    SERIAL=$(hostname -s)
else
    SERIAL=$(dmidecode  | grep -A 5 "System Information" | \
    grep "Serial Number" |awk -F: '{print $2}') >> /dev/null 2>&1
fi
if [ -z ${SERIAL} ] || [ ${SERIAL} == 0 ] ; then
    echo -e "No serial number detected from dmidecode, using the short " \
    "hostname \n"
    SERIAL=$(hostname -s)
fi
# Remove whitespace from the serial number if there is any
SERIAL=$(echo ${SERIAL} | sed 's/ //g')
DATE=$(date +%Y-%m-%d)
S3CMD_CONF="/root/.s3cmd.cfg"
S3="s3cmd -c ${S3CMD_CONF}"
# Size of multipart chunks to send during S3 transfer
MULTIPART_MB="500"
# Snapshot naming convention
SNAPSHOT="${SERIAL}-${DATE}"
# Minimum percentage or fragmentation before we should run a defrag
MIN_FRAG="50"

# CPUS for pigz to use
CPUS=$(awk '/siblings/ {print $NF; exit}' /proc/cpuinfo)
PIGZ_CPUS=$(printf "%.0f" $(echo "${CPUS}*.8" | bc))

# Default and recommended zfs settings during the defrag process
# If you're defaults are different, we'll read them in and override
# these settings
ZFS_PARAM_DIR=/sys/module/zfs/parameters

declare -A zfs_default_settings
declare -A zfs_defrag_settings
zfs_defrag_settings['zfs_txg_timeout']=60
zfs_defrag_settings['zfs_dirty_data_sync']=536870912
zfs_defrag_settings['zfs_vdev_sync_write_min_active']=512
zfs_defrag_settings['zfs_vdev_sync_write_max_active']=512
zfs_defrag_settings['zfs_vdev_sync_read_min_active']=512
zfs_defrag_settings['zfs_vdev_sync_read_max_active']=512
zfs_defrag_settings['zfs_vdev_async_read_min_active']=128
zfs_defrag_settings['zfs_vdev_async_read_max_active']=128
zfs_defrag_settings['zfs_vdev_async_write_max_active']=128
zfs_defrag_settings['zfs_vdev_async_write_min_active']=128
zfs_defrag_settings['zfs_vdev_async_write_active_min_dirty_percent']=5
zfs_defrag_settings['zfs_vdev_max_active']=5000

zfs_default_settings['zfs_txg_timeout']=5
zfs_default_settings['zfs_dirty_data_sync']=67108864
zfs_default_settings['zfs_vdev_sync_write_min_active']=10
zfs_default_settings['zfs_vdev_sync_write_max_active']=10
zfs_default_settings['zfs_vdev_sync_read_min_active']=10
zfs_default_settings['zfs_vdev_sync_read_max_active']=10
zfs_default_settings['zfs_vdev_async_read_min_active']=128
zfs_default_settings['zfs_vdev_async_read_max_active']=1
zfs_default_settings['zfs_vdev_async_write_max_active']=3
zfs_default_settings['zfs_vdev_async_write_min_active']=10
zfs_default_settings['zfs_vdev_async_write_active_min_dirty_percent']=30
zfs_default_settings['zfs_vdev_max_active']=1000


# Help menu
read -d '' USAGE << "EOF"
-c <New create statement>   - Used for if you want to make changes to how your\
zfs pool was originally created
-x <new options>            - Used for if you simply want to add extra "-o"\
 options to your "zfs create" statements
-y                          - For defaulting to yes to all questions to use in\
 a semi-hands off state
            **NOTE** This will NOT bypass if there are open files! (hence\
 the semi-hands off)
-h                          - Print this help
EOF
################################

while getopts ":c:x:yh" OPT ; do
    case ${OPT} in
        c ) CREATE_OPTION="${OPTARG}"
        ;;
        x ) EXTRA_CREATE="${OPTARG}"
        ;;
        y ) DEFAULT_YES="1"
        ;;
        h ) echo "${USAGE}"
            exit 0
        ;;
        * ) echo "ERROR: Unknown option: ${OPT}"
            echo -e "${USAGE}"
            exit 1
        ;;
    esac
done





########### Functions
# Used in local and remote snapshot checks
EXISTS_PROMPT="snapshot exists. Should we [U]se the existing  \
snapshot or [D]elete it and create a new one? [u/d]: "

# Get the default ZFS settings in case they are different and override
# our defaults
get_zfs_default () {
    for setting in ${!zfs_defrag_settings[@]} ; do
        if [ -e ${ZFS_PARAM_DIR}/${setting} ] ; then
            zfs_defrag_settings[${setting}]=$(cat ${ZFS_PARAM_DIR}/${setting})
        fi
    done
}
# Set ZFS into "turbo" mode to significantly speed up zfs send
set_zfs_defrag_settings () {
    for setting in ${!zfs_defrag_settings[@]} ; do
        echo ${zfs_defrag_settings[${setting}]} > ${ZFS_PARAM_DIR}/${setting}
    done
}
# set the settings back to default
set_zfs_default_settings () {
    for setting in ${!zfs_default_settings[@]} ; do
        echo ${zfs_default_settings[${setting}]} > ${ZFS_PARAM_DIR}/${setting}
    done
}
# display the current settings (we'll probably only use this in a debug mode)
display_zfs_settings () {
    for setting in ${!zfs_defrag_settings[@]} ; do
        echo -n "${setting}: " ; cat ${ZFS_PARAM_DIR}/${setting}
    done
}

# Check to see if any files are open in any of the pools we are working with.
# Future versions will add in functionality to automatically stop "well known"
# services.
openfile_check () {
    local POOL=$1
    local OPEN=0
    # Check if we have any ZVOLs
    local VOLS=$(zfs list -Ht volume | awk '{print $1}')
    if [[ ! -z ${VOLS} ]] ; then
        echo "We have detected ZVOLs:"
        for VOL in ${VOLS} ; do
            echo -e "\t ${VOL}"
        done
        # This logic will hopefully be in a future version, however the current
        # problem is: "If you don’t have at least as much free space in a pool
        # as the REFER of a ZVOL on that pool, you can’t snapshot the ZVOL,
        # period. "
        # http://jrs-s.net/2016/06/16/psa-snapshots-are-better-than-zvols/
        echo "Unfortunately we currently do not support ZVOLS. Sorry"
        exit 1
    fi

    local MOUNTPOINTS=$(/sbin/zfs list -Ho name,mountpoint | grep ^${POOL}| awk\
     '{print $2}' | sort -u| grep -v "-")
    # Commenting out testing open files on zvol's until we can support zvols.
    #  if [ -e /dev/zvol ]; then
    #      local ZDEVS=$(ls /dev/zd*)
    #      local MOUNTPOINTS="${MOUNTPOINTS} ${ZDEVS}"
    #  fi
    for MP in ${MOUNTPOINTS} ; do
        echo "- Checking Mountpoint ${MP} for open files"
        local PROCS=$(lsof ${MP} | grep -v ^COMMAND | awk '{OFS=","}{print $1,$2,$3}' | sort -u)
        for PROC in ${PROCS} ; do
            local COMMAND=$(echo ${PROC} | cut -f1 -d,)
            local USER=$(echo ${PROC} | cut -f3 -d,)
            local PID=$(echo ${PROC} | cut -f2 -d,)
            echo "${COMMAND} as PID ${PID} has files open on ${MP}"
            echo "Please close these before continuing"
            OPEN+=1
        done
        echo -e "${MP} is clean of open files.\n"
        OPEN+=0
    done
    # We want to just return a value on if there's open files or not rather than
    # simply exiting so that different steps can handle this condition
    # differently
    return ${OPEN}
 }

# Check the current fragmentation against what we feel the minimum should be.
# This is really just a simple check in case you have multiple servers of
# similar names, or even simply multiple windows open so you don't accidently
# run a potentially long-running and destructive procress on the wrong server
check_fragmentation() {
    local POOL=$1
    local f_percentage=$(zpool list ${POOL} -Ho fragmentation)
    local f_percentage=${f_percentage%?}
    if [ -z "$DEFAULT_YES" ] ; then
        if [ ${f_percentage} -lt ${MIN_FRAG} ] ; then
            echo "Pool is only ${f_percentage}% fragmented, which is less than the"\
             "recommended ${MIN_FRAG}%"
            echo -n "Are you sure you want to continue? (y/n) "
            read LETSGO
            case $LETSGO in
                [yY] | [Yy][Ee][Ss] ) echo "OK! Let's go!"
                    return
                    ;;
                [nN] | [n|N][O|o] ) echo "Very well, exiting!"
                    exit 0
                    ;;
                * ) echo "I don't understand what you're saying here, so I'm"\
                    "quitting"
                    exit 0
                    ;;
            esac
        fi
    else
        echo "Current fragmentation is ${f_percentage}%"
    fi
}

# Check to make sure there isn't already an existing snapshot with the same
# name (e.g. script maybe failed at some step and it's being re-run)
# If it does exist, we'll ask if you want to keep the existing snapshot, or
# create a new one.
check_local_snapshot() {
    local POOL=$1
    zfs list -Ht snapshot -o name| egrep "${SNAPSHOT}" >> /dev/null 2>&1
    if [ $? -eq 0 ] ; then
      if [ -z ${DEFAULT_YES} ] ; then
        retries=0
        max_retries=10
        while [ $retries -lt $max_retries ] ; do
            read -p "Local ${EXISTS_PROMPT}" KD_SNAP
            case $KD_SNAP in
                [Uu] | [Uu][Ss][Ee] ) echo "OK using existing snapshot"
                    return 1
                    break;;
                [Dd] | [Dd][Ee][Ll][Ee][Tt][Ee] ) echo "Ok, Deleting and "\
                "creating a new local snapshot"
                    delete_local_snapshot ${POOL}
                    return 0
                    break;;
                * ) echo "Invalid Option: ${KD_SNAP}." >&2
                    if [ $((++retries)) -ge $max_retries ] ; then break 2; fi
                    ;;
            esac
        done
      else
        echo "Delteing existing snapshot and creating a new one"
        delete_local_snapshot ${POOL}
        return 0
      fi
    fi
}

# Again we want to make sure something didn't happen that the snapshot was
# already uploaded.  Maybe it failed during transfer?  Either way we'll
# ask if we want to keep it, or re-upload it.
check_remote_snapshot() {
    local POOL=$1
    echo "Checking if snapshot exists with "
    # Yea, this method of checking if it exists looks pretty dumb, but it's
    # a limitation of s3cmd.  It will return a 0 exit code even if the object
    # does not exist.
    ${S3} ls -H s3://${S3_BUCKET}/${SERIAL}/${POOL}.${SNAPSHOT}.gz | grep ${SNAPSHOT} \
    >> /dev/null 2>&1
    if [ $? -eq 0 ] ; then
      if [ -z ${DEFAULT_YES} ] ; then
        local retries=0
        local max_retries=10
        while [ $retries -lt $max_retries ] ; do
            read -p "Remote ${EXISTS_PROMPT}" KD_SNAP
            case $KD_SNAP in
                [Uu] | [Uu][Ss][Ee] ) echo "OK using existing snapshot"
                    return 1
                    break;;
                [Dd] | [Dd][Ee][Ll][Ee][Tt][Ee] ) echo "Ok, Deleting and "\
                "creating a new remote snapshot"
                    delete_remote_snapshot ${POOL}
                    return 0
                    break;;
                * ) echo "Invalid Option: ${KD_SNAP}." >&2
                    if [ $((++retries)) -ge $max_retries ] ; then break 2; fi
                    ;;
            esac
        done
      else
        echo "Deleting remote snapshot and re-uploading"
        delete_remote_snapshot ${POOL}
        return 0
      fi
    fi
}

# Simple function to destroy the local snapshot
delete_local_snapshot () {
    local POOL=$1
    for SNAP in $(zfs list -Ht snapshot -o name| grep ${POOL} | grep ${SNAPSHOT}) ; do
        echo "Destroying ${SNAP}"
        zfs destroy ${SNAP}
    done
}

# Simple function to delete the snapshot from S3
delete_remote_snapshot () {
    local POOL=$1
    ${S3} rm s3://${S3_BUCKET}/${SERIAL}/${POOL}.${SNAPSHOT}.gz
}

# Creating snapshots, and making sure it all works properly.
# we're destroying data here so we NEED to be sure we have a good backup
snapshot() {
    local POOL=$1
    if [ ! ${POOL} ] ; then
        echo "No pool defined to create a snapshot!"
        exit 1
    fi
    # Make sure it doesn't already exist first
    check_local_snapshot ${POOL}
    if [ $? -gt 0 ] ; then
        return 0
    fi
    # Take the snapshot
    echo "Taking a recursive snapshot of ${POOL}"
    zfs snapshot -r ${POOL}@${SNAPSHOT}
    # Make sure it succeeded
    if [ $? -gt 0 ] ; then
        echo "Snapshot on ${POOL} exited with an error. Please investigate"
        exit 1
    else
        echo "Snapshot on ${POOL} succeeded."
        return 0
    fi
}

# Sending the snapshot to S3. Again since we're being very destructive to data
# we need to be sure it uploaded.  At some point we will want to find a way to
# estimate the compressed size of a snapshot so we can compare sizes to ensure
# we got a complete upload
send_snapshot() {
    local POOL=$1
    # See if the snapshot exists already
    check_remote_snapshot ${POOL}
    if [ $? -gt 0 ] ; then
        return 0
    fi
    # Send the snapshot off to ceph
    echo "Sending Snapshot off to object store"
    zfs send -Rv ${POOL}@${SNAPSHOT} | pigz -p ${PIGZ_CPUS}| | pv |\
    ${S3} --acl-private --no-progress\
      --multipart-chunk-size-mb=${MULTIPART_MB}  put - \
      s3://${S3_BUCKET}/${SERIAL}/${POOL}.${SNAPSHOT}.gz
    if [ $? -gt 0 ] ; then
        echo "zfs send to S3 failed.  Please invesitgate"
        exit 1
    else
        echo "ZFS send succeeded!"
    fi
    echo "Verifying snapshot file exists"
    ${S3} ls -H s3://${S3_BUCKET}/${SERIAL}/${POOL}.${SNAPSHOT}.gz | grep ${SNAPSHOT} \
    >> /dev/null 2>&1
    if [ $? -gt 0 ] ; then
        echo "Snapshot file was not found in object store!"
        return 1
    else
        echo "Snapshot in object store looks good"
        return 0
    fi
}

# Simple function to destroy the ZFS pool
destroy_pool () {
    local POOL=$1
    echo "Destroying existing pool: ${POOL}"
    zpool destroy ${POOL}
    if [ $? -gt 0 ] ; then
        echo "Pool ${POOL} won't die.  Check it out"
        exit 1
    fi
}

# Brining the snapshot back from S3 and re-applying it to the pool
receive_pool () {
    local POOL=$1
    echo "Receiving pool backup"
    ${S3} --no-progress get s3://${S3_BUCKET}/${SERIAL}/${POOL}.${SNAPSHOT}.gz - | pv | \
    pigz -p ${PIGZ_CPUS} -d | zfs receive -F ${POOL}
    if [ $? -gt 0 ] ; then
        echo "ZFS receive failed. Please invesitgate"
        exit 1
    else
        return 0
    fi
}

# re-create the pool once it's been destroyed
create_pool() {
    local CREATE=$1
    echo "Creating new replacement pool"
    ${CREATE}
}

# We want to keep a backup of the zpool history just in case anything goes
# wrong.  If we need to re-run after the pool has been destroyed (e.g. the
# import failed for some reason) we need to be able to find how the pool(s)
# were originally created.
grab_history() {
    local POOL=$1
    echo "Backing up exisitng pool history for safety"
    # Let's keep a copy of the entire history, *JUST* in case.  We can remove
    # this when we're more comfortable with the process
    if [ -e /tmp/zfspool-${POOL}-history-${DATE}.txt ] ; then
        echo "history file exists, moving it to "\
        "/tmp/zfspool-${POOL}-history-${DATE}.txt.$$"
        mv /tmp/zfspool-${POOL}-history-${DATE}.txt \
        /tmp/zfspool-${POOL}-history-${DATE}.txt.$$
    fi
    zpool history ${POOL} | sed 1d | while read -r DATESTAMP LINE; do
        echo "${LINE}" >> /tmp/zfspool-${POOL}-history-${DATE}.txt
    done
    if [ ! -e /tmp/zfspool-${POOL}-history-${DATE}.txt ] ; then
        echo "Failed to pull history!"
        exit 1
    fi
}

# clean up after ourselves like good little admins
cleanup () {
    local POOL=$1
    echo -e "Cleaning up Local and Remote snapshots from defrag process\n"
    echo "Cleaning local snapshots...."
    delete_local_snapshot ${POOL}
    echo "Cleaning remote snapshots..."
    delete_remote_snapshot ${POOL}
    echo "All Clean!"
    echo "Leaving zpool history just in case any settings did not get re-set"\
    "during the import.  When you are finished you can delete it in "\
    "/tmp/zfspool-${POOL}-history-${DATE}.txt"
}


#### MAIN ######

# If we're not root, then exit, because zfs commands won't work as non-root
if [ $(id -u) -ne 0 ] ; then
    echo "You must root to run ZFS commands"
    exit 0
fi

# Set our zfs defaults
get_zfs_default
echo "Setting ZFS settings to speed up zfs send/receive"
set_zfs_defrag_settings
# determine our pools
POOLS=$(zpool list -Ho name)
### TODO: detect when no pools are present, and look for /tmp/zfspool-* files
### and s3 objects to restore from to be able to recover from a failure after
### the snapshot has been completed but it can't restore for some reason.

for p in ${POOLS} ; do
    openfile_check ${p}
    if [ $? -gt 0 ] ; then
        echo "Please close open files before continuing"
        exit 1
    fi
    check_fragmentation ${p}
    grab_history ${p}
    snapshot ${p}
    # Use the create command provided if there is one
    if [ -n "${CREATE_OPTION}" ] ; then
        CREATE=${CREATE_OPTION}
    else
        # How was this pool created?
        CREATE=$(zpool history ${p} | grep "zpool create" | awk '{for (i=2; i<=NF;\
         i++) printf "%s ", $i; printf "\n"; }')
         if [ -z "${CREATE}" ] ; then
             echo "Create statement was not found in zfs history. Grabbing from" \
             "the history file at /tmp/zfspool-${p}-history-${DATE}.txt"
             head -1 /tmp/zfspool-${p}-history-${DATE}.txt | grep create \
             > /dev/null 2>&1
             if [ $? -gt 0 ] ; then
                 echo "Create statement can not be found. Not going further until"\
                 "we know how to re-create the pool!"
                 exit 1
             fi
         fi
         if [ ! -z "${EXTRA_CREATE}" ] ; then
             # Inject our extra options into the existing create commands
             C_LENGTH=${#CREATE}
             COMMAND=${CREATE:0:12}
             ARGS=${CREATE:12:${C_LENGTH}}
             CREATE="${COMMAND} ${EXTRA_CREATE} ${ARGS}"
         fi
     fi
    # Send the snapshot to S3/ceph
    send_snapshot ${p}
    IS_OPEN=1
    while [ ${IS_OPEN} -gt 0 ] ; do
        openfile_check ${p}
        IS_OPEN=$?
        if [ ${IS_OPEN} -gt 0 ] ; then
            echo "The processes above re-opened files on your pool."
            read -n 1 -s -p "Press any key to continue when files are closed. "
        fi
    done
    destroy_pool ${p}
    # Let's wait a second to make sure it all completes nicely
#    sleep 1
#    ok, let's move on and recreate the pool
    create_pool "${CREATE}"
    receive_pool ${p}
    if [ $? -eq 0 ] ; then
        echo "Ensuring all moutpoints are re-mounted"
    fi
    zfs mount -a
    if [ $? -eq 0 ] ; then
        cleanup ${p}
    else
        echo "Mount failed"
        exit 1
    fi
done
echo "Setting ZFS settings back to original"
set_zfs_default_settings
