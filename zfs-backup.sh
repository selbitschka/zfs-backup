#!/bin/bash
# shellcheck disable=SC2091
# shellcheck disable=SC2086

readonly VERSION='0.9.5'

# return codes
readonly EXIT_OK=0
readonly EXIT_ERROR=1
readonly EXIT_MISSING_PARAM=2
readonly EXIT_INVALID_PARAM=3
# readonly parameter
readonly ID_LENGTH=10
readonly TYPE_LOCAL=local
readonly TYPE_SSH=ssh

# ZFS commands
# we try to autodetect but in case these variables can be set
ZFS_CMD=
ZPOOL_CMD=
SSH_CMD=
MD5SUM_CMD=
ZFS_CMD_REMOTE=
ZPOOL_CMD_REMOTE=

# defaults
CONFIG_FILE=
LOG_FILE=
LOG_DATE_PATTERN="%Y-%m-%d - %H:%M:%S"
LOG_DEBUG="[DEBUG]"
LOG_INFO="[INFO]"
LOG_WARN="[WARN]"
LOG_ERROR="[ERROR]"
LOG_CMD="[COMMAND]"
SNAPSHOT_PREFIX="bkp"
SNAPSHOT_HOLD_TAG="zfsbackup"

# datasets
ID=
SRC_DATASET=
SRC_TYPE=$TYPE_LOCAL
SRC_ENCRYPTED=false
SRC_DECRYPT=false
SRC_COUNT=1
SRC_SNAPSHOTS=()
SRC_SNAPSHOT_LAST=
SRC_SNAPSHOT_LAST_SYNCED=

DST_DATASET=
DST_TYPE=$TYPE_LOCAL
DST_ENCRYPTED=false
DST_DECRYPT=false
DST_COUNT=1
DST_SNAPSHOTS=()
DST_SNAPSHOT_LAST=
DST_PROP="canmount=off,mountpoint=none,readonly=on"
DST_PROP_ARRAY=()

# boolean options
RECURSIVE=false
RESUME=false
INTERMEDIATE=false
MOUNT=false
BOOKMARK=false
NO_OVERRIDE=false
NO_HOLD=false
MAKE_CONFIG=false
DEBUG=false
DRYRUN=false

# parameter
DEFAULT_SEND_PARAMETER="-Lec"
SEND_PARAMETER=
RECEIVE_PARAMETER=

# pre post scripts
ONLY_IF=
PRE_SNAPSHOT=
POST_SNAPSHOT=
PRE_RUN=
POST_RUN=

# ssh parameter
SSH_HOST=
SSH_PORT=22
SSH_USER=
SSH_KEY=
SSH_OPT="-o ConnectTimeout=10"
#SSH_OPT="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

FIRST_RUN=false
EXECUTION_ERROR=false

RESTORE=false
RESTORE_DESTROY=false

# help text
readonly SRC_DATASET_HELP="Name of the sending dataset (source)."
readonly SRC_TYPE_HELP="Type of source dataset: '$TYPE_LOCAL' or '$TYPE_SSH' (default: local)."
readonly SRC_COUNT_HELP="Number (greater 0) of successful sent snapshots to keep on source side (default: 1)."
readonly DST_DATASET_HELP="Name of the receiving dataset (destination)."
readonly DST_TYPE_HELP="Type of destination dataset: '$TYPE_LOCAL' or '$TYPE_SSH' (default: 'local')."
readonly DST_COUNT_HELP="Number (greater 0) of successful received snapshots to keep on destination side (default: 1)."
readonly DST_PROP_HELP=("Properties to set on destination after first sync. User ',' separated list of 'property=value'" "If 'inherit' is used as value 'zfs inherit' is executed otherwise 'zfs set'." "Default: '$DST_PROP'")

readonly SSH_HOST_HELP="Host to connect to."
readonly SSH_PORT_HELP="Port to use (default: 22)."
readonly SSH_USER_HELP="User used for connection. If not set current user is used."
readonly SSH_KEY_HELP="Key to use for connection. If not set default key is used."
readonly SSH_OPT_HELP="Options used for connection (i.e: '-oStrictHostKeyChecking=accept-new')."

readonly ID_HELP=("Unique ID of backup destination (default: md5sum of destination dataset and ssh host, if present)." "Required if you use multiple destinations to identify snapshots. Maximum of $ID_LENGTH characters or numbers.")
readonly SEND_PARAMETER_HELP="Parameters used for 'zfs send' command. If set these parameters are use and all other settings (see below) are ignored."
readonly RECEIVE_PARAMETER_HELP="Parameters used for 'zfs receive' command. If set these parameters are use and all other settings (see below) are ignored."

readonly BOOKMARK_HELP="Use bookmark (if supported) instead of snapshot on source dataset. Ignored if '-ss, --src-count' is greater 1."
readonly RESUME_HELP="Make sync resume able and resume interrupted streams. User '-s' option during receive."
readonly MOUNT_HELP="Try to mount received dataset on destination. Option '-u' is NOT used during receive."
readonly INTERMEDIATE_HElP=("Use '-I' instead of '-i' while sending to keep intermediary snapshots." "If set, created but not send snapshots are kept, otherwise they are deleted.")
readonly NO_OVERRIDE_HElP=("By default option '-F' is used during receive to discard changes made in destination dataset." "If you use this option receive will fail if destination was changed.")
readonly DECRYPT_HElP=("By default encrypted source datasets are send in raw format using send option '-w'." "This options disables that and sends encrypted (mounted) datasets in plain.")
readonly NO_HOLD_HELP="Do not put hold tag on snapshots created by this tool."
readonly DEBUG_HELP="Print executed commands and other debugging information."

readonly ONLY_IF_HELP=("Command or script to check preconditions, if command fails backup is not started." "Examples:" "check IP: [[ \\\"\\\$(ip -4 addr show wlp5s0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')\\\" =~ 192\\.168\\.2.* ]]" "check wifi: [[ \\\"\\\$(iwgetid -r)\\\" == \\\"ssidname\\\" ]]")
readonly PRE_RUN_HELP="Command or script to be executed before anything else is done (i.e. init a wireguard tunnel)."
readonly POST_RUN_HELP="Command or script to be executed after the this script is finished."
readonly PRE_SNAPSHOT_HELP="Command or script to be executed before snapshot is made (i.e. to lock databases)."
readonly POST_SNAPSHOT_HELP="Command or script to be executed after snapshot is made."

readonly RESTORE_HELP="Restore a previous made backup. Source and destination are switched and the lastest snapshot will be restored."
readonly RESTORE_DESTROY_HELP="WARNING if this option is set option '-F' is used during receive and the existing dataset will be destroyed."

usage() {
  local usage
  usage="zfs-backup Version $VERSION
Usage:
------
zfs-backup -s pool/data -d pool/backup -dt ssh --ssh_host 192.168.1.1 --ssh_user backup ... [--help]
zfs-backup -c configFile ... [--help]
Help:
-----
zfs-backup --help"
  echo "$usage"
}

