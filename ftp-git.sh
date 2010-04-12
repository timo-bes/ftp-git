#!/bin/bash

#
# FTP-GIT
# Synchronize down from FTP Server
#
# Copyright (c) 2010 
# Timo Besenreuther <timo@ezdesign.de>
# Based on git-ftp by Eric Greve <ericgreve@gmail.com>
#


# ------------------------------------------------------------
# Setup Environment
# ------------------------------------------------------------

# General config
DEFAULT_PROTOCOL="ftp"
LOG_FILE=".ftp-git.log"
LOG_FILE_TEMP=".ftp-git.cached.log"
GIT_BIN="/usr/bin/git"
CURL_BIN="/usr/bin/curl"
LCK_FILE="`basename $0`.lck"


# ------------------------------------------------------------
# Defaults
# ------------------------------------------------------------
URL=""
REMOTE_PROTOCOL=""
REMOTE_HOST=""
REMOTE_USER=${USER}
REMOTE_PASSWD=""
REMOTE_PATH=""
HTTP_URL=""
VERBOSE=0
DRY_RUN=0
FORCE=0


# ------------------------------------------------------------
# Documentation
# ------------------------------------------------------------

VERSION='0.3'
AUTHORS='Timo Besenreuther <timo@ezdesign.de>'
 
usage_long() {
cat << EOF
USAGE: 
        ftp-git [<options>] <url> [<options>]

DESCRIPTION:
        Synchronize FTP with local git repository (download from FTP).

        Version $VERSION
        Authors $AUTHORS

URL:
        ftp://host.example.com[:<port>][/<remote path>]

OPTIONS:
        -h, --help      Show this message
        -u, --user      FTP login name
        -p, --passwd    FTP password
        -h, --http      The HTTP equivalent to the FTP URL
        -D, --dry-run   Dry run: Does not upload anything
        -f, --force     Force, does not ask questions
        -v, --verbose   Verbose
        
EXAMPLE:
        ftp-git ftp://example.com/httpdocs/ -v -u username -p p4ssw0rd --http http://www.example.com/
EOF
exit 0
}

usage() {
cat << EOF
ftp-git [<options>] <url> [<options>]
EOF
exit 1
}


# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------

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

write_head() {
    echo ""
    echo $1
    echo "**************************************************"
}

write_head_small() {
    echo ""
    echo "# $1"
}

# Release lock func
release_lock() {
    write_log "Releasing lock"
    rm -f "${LCK_FILE}"
    if [ -f "$LOG_FILE_TEMP" ]; then
        rm -f "$LOG_FILE_TEMP"
    fi
}


# ------------------------------------------------------------
# Up- / download functions
# ------------------------------------------------------------

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
    ${CURL_BIN} -s --user ${REMOTE_USER}:${REMOTE_PASSWD} -Q "-DELE ${REMOTE_PATH}${file}" ftp://${REMOTE_HOST}
}

get_file_content() {
    source_file=${1}
    ${CURL_BIN} -s --user ${REMOTE_USER}:${REMOTE_PASSWD} ftp://${REMOTE_HOST}/${REMOTE_PATH}${source_file}
}

download_file() {
    source_file="${1}"
    dest_file="${2}"
    ${CURL_BIN} --user "${REMOTE_USER}:${REMOTE_PASSWD}" "ftp://${REMOTE_HOST}/${REMOTE_PATH}${source_file}" -o "${dest_file}"
}


# ------------------------------------------------------------
# Read params
# ------------------------------------------------------------

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
        -h|--http*)
            case "$#,$1" in
                *,*=*)
                    HTTP_URL=`expr "z$1" : 'z-[^=]*=\(.*\)'`
                    ;;
                *)
                    HTTP_URL="$2"
                    shift
                    ;;
            esac
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


# ------------------------------------------------------------
# Do some checks
# ------------------------------------------------------------

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
    write_log "No other process running"
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
        echo ""
        echo "You are not on master branch."
        echo -n "Master will be synced anyway. Continue? (yes/no) "
        read answer
        echo ""
        if [ $answer != "yes" ] && [ $answer != "y" ]; then
            write_info "Aborting..."
            release_lock
            exit 0
        fi
    fi 
fi

# Check if HTTP URL was specified
if [ "$HTTP_URL" = "" ]; then
    write_error "No HTTP URL (http|h) specified! Exiting..."
    release_lock
    exit 1
fi


