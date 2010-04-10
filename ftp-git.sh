#!/bin/sh
#
# Copyright (c) 2010 
# Timo Besenreuther <timo@ezdesign.de>
#

#
# copied from git-ftp
# TODO: move to lib.sh
#

# General config
DEFAULT_PROTOCOL="ftp"
DEPLOYED_SHA1_FILE=".git-ftp.log"
GIT_BIN="/usr/bin/git"
CURL_BIN="/usr/bin/curl"
LCK_FILE="`basename $0`.lck"

# Defaults
URL=""
REMOTE_PROTOCOL=""
REMOTE_HOST=""
REMOTE_USER=${USER}
REMOTE_PASSWD=""
REMOTE_PATH=""
VERBOSE=0
IGNORE_DEPLOYED=0
DRY_RUN=0
CATCHUP=0
FORCE=0

ask_for_passwd() {
    echo -n "Password: "
    stty -echo
    read REMOTE_PASSWD
    stty echo
    echo ""
}

# Checks if last comand was successful
check_exit_status() {
    if [ $? -ne 0 ]; then
        write_error "$1, exiting..." 
        exit 1
    fi
}

# Simple log func
write_log() {
    if [ $VERBOSE -eq 1 ]; then
        echo "`date`: $1"
    fi
}

# Simple error writer
write_error() {
    if [ $VERBOSE -eq 0 ]; then
        echo "Fatal: $1"
    else
        write_log "Fatal: $1"
    fi
}

# Simple info writer
write_info() {
    if [ $VERBOSE -eq 0 ]; then
        echo "Info: $1"
    else
        write_log "Info: $1"
    fi
}

upload_file() {
    source_file=${1}
    dest_file=${2}
    if [ -z ${dest_file} ]; then
        dest_file=${source_file}
    fi
    ${CURL_BIN} -T ${source_file} --user ${REMOTE_USER}:${REMOTE_PASSWD} --ftp-create-dirs -# ftp://${REMOTE_HOST}/${REMOTE_PATH}${dest_file}
}

remove_file() {
    file=${1}
    ${CURL_BIN} --user ${REMOTE_USER}:${REMOTE_PASSWD} -Q "-DELE ${REMOTE_PATH}${file}" ftp://${REMOTE_HOST}
}

get_file_content() {
    source_file=${1}
    ${CURL_BIN} -s --user ${REMOTE_USER}:${REMOTE_PASSWD} ftp://${REMOTE_HOST}/${REMOTE_PATH}${source_file}
}

while test $# != 0
do
	case "$1" in
	    -h|--h|--he|--hel|--help)
		    usage_long
		    ;;
        -u|--user*)
            case "$#,$1" in
                *,*=*)
                    REMOTE_USER=`expr "z$1" : 'z-[^=]*=\(.*\)'`
                    ;;
                1,*)
                    usage 
                    ;;
                *)
                    if [ ! `echo "${2}" | egrep '^-' | wc -l` -eq 1 ]; then
                        REMOTE_USER="$2"
                        shift                        
                    fi
                    ;;                      
            esac
            ;;
        -p|--passwd*)
            case "$#,$1" in
                *,*=*)
                    REMOTE_PASSWD=`expr "z$1" : 'z-[^=]*=\(.*\)'`
                    ;;
                1,*)
                    ask_for_passwd 
                    ;;
                *)
                    if [ ! `echo "${2}" | egrep '^-' | wc -l` -eq 1 ]; then
                        REMOTE_PASSWD="$2"
                        shift
                    else 
                        ask_for_passwd
                    fi
                    ;;
            esac
            ;;
        -a|--all)
            IGNORE_DEPLOYED=1
            ;;
        -c|--catchup)
            CATCHUP=1
            write_info "Catching up, only SHA1 hash will be uploaded"
            ;;
        -D|--dry-run)
            DRY_RUN=1
            write_info "Running dry, won't do anything"            
            ;;
        -v|--verbose)
            VERBOSE=1
            ;;
        -f|--force)
            FORCE=1
            write_log "Forced mode enabled"
            ;;		
        *)
            # Pass thru anything that may be meant for fetch.
            URL=${1}
            ;;
    esac
    shift
done

# Release lock func
release_lock() {
    write_log "Releasing lock"
    rm -f "${LCK_FILE}"
}

# Check if the git working dir is dirty
# This must be checked before lock is written,
# because otherwise directory is always dirty
CLEAN_REPO=`${GIT_BIN} status | grep "nothing to commit (working directory clean)" | wc -l`

# Checks locking, make sure this only run once a time
if [ -f "${LCK_FILE}" ]; then

    # The file exists so read the PID to see if it is still running
    MYPID=`head -n 1 "${LCK_FILE}"`

    TEST_RUNNING=`ps -p ${MYPID} | grep ${MYPID}`

    if [ -z "${TEST_RUNNING}" ]; then
        # The process is not running echo current PID into lock file
        write_log "Not running"
        echo $$ > "${LCK_FILE}"
    else
        write_log "`basename $0` is already running [${MYPID}]"
        exit 0
    fi
else
    write_log "Not running"
    echo $$ > "${LCK_FILE}"
fi

# Check if this is a git project here
if [ ! -d ".git" ]; then
    write_error "Not a git project? Exiting..."
    release_lock
    exit 1
fi 

# Exit if the git working dir is dirty
if [ $CLEAN_REPO -eq 0 ]; then 
    write_error "Dirty Repo? Exiting..."
    release_lock
    exit 1
fi 

if [ ${FORCE} -ne 1 ]; then
    # Check if are at master branch
    CURRENT_BRANCH="`${GIT_BIN} branch | grep '*' | cut -d ' ' -f 2`" 
    if [ "${CURRENT_BRANCH}" != "master" ]; then 
        write_info "You are not on master branch.