help() {
  local help
  help="
Help:
=====
Parameters
----------
  -c,  --config    [file]        Config file to load parameter from (default: $CONFIG_FILE).
  --create-config                Create a config file base on given commandline parameters.
                                 If a config file ('-c') is use the output is written to that file.

  -s,  --src       [name]        $SRC_DATASET_HELP
  -st, --src-type  [ssh|local]   $SRC_TYPE_HELP
  -ss, --src-snaps [count]       $SRC_COUNT_HELP
  -d,  --dst       [name]        $DST_DATASET_HELP
  -dt, --dst-type  [ssh|local]   $DST_TYPE_HELP
  -ds, --dst-snaps [count]       $DST_COUNT_HELP
  -dp, --dst-prop  [properties]  ${DST_PROP_HELP[0]}
                                 ${DST_PROP_HELP[1]}
                                 ${DST_PROP_HELP[2]}
  -i,  --id        [name]        ${ID_HELP[0]}
                                 ${ID_HELP[1]}
  --send-param     [parameters]  $SEND_PARAMETER_HELP
  --recv-param     [parameters]  $RECEIVE_PARAMETER_HELP
  --bookmark                     $BOOKMARK_HELP
  --resume                       $RESUME_HELP
  --intermediary                 ${INTERMEDIATE_HElP[0]}
                                 ${INTERMEDIATE_HElP[1]}
  --mount                        $MOUNT_HELP
  --no-override                  ${NO_OVERRIDE_HElP[0]}
                                 ${NO_OVERRIDE_HElP[1]}
  --decrypt                      ${DECRYPT_HElP[0]}
                                 ${DECRYPT_HElP[1]}
  --no-holds                     $NO_HOLD_HELP
  --only-if        [command]     ${ONLY_IF_HELP[0]}
                                 ${ONLY_IF_HELP[1]}
                                 ${ONLY_IF_HELP[2]}
                                 ${ONLY_IF_HELP[3]}
  --pre-run        [command]     $PRE_RUN_HELP
  --post-run       [command]     $POST_RUN_HELP
  --pre-snapshot   [command]     $PRE_SNAPSHOT_HELP
  --post-snapshot  [command]     $POST_SNAPSHOT_HELP

  --restore                      $RESTORE_HELP
  --restore-destroy              $RESTORE_DESTROY_HELP

  --log-file       [file]        Logfile

  -v,  --verbose                 $DEBUG_HELP
  --dryrun                       Do check inputs, dataset existence,... but do not create or destroy snapshot or transfer data.
  --version                      Print version.

Types:
------
  'local'                       Local dataset.
  'ssh'                         Traffic is streamed from/to ssh. Only source or destination can use ssh, other need to be local.

SSH Options
-----------
If you use type 'ssh' you need to specify Host, Port, etc.
 --ssh_host [hostname]          $SSH_HOST_HELP
 --ssh_port [port]              $SSH_PORT_HELP
 --ssh_user [username]          $SSH_USER_HELP
 --ssh_key  [keyfile]           $SSH_KEY_HELP
 --ssh_opt  [options]           $SSH_OPT_HELP

Help
----
  -h,  --help              Print this message."

  # --recursive                    Create and send recursive. Use '-r' during snapshot generation and '-Rp' during send.
  echo "$help"
}

function help_permissions_send() {
  local current_user
  if [ "$SRC_TYPE" == "$TYPE_SSH" ] && [ "$SSH_USER" != "" ]; then
    current_user=$SSH_USER
  else
    current_user=$(whoami)
  fi
  log_debug "Sending user '$current_user' maybe has not enough rights."
  log_debug "To set right on sending side use:"
  log_debug "zfs allow -u $current_user send,snapshot,hold,release,destroy,mount $SRC_DATASET"
}

function help_permissions_receive() {
  local current_user
  if [ "$DST_TYPE" == "$TYPE_SSH" ] && [ "$SSH_USER" != "" ]; then
    current_user=$SSH_USER
  else
    current_user=$(whoami)
  fi
  log_debug "Receiving user '$current_user' maybe has not enough rights."
  log_debug "To set right on sending side use:"
  log_debug "zfs allow -u $current_user compression,create,mount,receive $(dataset_parent $DST_DATASET)"
  log_debug "zfs allow -d -u $current_user canmount,destroy,hold,mountpoint,readonly,release $(dataset_parent $DST_DATASET)"
}

function load_parameter() {
  # read all parameters
  POSITIONAL=()
  while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
    -c | --config)
      CONFIG_FILE="$2"
      shift
      shift
      ;;
    --create-config)
      MAKE_CONFIG=true
      shift
      ;;
    -i | --id)
      ID="${2:0:$ID_LENGTH}"
      shift
      shift
      ;;
    -s | --src)
      SRC_DATASET="$2"
      shift
      shift
      ;;
    -st | --src-type)
      SRC_TYPE="$2"
      shift
      shift
      ;;
    -ss | --src-snaps)
      SRC_COUNT="$2"
      shift
      shift
      ;;
    -d | --dst)
      DST_DATASET="$2"
      shift
      shift
      ;;
    -dt | --dst-type)
      DST_TYPE="$2"
      shift
      shift
      ;;
    -ds | --dst-snaps)
      DST_COUNT="$2"
      shift
      shift
      ;;
    -dp | --dst-prop)
      DST_PROP="$2"
      shift
      shift
      ;;
    --send-param)
      if [ "${2:0:1}" == "-" ]; then
        SEND_PARAMETER="$2"
      else
        SEND_PARAMETER="-$2"
      fi
      shift
      ;;
    --recv-param)
      if [ "${2:0:1}" == "-" ]; then
        RECEIVE_PARAMETER="$2"
      else
        RECEIVE_PARAMETER="-$2"
      fi
      shift
      ;;
    --bookmark)
      BOOKMARK=true
      shift
      ;;
      #  --recursive)
      #    RECURSIVE=true
      #    shift
      #    ;;
    --resume)
      RESUME=true
      shift
      ;;
    --intermediary)
      INTERMEDIATE=true
      shift
      ;;
    --mount)
      MOUNT=true
      shift
      ;;
    --no-override)
      NO_OVERRIDE=true
      shift
      ;;
    --decrypt)
      SRC_DECRYPT=true
      shift
      ;;
    --no-holds)
      NO_HOLD=true
      shift
      ;;
    --only-if)
      ONLY_IF="$2"
      shift
      shift
      ;;
    --pre-snapshot)
      PRE_SNAPSHOT="$2"
      shift
      shift
      ;;
    --post-snapshot)
      POST_SNAPSHOT="$2"
      shift
      shift
      ;;
    --pre-run)
      PRE_RUN="$2"
      shift
      shift
      ;;
    --post-run)
      POST_RUN="$2"
      shift
      shift
      ;;
    --ssh_host)
      SSH_HOST="$2"
      shift
      shift
      ;;
    --ssh_port)
      SSH_PORT="$2"
      shift
      shift
      ;;
    --ssh_user)
      SSH_USER="$2"
      shift
      shift
      ;;
    --ssh_key)
      SSH_KEY="$2"
      shift
      shift
      ;;
    --ssh_opt)
      SSH_OPT="$2"
      shift
      shift
      ;;
    -v | --verbose)
      DEBUG=true
      shift
      ;;
    --dryrun)
      DRYRUN=true
      shift
      ;;
    --restore)
      RESTORE=true
      shift
      ;;
    --restore-destroy)
      RESTORE_DESTROY=true
      shift
      ;;
    --log-file)
      LOG_FILE="$2"
      shift
      shift
      ;;
    --version)
      echo "zfs-backup $VERSION"
      exit $EXIT_OK
      ;;
    -h | --help)
      usage
      help
      exit $EXIT_OK
      ;;
    *) # unknown option
      POSITIONAL+=("$1") # save it in an array for later
      shift              # past argument
      ;;
    esac
  done
  set -- "${POSITIONAL[@]}" # restore positional parameters
}

# print log output
# $1 log message, $2 severity pattern
function log() {
  if [ -n "$1" ]; then
    if [ -z "$LOG_FILE" ]; then
      case "$2" in
      "$LOG_INFO" | "$LOG_DEBUG")
        echo "$1"
        ;;
      "$LOG_WARN" | "$LOG_ERROR" | "$LOG_CMD")
        # log commands to stderr to do not interfere with echo results
        echo "$1" >&2
        ;;
      *)
        echo "$1"
        ;;
      esac
    else
      if [ -n "$2" ]; then
        echo "$(date +"$LOG_DATE_PATTERN") - $1" >>"$LOG_FILE"
      else
        echo "$(date +"$LOG_DATE_PATTERN") - $2 - $1" >>"$LOG_FILE"
      fi
    fi
  fi
}

function log_debug() {
  if [ "$DEBUG" == "true" ]; then
    log "$1" "$LOG_DEBUG"
  fi
}

function log_info() {
  log "$1" "$LOG_INFO"
}

function log_warn() {
  log "$1" "$LOG_WARN"
}

function log_error() {
  log "$1" "$LOG_ERROR"
}

function log_cmd() {
  if [ "$DEBUG" == "true" ]; then
    log "executing: '$1'" "$LOG_CMD"
  fi
}

# date utility functions
function date_text() {
  date +%Y%m%d_%H%M%S
}