# ------------------------------------------------------------
# Derive URL parts
# ------------------------------------------------------------

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
else
    # remove protocol from url
    # otherwise the path can't be found for urls like ftp://example.com/example.com/mydir/
    protocol_length=$(( ${#REMOTE_PROTOCOL} + 3 ))
    URL=${URL:$protocol_length}
fi

# Split remote path from url
REMOTE_PATH=`echo "${URL}" | sed "s/[^\/]*\.[a-z0-9:]*\/\(.*\)/\1/"`

# Add trailing slash if missing 
if [ ! -z ${REMOTE_PATH} ] && [ `echo "${REMOTE_PATH}" | egrep "*/$" | wc -l` -ne 1 ]; then
    write_log "Added missing trailing / in path"
    REMOTE_PATH="${REMOTE_PATH}/"
fi
if [ ! -z ${HTTP_URL} ] && [ `echo "${HTTP_URL}" | egrep "*/$" | wc -l` -ne 1 ]; then
    write_log "Added missing trailing / in HTTP url"
    HTTP_URL="${HTTP_URL}/"
fi

write_log "Host is '${REMOTE_HOST}'"
write_log "User is '${REMOTE_USER}'"
write_log "Path is '${REMOTE_PATH}'"


# ------------------------------------------------------------
# More specific helper functions
# ------------------------------------------------------------

delete_local_file() {
    file_name=`get_file_name_from_log "$1"`
    file_date=`get_file_date_from_log "$1"`
    if [ "$file_date" == "DIR" ]; then
        write_head_small "REMOVE DIR $file_name"
        if [ $DRY_RUN -eq 1 ]; then
            echo "rm -R \"$file_name\""
        else
            if [ -d "$file_name" ]; then
                rm -R "$file_name"
            else
                echo "WARNING: DIRECTORY DOES NOT EXIST"
            fi
        fi
    else
        write_head_small "REMOVE FILE $file_name"
        if [ $DRY_RUN -eq 1 ]; then
            echo "rm \"$file_name\""
        else
            if [ -f "$file_name" ]; then
                rm "$file_name"
            else
                echo "WARNING: FILE DOES NOT EXIST"
            fi
        fi
    fi
}

update_local_file() {
    file_name=`get_file_name_from_log "$1"`
    file_date=`get_file_date_from_log "$1"`
    if [ "$file_name" != "./.ftp-git.log" ]; then
        if [ "$file_name" != "./.git-ftp.log" ]; then
            if [ $file_date == "DIR" ]; then
                write_head_small "CREATE DIR $file_name"
                if [ $DRY_RUN -eq 1 ]; then
                    echo "mkdir \"$file_name\""
                else
                    if [ ! -d "$file_name" ]; then
                        mkdir "$file_name"
                    fi
                fi
            else
                write_head_small "UPDATE FILE $file_name"
                if [ $DRY_RUN -eq 1 ]; then
                    echo "download_file \"${file_name:2}\" \"$file_name\""
                else
                    download_file "${file_name:2}" "$file_name"
                fi
            fi
        fi
    fi
}

get_file_name_from_log() {
    echo "$1" | sed "s/\(.*\) ## .*/\1/"
}

get_file_date_from_log() {
    echo "$1" | sed "s/.* ## \(.*\)/\1/"
}


# ------------------------------------------------------------
# Main part
# ------------------------------------------------------------

#
# 1. Try to merge master onto ftp-git branch
#

# create branch
branch=`$GIT_BIN branch | grep " ftp-git$"`
if [ "$branch" == "" ]; then
    write_head "Creating ftp-git branch"
    $GIT_BIN branch ftp-git
fi

# checkout branch
branch=`$GIT_BIN branch | grep "* ftp-git$"`
if [ "$branch" == "" ]; then
    write_head "Checking out ftp-git"
    $GIT_BIN checkout ftp-git
fi

# merge master
write_head "Attempting to merge master onto ftp-git"
$GIT_BIN merge master

echo ""
echo "Please check the merge above."
echo -n "Did everything go nice and smooth? (yes/no) "
read answer
if [ $answer != "yes" ] && [ $answer != "y" ]; then
    echo "Exiting..."
    release_lock
    exit 1
fi


#
# 2. Generate new list
#

write_head "Generating list from webserver"

script="ftp-git.php"
git_ftp_dir=`echo $0 | sed "s/\(.*\)\/.*/\1/"`

upload_file "$git_ftp_dir/$script" $script
curl -s "$HTTP_URL$script" -o $LOG_FILE_TEMP
temp=`remove_file "$script"`

# statistics
item_cnt=`cat $LOG_FILE_TEMP | wc -l`
dir_cnt=`cat $LOG_FILE_TEMP | grep "DIR$" | wc -l`
dir_cnt=$(( $dir_cnt ))
file_cnt=$(( $item_cnt - $dir_cnt ))

echo "> $file_cnt files, $dir_cnt directories found"


#
# 3. Compare to list from working directory
# 4. Download updates
#

write_head "Comparing the lists"

# compare logs
eof_line="zzzzzzzzzzzzzz"
while true
do
    read live_line <&7
    if [ "$live_line" == "" ]; then
        live_line=$eof_line
    fi
    
    read cached_line <&8
    if [ "$cached_line" == "" ]; then
        cached_line=$eof_line
    fi
    
    while [ "$live_line" != "$cached_line" ]; do
        
        live_name=`get_file_name_from_log "$live_line"`
        cached_name=`get_file_name_from_log "$cached_line"`
        
        if [ "$live_name"  ==  "$cached_line" ]; then
            update_local_file "$live_line"
            break
        fi
        
        while [ "$live_line" \> "$cached_line" ]; do
            delete_local_file "$cached_line"
            read cached_line <&8
            if [ "$cached_line" == "" ]; then
                cached_line=$eof_line
            fi
        done
        
        while [ "$live_line" \< "$cached_line" ]; do
            update_local_file "$live_line"
            read live_line <&7
            if [ "$live_line" == "" ]; then
                live_line=$eof_line
            fi
        done
        
    done
    
    if [ "$cached_line" == "$eof_line" -a "$live_line" == "$eof_line" ]; then
        break;
    fi
    
done \
    7<$LOG_FILE_TEMP \
    8<$LOG_FILE

echo ""
echo "DONE!"


#
# 5. Update list
#

rm -f $LOG_FILE
mv $LOG_FILE_TEMP $LOG_FILE

git add "$LOG_FILE"


# ------------------------------------------------------------
# Instructions for user
# ------------------------------------------------------------

echo ""
echo "******************************************************************************"
echo "you are now on branch ftp-git. please review the changes and merge the branch."
echo "******************************************************************************"
echo ""


# ------------------------------------------------------------
# Clean up
# ------------------------------------------------------------

release_lock
exit 0