Are you sure deploying branch '${CURRENT_BRANCH}'? [Y/n]"
        read answer_branch
        if [ "${answer_branch}" = "n" ] || [ "${answer_branch}" = "N" ]; then
            write_info "Aborting..."
            release_lock
            exit 0
        fi
    fi 
fi

# Split host from url
REMOTE_HOST=`echo "${URL}" | sed "s/.*:\/\/\([a-z0-9\.:-]*\).*/\1/"`
if [ -z ${REMOTE_HOST} ]; then
    REMOTE_HOST=`echo "${URL}" | sed "s/^\([a-z0-9\.:-]*\).*/\1/"`
fi

# Some error checks
HAS_ERROR=0
if [ -z ${REMOTE_HOST} ]; then
    write_error "FTP host not set"
    HAS_ERROR=1
fi

if [ -z ${REMOTE_USER} ]; then
    write_error "FTP user not set"
    HAS_ERROR=1
fi

if [ ${HAS_ERROR} -ne 0 ]; then
    usage
    release_lock
    exit 1
fi

# Split protocol from url 
REMOTE_PROTOCOL=`echo "${URL}" | sed "s/\(ftp\).*/\1/"`

# Check supported protocol
if [ -z ${REMOTE_PROTOCOL} ]; then
    write_info "Protocol unknown or not set, using default protocol '${DEFAULT_PROTOCOL}'"
    REMOTE_PROTOCOL=${DEFAULT_PROTOCOL}
fi

# Split remote path from url
REMOTE_PATH=`echo "${URL}" | sed "s/.*\.[a-z0-9:]*\/\(.*\)/\1/"`

# Add trailing slash if missing 
if [ ! -z ${REMOTE_PATH} ] && [ `echo "${REMOTE_PATH}" | egrep "*/$" | wc -l` -ne 1 ]; then
    write_log "Added missing trailing / in path"
    REMOTE_PATH="${REMOTE_PATH}/"  
fi

write_log "Host is '${REMOTE_HOST}'"
write_log "User is '${REMOTE_USER}'"
write_log "Path is '${REMOTE_PATH}'"

#
# end copied from git-ftp
#




list_dir() {
    # get list from ftp (replace whitespaces for easier iterating)
    list=`$CURL_BIN "ftp://${REMOTE_HOST}/$1" --user "${REMOTE_USER}:${REMOTE_PASSWD}" -s`
    list=`echo "$list" | sed 's/ /;/g'`
    
    echo "ftp -n '${REMOTE_USER}:${REMOTE_PASSWD}@ftp://${REMOTE_HOST}/$1'"
    
        
    # traverse folders and files separately
    files=`echo "$list" | grep "^-"`
    if [ "$files" != "" ]; then
        traverse_files "$files" "$1"
    fi
    
    folders=`echo "$list" | grep "^d"`
    if [ "$folders" != "" ]; then
        traverse_folders "$folders" "$1"
    fi
}

traverse_folders() {
    # descend into subfolder
    for folder in $1; do
        folder_name=`get_file_name $folder/`
        full_name="$2$folder_name"
        echo "$full_name ## DIR"
        list_dir "$full_name"
    done
}

traverse_files() {
    # traverse files
    for file in $1; do
        file_name=`get_file_name $file`
        # get file date
        start=$(( ${#file} - ${#file_name} - 13))
        date=`echo ${file:$start:12} | sed 's/;/ /g'`
        echo "$2$file_name ## $date"
    done
}

# get file name from list record
get_file_name() {
    # TODO: two date formats
    # -rw-r--r--;;;1;user;group;;;;;;;;;;3;Apr;10;16:53;file1.txt
    # drwxr-xr-x;;;2;user;group;;;;;;;4096;Sep;29;;2007;new;folder
    
    record=$1
    
    ex_month="[A-Z][a-z][a-z]"
    ex_day=".[0-9]"
    ex_time="[0-9][0-9]:[0-9][0-9]"
    
    match=`echo $record | grep -o ";$ex_month;$ex_day;$ex_time;.*$"`
    echo ${match:14} | sed 's/;/ /g'
}

# log file names
ftp_log=".ftp-git-live.log"
local_log=".ftp-git.log"

# write log
echo ""
list_dir "${REMOTE_PATH}git-ftp-test/" | tee $ftp_log
echo ""

delete_local_file() {
    echo "DELETE $1"
    echo get_file_name_from_log $1
}

update_local_file() {
    echo "UPDATE $1"
}

get_file_name_from_log() {
    echo "$1" | sed "s/\(.*\) ## .*/\1/"
}

get_date_from_log() {
    
}

# compare logs
# TODO: compare dates
while read ftp_line <&7
do
    read local_line <&8
    if [ "$local_line" == "" ]; then
        # TODO: go through rest of other file
        echo "!!! EOF LOCAL !!!"
        break 2
    fi
    
    while [ "$ftp_line" != "$local_line" ]; do
        
        while [ "$ftp_line" \> "$local_line" ]; do
            delete_local_file "$local_line"
            read local_line <&8
            if [ "$local_line" == "" ]; then
                # TODO: go through rest of other file
                echo "!!! EOF LOCAL !!!"
                break 2
            fi
        done
        
        while [ "$ftp_line" \< "$local_line" ]; do
            update_local_file "$ftp_line"
            read ftp_line <&7
            if [ "$ftp_line" == "" ]; then
                # TODO: go through rest of other file
                echo "!!! EOF FTP !!!"
                break 2
            fi
        done
        
    done
    
done \
    7<$ftp_log \
    8<$local_log

echo ""

release_lock
exit 0