function date_seconds() {
  date +%s
}

function date_compare() {
  local pattern="^[0-9]+$"
  if [[ "$1" != "" ]] && [[ $1 =~ $pattern ]] && [[ "$2" != "" ]] && [[ $2 =~ $pattern ]]; then
    [[ $1 > $2 ]]
  else
    false
  fi
}

function load_config() {
  if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
}

# create ssh command
function ssh_cmd() {
  local cmd="$SSH_CMD"
  if [ -n "$SSH_PORT" ]; then
    cmd="$cmd -p $SSH_PORT"
  fi
  if [ -n "$SSH_KEY" ]; then
    cmd="$cmd -i $SSH_KEY"
  fi
  if [ -n "$SSH_USER" ]; then
    cmd="$cmd -l $SSH_USER"
  fi
  if [ -n "$SSH_OPT" ]; then
    cmd="$cmd $SSH_OPT"
  fi
  echo "$cmd $SSH_HOST "
}

# $1 type - 'local', 'ssh'
# $2 command to execute
function build_cmd() {
  case "$1" in
  "$TYPE_LOCAL")
    echo "$2"
    ;;
  "$TYPE_SSH")
    echo "$(ssh_cmd) $2"
    ;;
  *)
    log_error "Invalid type '$1'. Use '$TYPE_LOCAL' for local backup or '$TYPE_SSH' for remote server."
    stop $EXIT_ERROR
    ;;
  esac
}

# zpool from dataset
# $1 dataset
function zpool() {
  local split
  IFS='/' read -ra split <<<"$1"
  unset IFS
  echo "${split[0]}"
}

# command used to test if pool supports bookmarks
# $1 zpool command
# $2 dataset name
function zpool_exists_cmd() {
  local pool
  pool="$(zpool "$2")"
  echo "$1 list $pool"
}

# command used to test if pool supports bookmarks
# $1 zpool command
# $2 dataset name
function zpool_bookmarks_cmd() {
  local pool
  pool="$(zpool "$2")"
  echo "$1 get -Hp -o value feature@bookmarks $pool"
}

# command used to test if pool supports encryption
# $1 zpool command
# $2 dataset name
function zpool_encryption_cmd() {
  local pool
  pool="$(zpool "$2")"
  echo "$1 get -Hp -o value feature@encryption $pool"
}

# test if pool exists
# $1 is source
function pool_exists() {
  local cmd
  if [ "$1" == "true" ]; then
    cmd="$(build_cmd "$SRC_TYPE" "$(zpool_exists_cmd $ZPOOL_CMD "$SRC_DATASET")")"
  else
    cmd="$(build_cmd "$DST_TYPE" "$(zpool_exists_cmd $ZPOOL_CMD_REMOTE "$DST_DATASET")")"
  fi
  log_cmd "$cmd"
  [[ $($cmd) ]] &>/dev/null
  return
}

# test if pool supports bookmarks
# $1 is source
function pool_support_bookmarks() {
  local cmd
  if [ "$1" == "true" ]; then
    cmd="$(build_cmd "$SRC_TYPE" "$(zpool_bookmarks_cmd $ZPOOL_CMD "$SRC_DATASET")")"
  else
    cmd="$(build_cmd "$DST_TYPE" "$(zpool_bookmarks_cmd $ZPOOL_CMD_REMOTE "$DST_DATASET")")"
  fi
  log_cmd "$cmd"
  [[ $($cmd) != "disabled" ]] &>/dev/null
  return
}

# test if pool supports bookmarks
# $1 is source
function pool_support_encryption() {
  local cmd
  local pool
  pool="$(zpool "$2")"
  if [ "$1" == "true" ]; then
    cmd="$(build_cmd "$SRC_TYPE" "$(zpool_encryption_cmd $ZPOOL_CMD "$SRC_DATASET")")"
  else
    cmd="$(build_cmd "$DST_TYPE" "$(zpool_encryption_cmd $ZPOOL_CMD_REMOTE "$DST_DATASET")")"
  fi
  log_cmd "$cmd"
  [[ $($cmd) != "disabled" ]] &>/dev/null
  return
}

# command used to test if dataset exists
# $1 zfs command
# $2 dataset name
function zfs_exist_cmd() {
  echo "$1 list -H $2"
}

# command used to list available dataset
# $1 zfs command
function zfs_list_cmd() {
  echo "$1 list -H -o name"
}

# command used to get creation time
# $1 zfs command
# $2 dataset name
function zfs_creation_cmd() {
  echo "$1 get -Hp -o value creation $2"
}

# command used to get test encryption
# $1 zfs command
# $2 dataset name
function zfs_encryption_cmd() {
  echo "$1 get -Hp -o value encryption $2"
}

# command used to get a list of all snapshots
# $1 zfs command
# $2 dataset name
function zfs_snapshot_list_cmd() {
  echo "$1 list -Hp -t snapshot -o name -s creation $2"
}

# command used to get a list of all snapshots
# $1 zfs command
# $2 dataset name
function zfs_bookmark_list_cmd() {
  echo "$1 list -Hp -t bookmark -o name -s creation $2"
}

# command used to get a list of all snapshots and bookmarks
# $1 zfs command
# $2 dataset name
function zfs_snapshot_bookmark_list_cmd() {
  echo "$1 list -Hrp -t snapshot,bookmark -o name -s creation $2"
}

# command used to create a new snapshots
# $1 zfs command
# $2 dataset name
function zfs_snapshot_create_cmd() {
  if [ "$RECURSIVE" == "true" ]; then
    echo "$1 snapshot -r $2@${SNAPSHOT_PREFIX}_${ID}_$(date_text)"
  else
    echo "$1 snapshot $2@${SNAPSHOT_PREFIX}_${ID}_$(date_text)"
  fi
}

# command used to rename a synced snapshots
# $1 zfs command
# $2 snapshot name
# $3 new name
function zfs_snapshot_rename_cmd() {
  if [ "$RECURSIVE" == "true" ]; then
    echo "$1 rename -r $2 $3"
  else
    echo "$1 rename $2 $3"
  fi
}

# command used to destroy a snapshot
# $1 zfs command
# $2 snapshot name
function zfs_snapshot_destroy_cmd() {
  if [[ "$2" =~ .*[@#].* ]]; then
    if [ "$RECURSIVE" == "true" ]; then
      echo "$1 destroy -r $2"
    else
      echo "$1 destroy $2"
    fi
  else
    log_error "Preventing destroy command for '$2' not containing '@' or '#', since we only destroy snapshots or bookmarks."
    log_error "Abort backup."
    stop $EXIT_ERROR
  fi
}

# command used to hold a snapshot
# $1 zfs command
# $2 snapshot name
function zfs_snapshot_hold_cmd() {
  if [ "$RECURSIVE" == "true" ]; then
    echo "$1 hold -r $SNAPSHOT_HOLD_TAG $2"
  else
    echo "$1 hold $SNAPSHOT_HOLD_TAG $2"
  fi
}

# command used to release a snapshot
# $1 zfs command
# $2 snapshot name
function zfs_snapshot_release_cmd() {
  if [ "$RECURSIVE" == "true" ]; then
    echo "$1 release -r $SNAPSHOT_HOLD_TAG $2"
  else
    echo "$1 release $SNAPSHOT_HOLD_TAG $2"
  fi
}

# command used to set property
# $1 zfs command
# $2 property=value
# $3 dataset
function zfs_set_cmd() {
  echo "$1 set $2 $3"
}

# command used to inherit property
# $1 zfs command
# $2 property
# $3 dataset
function zfs_inherit_cmd() {
  echo "$1 inherit $2 $3"
}

# command used to send a snapshot
# $1 zfs command
# $2 snapshot from name
# $3 snapshot to name
function zfs_snapshot_send_cmd() {
  local cmd
  cmd="$1 send"
  if [ -n "$SEND_PARAMETER" ]; then
    cmd="$cmd $SEND_PARAMETER"
  else
    cmd="$cmd $DEFAULT_SEND_PARAMETER"
    if [ "$RESTORE" == "true" ] && [ "$SRC_DECRYPT" == "false" ]; then
      cmd="$cmd -p"
    elif [ "$FIRST_RUN" == "true" ] && [ "$SRC_DECRYPT" == "false" ]; then
      cmd="$cmd -p"
    fi
    if [ "$SRC_ENCRYPTED" == "true" ] && [ "$SRC_DECRYPT" == "false" ]; then
      cmd="$cmd -w"
    fi
    if [ "$RECURSIVE" == "true" ]; then
      cmd="$cmd -R"
    fi
  fi
  if [ -z "$2" ]; then
    cmd="$cmd $3"
  elif [ "$INTERMEDIATE" == "true" ]; then
    cmd="$cmd -I $2 $3"
  else
    cmd="$cmd -i $2 $3"
  fi
  echo "$cmd"
}

# command used to receive a snapshot
# $1 zfs command
# $2 dst dataset
# $3 is resume
function zfs_snapshot_receive_cmd() {
  local cmd
  cmd="$1 receive"
  if [ -n "$RECEIVE_PARAMETER" ]; then
    cmd="$cmd $RECEIVE_PARAMETER"
  else
    if [ "$RESTORE" == "true" ] && [ "$SRC_DECRYPT" == "false" ]; then
      cmd="$cmd -x encryption"
    fi
    if [ "$RESUME" == "true" ]; then
      cmd="$cmd -s"
    fi
    if [ "$MOUNT" == "false" ]; then
      cmd="$cmd -u"
    fi
    if [[ -z "$3" && ("$FIRST_RUN" == "true" || "$NO_OVERRIDE" == "false") ]]; then
      cmd="$cmd -F"
    fi
  fi
  cmd="$cmd $2"
  echo "$cmd"
}

# command used to create a bookmark from snapshots
# $1 zfs command
# $2 snapshot name
function zfs_bookmark_create_cmd() {
  local bookmark
  # shellcheck disable=SC2001
  bookmark=$(sed "s/@/#/g" <<<"$2")
  echo "$1 bookmark $2 $bookmark"
}

# command used to destroy a bookmark
# $1 zfs command
# $2 bookmark name
function zfs_bookmark_destroy_cmd() {
  echo "$1 destroy $2"
}

# command used to get resume token
# $1 zfs command
# $2 dataset name
function zfs_resume_token_cmd() {
  echo "$1 get -Hp -o value receive_resume_token $2"
}

# command used to send with resume token
# $1 zfs command
# $2 resume token
function zfs_resume_send_cmd() {
  echo "$1 send -t $2"
}

# remove dataset from snapshot or bookmark fully qualified name
# $1 dataset name
# $2 full name including snapshot/bookmark name
function snapshot_name() {
  if [ -n "$1" ] && [ -n "$2" ] && [ ${#2} -gt ${#1} ]; then
    echo "${2:${#1}+1}"
  fi
}

# parent from dataset
# $1 dataset
function dataset_parent() {
  local split
  local parent
  IFS='/'
  read -ra split <<<"$1"
  split=("${split[@]::${#split[@]}-1}")
  parent="${split[*]}"
  unset IFS
  echo "$parent"
}

# $1 is source
function dataset_list() {
  local cmd
  if [ "$1" == "true" ]; then
    echo "Following source datasets are available:"
    cmd="$(build_cmd "$SRC_TYPE" "$(zfs_list_cmd $ZFS_CMD)")"
  else
    echo "Following destination datasets are available:"
    cmd="$(build_cmd "$DST_TYPE" "$(zfs_list_cmd $ZFS_CMD_REMOTE)")"
  fi
  log_cmd "$cmd"
  # shellcheck disable=SC2005
  echo "$($cmd)"
}

# $1 is source
# $2 optional dataset
function dataset_exists() {
  local cmd
  if [ "$1" == "true" ]; then
    if [ -z "$2" ]; then
      cmd="$(build_cmd "$SRC_TYPE" "$(zfs_exist_cmd $ZFS_CMD "$SRC_DATASET")")"
    else
      cmd="$(build_cmd "$SRC_TYPE" "$(zfs_exist_cmd $ZFS_CMD "$2")")"
    fi
  else
    if [ -z "$2" ]; then
      cmd="$(build_cmd "$DST_TYPE" "$(zfs_exist_cmd $ZFS_CMD_REMOTE "$DST_DATASET")")"
    else
      cmd="$(build_cmd "$DST_TYPE" "$(zfs_exist_cmd $ZFS_CMD_REMOTE "$2")")"
    fi
  fi
  log_cmd "$cmd"
  [[ $($cmd) ]] &>/dev/null
  return
}

# $1 is source
# $2 optional dataset
function dataset_encrypted() {
  local cmd
  if [ "$1" == "true" ]; then
    if [ -z "$2" ]; then
      cmd="$(build_cmd "$SRC_TYPE" "$(zfs_encryption_cmd $ZFS_CMD "$SRC_DATASET")")"
    else
      cmd="$(build_cmd "$SRC_TYPE" "$(zfs_encryption_cmd $ZFS_CMD "$2")")"
    fi
  else
    if [ -z "$2" ]; then
      cmd="$(build_cmd "$DST_TYPE" "$(zfs_encryption_cmd $ZFS_CMD_REMOTE "$DST_DATASET")")"
    else
      cmd="$(build_cmd "$DST_TYPE" "$(zfs_encryption_cmd $ZFS_CMD_REMOTE "$2")")"
    fi
  fi
  log_cmd "$cmd"
  [[ ! $($cmd) == "off" ]] &>/dev/null
  return
}

# $1 is source
function dataset_list_snapshots() {
  local cmd
  if [ "$1" == "true" ]; then
    cmd="$(build_cmd "$SRC_TYPE" "$(zfs_snapshot_list_cmd $ZFS_CMD "$SRC_DATASET")")"
  else
    cmd="$(build_cmd "$DST_TYPE" "$(zfs_snapshot_list_cmd $ZFS_CMD_REMOTE "$DST_DATASET")")"
  fi
  log_cmd "$cmd"
  # shellcheck disable=SC2005
  echo "$($cmd)"
}

# $1 is source
function dataset_list_bookmarks() {
  local cmd
  if [ "$1" == "true" ]; then
    cmd="$(build_cmd "$SRC_TYPE" "$(zfs_bookmark_list_cmd $ZFS_CMD "$SRC_DATASET")")"
  else
    cmd="$(build_cmd "$DST_TYPE" "$(zfs_bookmark_list_cmd $ZFS_CMD_REMOTE "$DST_DATASET")")"
  fi
  log_cmd "$cmd"
  # shellcheck disable=SC2005
  echo "$($cmd)"
}

# $1 is source
function dataset_list_snapshots_bookmarks() {
  local cmd
  if [ "$1" == "true" ]; then
    cmd="$(build_cmd "$SRC_TYPE" "$(zfs_snapshot_bookmark_list_cmd $ZFS_CMD "$SRC_DATASET")")"
  else
    cmd="$(build_cmd "$DST_TYPE" "$(zfs_snapshot_bookmark_list_cmd $ZFS_CMD_REMOTE "$DST_DATASET")")"
  fi
  log_cmd "$cmd"
  # shellcheck disable=SC2005
  echo "$($cmd)"
}

function dataset_resume_token() {
  local cmd
  cmd="$(build_cmd "$DST_TYPE" "$(zfs_resume_token_cmd $ZFS_CMD_REMOTE "$DST_DATASET")")"
  log_cmd "$cmd"
  # shellcheck disable=SC2005
  echo "$($cmd)"
}

# $1 command
# $2 no dryrun
function execute() {
  log_cmd "$1"
  if [ "$DRYRUN" == "true" ] && [ -z "$2" ]; then
    log_info "dryrun ... nothing done."
    return 0
  elif [ -n "$LOG_FILE" ]; then
    eval $1 >>$LOG_FILE 2>&1
    return
  else
    eval $1
    return
  fi
}

# $1 is source
# $2 snapshot name
function execute_snapshot_hold() {
  local cmd
  cmd=
  if [ "$1" == "true" ]; then
    cmd="$(build_cmd $SRC_TYPE "$(zfs_snapshot_hold_cmd $ZFS_CMD "$2")")"
  else
    cmd="$(build_cmd $DST_TYPE "$(zfs_snapshot_hold_cmd $ZFS_CMD_REMOTE "$2")")"
  fi
  log_info "hold snapshot $2 ..."
  if execute "$cmd"; then
      log_debug "... snapshot $2 hold tag '$SNAPSHOT_HOLD_TAG'."
  else
      log_error "Error hold snapshot $2."
      EXECUTION_ERROR=true
  fi
  return
}


# $1 is source
# $2 snapshot name
function execute_snapshot_release() {
  local cmd
  if [ "$1" == "true" ]; then
    cmd="$(build_cmd $SRC_TYPE "$(zfs_snapshot_release_cmd $ZFS_CMD "$2")")"
  else
    cmd="$(build_cmd $DST_TYPE "$(zfs_snapshot_release_cmd $ZFS_CMD_REMOTE "$2")")"
  fi
  log_info "... release snapshot $2"
  if execute "$cmd"; then
    log_debug "... snapshot $2 released tag '$SNAPSHOT_HOLD_TAG'."
  else
    log_error "Error releasing snapshot $2."
    EXECUTION_ERROR=true
  fi
}

# $1 is source
# $2 snapshot name
function execute_snapshot_destroy() {
  local cmd
  if [ "$1" == "true" ]; then
    cmd="$(build_cmd $SRC_TYPE "$(zfs_snapshot_destroy_cmd $ZFS_CMD "$2")")"
  else
    cmd="$(build_cmd $DST_TYPE "$(zfs_snapshot_destroy_cmd $ZFS_CMD_REMOTE "$2")")"
  fi
  log_info "... destroying snapshot $2"
  if execute "$cmd"; then
    log_debug "... snapshot $2 destroyed."
  else
    log_error "Error destroying snapshot $2."
    EXECUTION_ERROR=true
  fi
}

# $1 is source
# $2 bookmark name
function execute_bookmark_destroy() {
  local cmd
  if [ "$1" == "true" ]; then
    cmd="$(build_cmd $SRC_TYPE "$(zfs_bookmark_destroy_cmd $ZFS_CMD "$2")")"
  else
    cmd="$(build_cmd $DST_TYPE "$(zfs_bookmark_destroy_cmd $ZFS_CMD_REMOTE "$2")")"
  fi
  log_info "... destroying bookmark $2"
  if execute "$cmd"; then
    log_debug "... bookmark $2 destroyed."
  else
    log_error "Error destroying bookmark $2."
    EXECUTION_ERROR=true
  fi
}

function distro_dependent_commands() {
  local cmd
  local zfs_path
  local distro
  local release

  if [ -z "$SSH_CMD" ]; then
    SSH_CMD=$(command -v ssh)
  fi

  if [ -z "$MD5SUM_CMD" ]; then
    MD5SUM_CMD=$(command -v md5sum)
  fi

  if [[ -z "$ZFS_CMD" || -z "$ZPOOL_CMD" ]]; then
    cmd="$(build_cmd $SRC_TYPE "lsb_release --id --short")"
    echo "$cmd"
    log_debug "determining source commands ..."
    log_cmd "$cmd"
    distro=$($cmd)
    case $distro in
    Ubuntu)
      release=$($(build_cmd $SRC_TYPE "lsb_release --release --short"))
      if [[ "${release:0:2}" -gt 19 ]]; then
        zfs_path="/usr/sbin/"
      else
        zfs_path="/sbin/"
      fi
      ;;
    Linuxmint)
      zfs_path="/sbin/"
      ;;
    *)
      zfs_path="/sbin/"
      ;;
    esac

    [ -z "$ZFS_CMD" ] && ZFS_CMD="${zfs_path}zfs"
    [ -z "$ZPOOL_CMD" ] && ZPOOL_CMD="${zfs_path}zpool"
  fi

  if [[ -z "$ZFS_CMD_REMOTE" || -z "$ZPOOL_CMD_REMOTE" ]]; then
    cmd="$(build_cmd $DST_TYPE "lsb_release --id --short")"
    log_debug "determining destination commands ..."
    log_cmd "$cmd"
    distro=$($cmd)
    case $distro in
    Ubuntu)
      release=$($(build_cmd $DST_TYPE "lsb_release --release --short"))
      if [[ "${release:0:2}" -gt 19 ]]; then
        zfs_path="/usr/sbin/"
      else
        zfs_path="/sbin/"
      fi
      ;;
    Linuxmint)
      zfs_path="/sbin/"
      ;;
    *)
      ;;
    esac

    [ -z "$ZFS_CMD_REMOTE" ] && ZFS_CMD_REMOTE="${zfs_path}zfs"
    [ -z "$ZPOOL_CMD_REMOTE" ] && ZPOOL_CMD_REMOTE="${zfs_path}zpool"
  fi
}

function validate_backup() {
  local exit_code
  if [ -z "$SRC_DATASET" ]; then
    log_error "Missing parameter -s | --source for sending dataset (source)."
    exit_code=$EXIT_MISSING_PARAM
  fi
  if [ -z "$DST_DATASET" ]; then
    log_error "Missing parameter -d | --dest for receiving dataset (destination)."
    exit_code=$EXIT_MISSING_PARAM
  fi

  if [ "$SRC_TYPE" == "$TYPE_SSH" ] && [ "$DST_TYPE" == "$TYPE_SSH" ]; then
    log_error "You can use type 'ssh' only for source or destination but not both."
    exit_code=$EXIT_INVALID_PARAM
  elif [ "$SRC_TYPE" == "$TYPE_SSH" ] || [ "$DST_TYPE" == "$TYPE_SSH" ]; then
    if [ -z "$SSH_HOST" ]; then
      log_error "Missing parameter --ssh_host for receiving host."
      exit_code=$EXIT_MISSING_PARAM
    fi
  fi

  if [ -z "$ID" ]; then
    ID="$($MD5SUM_CMD <<<"$DST_DATASET$SSH_HOST")"
    ID="${ID:0:$ID_LENGTH}"
  fi
  if ! [[ "$ID" =~ ^[a-zA-Z0-9]*$ ]]; then
    log_error "ID -i must only contain characters and numbers. You used '$ID'"
    exit_code=$EXIT_INVALID_PARAM
  fi

  if [ -n "$DST_PROP" ]; then
    IFS=',' read -ra DST_PROP_ARRAY <<<"$DST_PROP"
    unset IFS
  fi

  if [ -n "$exit_code" ]; then
    echo
    usage
    stop $exit_code
  fi

  log_debug "checking if source dataset '$SRC_DATASET' exists ..."
  if dataset_exists true; then
    log_debug "... '$SRC_DATASET' exits."
  else
    log_error "Source dataset '$SRC_DATASET' does not exists."
    dataset_list true
    stop $EXIT_ERROR
  fi

  log_debug "checking if source dataset '$SRC_DATASET' is encrypted ..."
  if dataset_encrypted true; then
    log_debug "... source is encrypted"
    SRC_ENCRYPTED=true
  else
    log_debug "... source is not encrypted"
  fi

  if [ "$SRC_ENCRYPTED" == "true" ] && [ "$SRC_DECRYPT" == true ] && [ "$RECURSIVE" == "true" ]; then
    log_error "Encrypted datasets can only be replicated using encrypted raw format."
    log_error "You cannot use '--recursive' and '--decrypt' together."
    stop $EXIT_INVALID_PARAM
  fi

  # bookmarks only make sense if snapshot count on source side is 1
  if [ "$SRC_COUNT" == "1" ]; then
    if [ "$BOOKMARK" == "true" ]; then
      log_debug "checking if pool of source '$SRC_DATASET' support bookmarks ..."
      if pool_support_bookmarks true; then
        log_debug "... bookmarks supported"
        BOOKMARK=true
      else
        log_debug "... bookmarks not supported"
        BOOKMARK=false
      fi
    fi
  elif [ "$BOOKMARK" == "true" ]; then
    log_warn "Bookmark option --bookmark will be ignored since you are using a snapshot count $SRC_COUNT which is greater then 1."
    BOOKMARK=false
  fi

  # if we passed basic validation we load snapshots to check if this is the first sync
  load_src_snapshots
  # if we already have a sync done skip destination checks
  if [ -z "$SRC_SNAPSHOT_LAST" ]; then
    FIRST_RUN=true
    log_debug "checking if destination dataset '$DST_DATASET' exists ..."
    if dataset_exists false; then
      log_debug "... '$DST_DATASET' exists."
      if [ "$SRC_ENCRYPTED" == "true" ]; then
        log_error "You cannot initially send an encrypted dataset into an existing one."
        stop $EXIT_ERROR
      fi
    else
      log_debug "... '$DST_DATASET' does not exist."
      if ! dataset_exists false "$(dataset_parent $DST_DATASET)"; then
        log_error "Parent dataset $(dataset_parent $DST_DATASET) does not exist."
        stop $EXIT_ERROR
      fi
      log_debug "checking if destination pool supports encryption ..."
      if pool_support_encryption false; then
        log_debug "... encryption supported"
      else
        log_debug "... encryption not supported"
        if [ "$SRC_ENCRYPTED" == "true" ]; then
          log_error "Source dataset '$SRC_DATASET' is encrypted but target pool does not support encryption."
          stop $EXIT_ERROR
        fi
      fi
    fi
  else
    # check if destination snapshot exists
    load_dst_snapshots
    if [ -z "$DST_SNAPSHOT_LAST" ]; then
      log_error "Destination does not have a snapshot but source does."
      if [ "$RESUME" == "true" ]; then
        log_info "Look if initial sync can be resumed ..."
        if [ "$(dataset_resume_token)" == "-" ]; then
          log_error "... no resume token found. Please delete all snapshots and start with full sync."
        fi
      else
        log_error "Either the initial sync did not work or we are out of sync."
        log_error "Please delete all snapshots and start with full sync."
        stop $EXIT_ERROR
      fi
    elif [ -z "$SRC_SNAPSHOT_LAST_SYNCED" ]; then
      log_error "Last destination snapshot $DST_SNAPSHOT_LAST is not present at source."
      log_error "We are out of sync."
      log_error "Please delete all snapshots on both sides and start with full sync."
      stop $EXIT_ERROR
    fi
  fi
}

function validate_restore() {
  local exit_code
  # these parameters are always false on restore
  RECURSIVE=false
  RESUME=false
  FIRST_RUN=false

  if [ -z "$SRC_DATASET" ]; then
    log_error "Missing parameter -s | --source for sending dataset (source)."
    exit_code=$EXIT_MISSING_PARAM
  fi
  if [ -z "$DST_DATASET" ]; then
    log_error "Missing parameter -d | --dest for receiving dataset (destination)."
    exit_code=$EXIT_MISSING_PARAM
  fi

  if [ "$SRC_TYPE" == "$TYPE_SSH" ] && [ "$DST_TYPE" == "$TYPE_SSH" ]; then
    log_error "You can use type 'ssh' only for source or destination but not both."
    exit_code=$EXIT_INVALID_PARAM
  elif [ "$SRC_TYPE" == "$TYPE_SSH" ] || [ "$DST_TYPE" == "$TYPE_SSH" ]; then
    if [ -z "$SSH_HOST" ]; then
      log_error "Missing parameter --ssh_host for receiving host."
      exit_code=$EXIT_MISSING_PARAM
    fi
  fi

  if [ -z "$ID" ]; then
    ID="$($MD5SUM_CMD <<<"$DST_DATASET$SSH_HOST")"
    ID="${ID:0:$ID_LENGTH}"
  fi
  if ! [[ "$ID" =~ ^[a-zA-Z0-9]*$ ]]; then
    log_error "ID -i must only contain characters and numbers. You used '$ID'"
    exit_code=$EXIT_INVALID_PARAM
  fi

  if [ -n "$DST_PROP" ]; then
    IFS=',' read -ra DST_PROP_ARRAY <<<"$DST_PROP"
    unset IFS
  fi

  if [ -n "$exit_code" ]; then
    echo
    usage
    stop $exit_code
  fi

  log_debug "checking if destination dataset '$DST_DATASET' exists ..."
  if dataset_exists false; then
    log_debug "... '$DST_DATASET' exists."
    log_debug "checking if destination dataset '$DST_DATASET' is encrypted ..."
    if dataset_encrypted false; then
      log_debug "... destination is encrypted"
      DST_ENCRYPTED=true
      log_debug "checking if source pool supports encryption ..."
      if pool_support_encryption true; then
        log_debug "... encryption supported on source side."
      else
        log_info "Destination dataset '$DST_DATASET' is encrypted but restore pool does not support encryption. Restore will be decrypted."
        DST_DECRYPT=true
      fi
    else
      log_debug "... destination is not encrypted"
    fi
  else
    log_error "Destination dataset '$DST_DATASET' does not exists."
    dataset_list false
    stop $EXIT_ERROR
  fi

  log_debug "checking if source dataset '$SRC_DATASET' exists ..."
  if dataset_exists true; then
    log_debug "checking if source dataset '$SRC_DATASET' is encrypted ..."
    if dataset_encrypted true; then
      log_debug "... source is encrypted"
      SRC_ENCRYPTED=true
    else
      log_debug "... source is not encrypted"
    fi
    if [ "$SRC_ENCRYPTED" == "true" ] || [ "$DST_ENCRYPTED" == "true" ]; then
      log_error "... $SRC_DATASET exists and source or destination are encrypted. A restore of encrypted data or to an encrypted existing dataset is not possible."
      stop $EXIT_ERROR
    elif [ "$RESTORE_DESTROY" == "true" ]; then
      log_info "... '$SRC_DATASET' exits and will be destroyed during restore."
      NO_OVERRIDE=false
    else
      log_error "... '$SRC_DATASET' exits no restore possible. Please destroy dataset or use --restore-destroy to override existing data."
      stop $EXIT_ERROR
    fi
  else
    log_info "... '$SRC_DATASET' does not exits."
    log_info "checking parent dataset '$(dataset_parent $SRC_DATASET)' ..."
    if dataset_exists true "$(dataset_parent $SRC_DATASET)"; then
      log_debug "Parent dataset $(dataset_parent $DST_DATASET) exist."
      if dataset_encrypted true "$(dataset_parent $SRC_DATASET)"; then
        log_debug "... parent dataset is encrypted."
        if [ "$DST_ENCRYPTED" == "true" ]; then
          log_info "... source and destination dataset are encrypted, we decrypt data during restore."
          DST_DECRYPT=true
        fi
      else
        log_debug "... parent dataset is not encrypted."
      fi
    else
      log_error "Parent dataset $(dataset_parent $SRC_DATASET) does not exist."
      stop $EXIT_ERROR
    fi
  fi

  # set source parameter to destination one for command build
  SRC_ENCRYPTED="$DST_ENCRYPTED"
  SRC_DECRYPT="$DST_DECRYPT"

  # check if destination snapshot exists
  load_dst_snapshots
  if [ -z "$DST_SNAPSHOT_LAST" ]; then
    log_error "Destination does not have a snapshot to restore."
    stop $EXIT_ERROR
  else
    log_info "Restore last destination snapshot '$DST_SNAPSHOT_LAST'."
  fi
}

function load_src_snapshots() {
  local pattern
  local escaped_src_dataset

  SRC_SNAPSHOTS=()
  SRC_SNAPSHOT_LAST=

  escaped_src_dataset="${SRC_DATASET//\//\\/}"
  # shellcheck disable=SC1087
  pattern="^$escaped_src_dataset[@#]${SNAPSHOT_PREFIX}_${ID}.*"
  log_debug "getting source snapshot and bookmark list ..."
  log_debug "... filter with pattern $pattern"
  for snap in $(dataset_list_snapshots_bookmarks true); do
    if [[ "$snap" =~ $pattern ]]; then
      SRC_SNAPSHOTS+=("$snap")
      log_debug "... add $snap"
    else
      log_debug "... $snap does not match pattern."
    fi
  done

  if [ ${#SRC_SNAPSHOTS[@]} -gt 0 ]; then
    SRC_SNAPSHOT_LAST=${SRC_SNAPSHOTS[*]: -1}
    log_debug "... found ${#SRC_SNAPSHOTS[@]} snapshots."
    log_debug "... last snapshot: $SRC_SNAPSHOT_LAST"
  else
    log_debug "... no snapshot found."
  fi
}

function load_dst_snapshots() {
  local pattern
  local escaped_dst_dataset
  local dst_name
  local src_name

  DST_SNAPSHOTS=()
  DST_SNAPSHOT_LAST=
  SRC_SNAPSHOT_LAST_SYNCED=

  escaped_dst_dataset="${DST_DATASET//\//\\/}"
  # shellcheck disable=SC1087
  pattern="^$escaped_dst_dataset[@#]${SNAPSHOT_PREFIX}_${ID}.*"
  log_debug "getting destination snapshot list ..."
  log_debug "... filter with pattern $pattern"
  for snap in $(dataset_list_snapshots false); do
    if [[ "$snap" =~ $pattern ]]; then
      log_debug "... add $snap"
      DST_SNAPSHOTS+=("$snap")
    else
      log_debug "... $snap does not match pattern."
    fi
  done

  if [ ${#DST_SNAPSHOTS[@]} -gt 0 ]; then
    DST_SNAPSHOT_LAST=${DST_SNAPSHOTS[*]: -1}
    log_debug "... found ${#DST_SNAPSHOTS[@]} snapshots."
    log_debug "... last snapshot: $DST_SNAPSHOT_LAST"
    dst_name="$(snapshot_name $DST_DATASET $DST_SNAPSHOT_LAST)"
    for snap in "${SRC_SNAPSHOTS[@]}"; do
      src_name="$(snapshot_name $SRC_DATASET $snap)"
      if [ "$src_name" == "$dst_name" ]; then
        SRC_SNAPSHOT_LAST_SYNCED=$snap
      fi
    done
    log_debug "... last synced snapshot: $SRC_SNAPSHOT_LAST_SYNCED"
  else
    log_debug "... no snapshot found."
  fi
}

function do_backup() {
  local cmd

  # looking for resume token and resume previous aborted sync if necessary
  if [ "$FIRST_RUN" == "false" ] && [ "$RESUME" == "true" ]; then
    log_info "Looking for resume token ..."
    local resume_token
    resume_token=$(dataset_resume_token)
    if [ "$resume_token" != "-" ]; then
      log_info "... resuming previous aborted sync with token '${resume_token:0:20}' ..."
      cmd="$(build_cmd "$SRC_TYPE" "$(zfs_resume_send_cmd "$ZFS_CMD" "$resume_token")") | $(build_cmd "$DST_TYPE" "$(zfs_snapshot_receive_cmd "$ZFS_CMD_REMOTE" "$DST_DATASET" "true")")"
      if execute "$cmd"; then
        log_info "... finished previous sync."
        # reload destination snapshots to get last
        load_dst_snapshots
        # put hold on destination snapshot
        execute_snapshot_hold false "$DST_SNAPSHOT_LAST"
        log_info "Continue with new sync ..."
      else
        log_error "Error resuming previous aborted sync."
        stop $EXIT_ERROR
      fi
    else
      log_info "... no sync to resume."
    fi
  fi

  # create snapshot
  if [ -n "$PRE_SNAPSHOT" ]; then
    if ! execute "$PRE_SNAPSHOT"; then
      log_error "Error executing pre snapshot command/script ..."
      stop $EXIT_ERROR
    fi
  fi
  cmd="$(build_cmd "$SRC_TYPE" "$(zfs_snapshot_create_cmd "$ZFS_CMD" "$SRC_DATASET")")"
  log_info "Creating new snapshot for sync ..."
  if ! execute "$cmd"; then
    log_error "Error creating new snapshot."
    [ "$FIRST_RUN" == "true" ] && help_permissions_send
    stop $EXIT_ERROR
  fi
  if [ -n "$POST_SNAPSHOT" ]; then
    if ! execute "$POST_SNAPSHOT"; then
      log_error "Error executing post snapshot command/script ..."
      EXECUTION_ERROR=true
    fi
  fi
  # reload source snapshots to get last
  load_src_snapshots

  if [ -z "$SRC_SNAPSHOT_LAST" ]; then
    log_error "No snapshot found."
    if [ "$DRYRUN" == "true" ]; then
      log_info "dryrun using dummy snapshot '$SRC_DATASET@dryrun_snapshot_$(date_text)' ..."
      SRC_SNAPSHOT_LAST="$SRC_DATASET@dryrun_snapshot_$(date_text)"
    else
      stop $EXIT_ERROR
    fi
  fi

  # put hold on source snapshot
  if [ "$NO_HOLD" = "false" ] && [ "$BOOKMARK" == "false" ]; then
    execute_snapshot_hold true "$SRC_SNAPSHOT_LAST"
  fi

  if [ -z "$SRC_SNAPSHOT_LAST_SYNCED" ]; then
    log_info "No synced snapshot or bookmark found."
    log_info "Using newest snapshot '$SRC_SNAPSHOT_LAST' for initial sync ..."
  else
    log_info "Using last synced snapshot '$SRC_SNAPSHOT_LAST_SYNCED' for incremental sync ..."
  fi

  # sending snapshot
  log_info "sending snapshot ..."
  cmd="$(build_cmd "$SRC_TYPE" "$(zfs_snapshot_send_cmd "$ZFS_CMD" "$SRC_SNAPSHOT_LAST_SYNCED" "$SRC_SNAPSHOT_LAST")") | $(build_cmd "$DST_TYPE" "$(zfs_snapshot_receive_cmd "$ZFS_CMD_REMOTE" "$DST_DATASET")")"
  if execute "$cmd"; then
    if [ "$FIRST_RUN" == "true" ]; then
      [ -n "$DST_PROP" ] && log_info "setting properties at destination ... "
      for prop in "${DST_PROP_ARRAY[@]}"; do
        if [[ "$prop" =~ .*inherit$ ]]; then
          cmd="$(build_cmd "$DST_TYPE" "$(zfs_inherit_cmd "$ZFS_CMD_REMOTE" "${prop/=inherit/}" "$DST_DATASET")")"
          if execute "$cmd"; then
            log_debug "Property ${prop/=inherit/} inherited on destination dataset $DST_DATASET."
          else
            log_error "Error setting property $prop on destination dataset $DST_DATASET."
            EXECUTION_ERROR=true
          fi
        else
          cmd="$(build_cmd "$DST_TYPE" "$(zfs_set_cmd "$ZFS_CMD_REMOTE" "$prop" "$DST_DATASET")")"
          if execute "$cmd"; then
            log_debug "Property $prop set on destination dataset $DST_DATASET."
          else
            log_error "Error setting property $prop on destination dataset $DST_DATASET."
            EXECUTION_ERROR=true
          fi
        fi
      done
    fi
    # reload destination snapshots to get last
    load_dst_snapshots

    # put hold on destination snapshot
    execute_snapshot_hold false "$DST_SNAPSHOT_LAST"

    # convert snapshot to bookmark
    if [ "$BOOKMARK" == "true" ]; then
      log_info "converting snapshot '$SRC_SNAPSHOT_LAST' to bookmark ..."
      cmd="$(build_cmd "$SRC_TYPE" "$(zfs_bookmark_create_cmd $ZFS_CMD "$SRC_SNAPSHOT_LAST")")"
      if execute "$cmd"; then
        execute_snapshot_destroy true "$SRC_SNAPSHOT_LAST"
      else
        log_error "Error converting snapshot to bookmark."
        EXECUTION_ERROR=true
      fi
    fi
  else
    log_error "Error sending snapshot."
    [ "$FIRST_RUN" == "true" ] && help_permissions_receive
    if [ "$INTERMEDIATE" == "true" ] || [ "$RESUME" == "true" ]; then
      log_info "Keeping unsent snapshot $SRC_SNAPSHOT_LAST for later send."
    else
      log_info "Destroying unsent snapshot $SRC_SNAPSHOT_LAST ..."
      if [ "$NO_HOLD" = "false" ]; then
        execute_snapshot_release true "$SRC_SNAPSHOT_LAST"
      fi
      execute_snapshot_destroy true "$SRC_SNAPSHOT_LAST"
    fi
    stop $EXIT_ERROR
  fi

  # cleanup successfully send snapshots on both sides
  load_src_snapshots
  if [ ${#SRC_SNAPSHOTS[@]} -gt "$SRC_COUNT" ]; then
    log_info "Destroying old source snapshots ..."
    for snap in "${SRC_SNAPSHOTS[@]::${#SRC_SNAPSHOTS[@]}-$SRC_COUNT}"; do
      if [[ "$snap" =~ @ ]]; then
        if [ "$NO_HOLD" = "false" ]; then
          execute_snapshot_release true "$snap"
        fi
        execute_snapshot_destroy true "$snap"
      else
        execute_bookmark_destroy true "$snap"
      fi
    done
  fi

  if [ ${#DST_SNAPSHOTS[@]} -gt "$DST_COUNT" ]; then
    log_info "Destroying old destination snapshots ..."
    for snap in "${DST_SNAPSHOTS[@]::${#DST_SNAPSHOTS[@]}-$DST_COUNT}"; do
      if [ "$NO_HOLD" = "false" ]; then
        execute_snapshot_release false "$snap"
      fi
      execute_snapshot_destroy false "$snap"
    done
  fi

  if [ "$EXECUTION_ERROR" == "true" ]; then
    log_error "... zfs-backup finished with errors."
    stop $EXIT_WARN
  else
    log_info "... zfs-backup finished successful."
    stop $EXIT_OK
  fi
}

function do_restore() {
  local cmd
  # sending snapshot
  log_info "restoring snapshot '$DST_SNAPSHOT_LAST' to '$SRC_DATASET' ..."
  cmd="$(build_cmd "$DST_TYPE" "$(zfs_snapshot_send_cmd "$ZFS_CMD_REMOTE" "" "$DST_SNAPSHOT_LAST")") | $(build_cmd "$SRC_TYPE" "$(zfs_snapshot_receive_cmd "$ZFS_CMD" "$SRC_DATASET")")"
  if execute "$cmd"; then
    log_info "... finished restore of snapshot '$DST_SNAPSHOT_LAST' to '$SRC_DATASET'."
    log_info "... zfs-backup finished successful."
  else
    log_error "Error restoring snapshot."
    stop $EXIT_ERROR
  fi
}

function create_config() {
  local config
  config="#######
## Config generated by zfs-backup $VERSION at $(date +"$LOG_DATE_PATTERN")
#######

## ZFS commands
# The script is trying to find the right path
# but you can set it if it fails
ZFS_CMD=$ZFS_CMD
ZPOOL_CMD=$ZPOOL_CMD
SSH_CMD=$SSH_CMD
MD5SUM_CMD=$MD5SUM_CMD
ZFS_CMD_REMOTE=$ZFS_CMD_REMOTE
ZPOOL_CMD_REMOTE=$ZFS_CMD_REMOTE

# Unique id of target system for example 'nas' of 'home'
# This id is used to separate backups of the same source
# to multiple targets.
# If this is not set the id is auto generated to the
# md5sum of destination dataset and ssh host (if present).
# Use only A-Za-z0-9 and maximum of $ID_LENGTH characters.
ID=\"$ID\"

## Source dataset options
# $SRC_DATASET_HELP
SRC_DATASET=\"$SRC_DATASET\"
# $SRC_TYPE_HELP
SRC_TYPE=$SRC_TYPE
# ${DECRYPT_HElP[0]}
# ${DECRYPT_HElP[1]}
SRC_DECRYPT=$SRC_DECRYPT
# $SRC_COUNT_HELP
SRC_COUNT=$SRC_COUNT

## Destination dataset options
# $DST_DATASET_HELP
DST_DATASET=\"$DST_DATASET\"
# $DST_TYPE_HELP
DST_TYPE=$DST_TYPE
# $DST_COUNT_HELP
DST_COUNT=$DST_COUNT
# ${DST_PROP_HELP[0]}
# ${DST_PROP_HELP[1]}
# ${DST_PROP_HELP[2]}
DST_PROP=$DST_PROP

# Snapshot pre-/postfix and hold tag
#SNAPSHOT_PREFIX=\"bkp\"
#SNAPSHOT_HOLD_TAG=\"zfsbackup\"

## SSH parameter
# $SSH_HOST_HELP
SSH_HOST=\"$SSH_HOST\"
# $SSH_PORT_HELP
SSH_PORT=\"$SSH_PORT\"
# $SSH_USER_HELP
SSH_USER=\"$SSH_USER\"
# $SSH_KEY_HELP
SSH_KEY=\"$SSH_KEY\"
# $SSH_OPT_HELP
# SSH_OPT=\"-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new\"
SSH_OPT=\"$SSH_OPT\"

# Backup style configuration
# $BOOKMARK_HELP
BOOKMARK=$BOOKMARK
# $RESUME_HELP
RESUME=$RESUME
# ${INTERMEDIATE_HElP[0]}
# ${INTERMEDIATE_HElP[1]}
INTERMEDIATE=$INTERMEDIATE
# $MOUNT_HELP
MOUNT=$MOUNT
# ${NO_OVERRIDE_HElP[0]}
# ${NO_OVERRIDE_HElP[1]}
NO_OVERRIDE=$NO_OVERRIDE
# $NO_HOLD_HELP
NO_HOLD=$NO_HOLD
# $DEBUG_HELP
DEBUG=$DEBUG

# $SEND_PARAMETER_HELP
SEND_PARAMETER=\"$SEND_PARAMETER\"
# $RECEIVE_PARAMETER_HELP
RECEIVE_PARAMETER=\"$RECEIVE_PARAMETER\"

## Scripts and commands
# ${ONLY_IF_HELP[0]}
# ${ONLY_IF_HELP[1]}
# ${ONLY_IF_HELP[3]}
# ${ONLY_IF_HELP[4]}
ONLY_IF=\"$ONLY_IF\"
# $PRE_RUN_HELP
PRE_RUN=\"$PRE_RUN\"
# $POST_RUN_HELP
POST_RUN=\"$POST_RUN\"
# $PRE_SNAPSHOT_HELP
PRE_SNAPSHOT=\"$PRE_SNAPSHOT\"
# $POST_SNAPSHOT_HELP
POST_SNAPSHOT=\"$POST_SNAPSHOT\"

# Logging options
#LOG_FILE=
#LOG_DATE_PATTERN=\"%Y-%m-%d - %H:%M:%S\"
#LOG_DEBUG=\"[DEBUG]\"
#LOG_INFO=\"[INFO]\"
#LOG_WARN=\"[WARN]\"
#LOG_ERROR=\"[ERROR]\"
#LOG_CMD=\"[COMMAND]\"
"
  if [ -n "$CONFIG_FILE" ]; then
    echo "$config" >$CONFIG_FILE
    echo "Configuration was written to $CONFIG_FILE."
  else
    echo "$config"
  fi
}

function start_backup() {
  log_info "Starting zfs-backup ..."
  if [ -n "$ONLY_IF" ]; then
    log_debug "check if backup should be done ..."
    if execute "$ONLY_IF" "false"; then
      log_debug "... pre condition are met, continue."
    else
      log_error "... pre conditions are not met, abort backup."
      exit $EXIT_OK
    fi
  fi
  if [ -n "$PRE_RUN" ]; then
    log_debug "executing pre run script ..."
    if execute "$PRE_RUN" "false"; then
      log_debug "... done"
    else
      log_error "Error executing pre run script, abort backup."
      exit $EXIT_ERROR
    fi
  fi
}

# $1 exit code
function stop() {
  if [ -n "$POST_RUN" ]; then
    log_debug "executing post run script ..."
    if execute "$POST_RUN" "false"; then
      log_debug "... done"
    else
      log_error "Error executing post run script, abort backup."
    fi
  fi
  exit $1
}

# main function calls
load_parameter "$@"
load_config
load_parameter "$@"
start_backup
distro_dependent_commands
if [ "$RESTORE" == "true" ]; then
  validate_restore
  do_restore
else
  validate_backup
  if [ "$MAKE_CONFIG" == "true" ]; then
    create_config
  else
    do_backup
  fi
fi

