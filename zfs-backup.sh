#!/bin/bash
# shellcheck disable=SC2091
# shellcheck disable=SC2086

readonly VERSION='0.0.1'

# return codes
readonly EXIT_OK=0
readonly EXIT_ERROR=1
readonly EXIT_MISSING_PARAM=2
readonly EXIT_INVALID_PARAM=3

# ZFS commands
# we try to autodetect but in case these variables can be set
ZFS_CMD=
ZPOOL_CMD=
SSH_CMD=
MD5SUM_CMD=
ZFS_CMD_REMOTE=
ZPOOL_CMD_REMOTE=

# defaults
CONFIG_FILE=./zfs-backup.config
LOG_FILE=
LOG_DATE_PATTERN="%Y-%m-%d - %H:%M:%S"
LOG_DEBUG="[DEBUG]"
LOG_INFO="[INFO]"
LOG_WARN="[WARN]"
LOG_ERROR="[ERROR]"
LOG_CMD="[COMMAND]"
DEBUG=false
DRYRUN=false
SNAPSHOT_PREFIX="bkp"
SNAPSHOT_HOLD_TAG="zfsbackup"
SNAPSHOT_SYNCED_POSTFIX="synced"

ID=
readonly ID_LENGTH=10
readonly TYPE_LOCAL=local
readonly TYPE_SSH=ssh

# datasets
SRC_DATASET=
SRC_TYPE=$TYPE_LOCAL
SRC_ENCRYPTED=false
SRC_DECRYPT=false
SRC_COUNT=1
SRC_SNAPSHOTS=()
SRC_SNAPSHOTS_SYNCED=()
SRC_SNAPSHOT_LAST=
SRC_SNAPSHOT_LAST_SYNCED=

DST_DATASET=
DST_TYPE=$TYPE_LOCAL
DST_EXITS=false
DST_COUNT=1
DST_SNAPSHOTS=()
DST_SNAPSHOT_LAST=

# boolean options
RECURSIVE=false
RESUME=false
INTERMEDIATE=false
MOUNT=false
BOOKMARK=false
NO_OVERRIDE=false
NO_HOLD=false

# parameter
DEFAULT_SEND_PARAMETER="-Lec"
SEND_PARAMETER=
RECEIVE_PARAMETER=

# ssh parameter
SSH_HOST=
SSH_PORT=22
SSH_USER=
SSH_KEY=
SSH_OPT="-o ConnectTimeout=10"
#SSH_OPT="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

FIRST_RUN=false

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
Config
------
  -c,  --config [file]     Config file to load parameter from (default: $CONFIG_FILE).
  -v,  --verbose           Print executed commands and other debugging information.
  --dryrun                 Do check inputs, dataset existence,... but do not create or destroy snapshot or transfer data.
  --version                Print version.

Options
-------
  -s,  --src       [name]        Name of the sending dataset (source).
  -st, --src-type  [ssh|local]   Type of source dataset (default: local)
  -ss, --src-snaps [count]       Number (greater 0) of successful sent snapshots to keep on source side (default: 1).
  -d,  --dst       [name]        Name of the receiving dataset (destination).
  -dt, --dst-type  [ssh|local]   Type of destination dataset (default: 'local').
  -ds, --dst-snaps [count]       Number (greater 0) of successful received snapshots to keep on destination side (default: 1).
  -i,  --id        [name]        Unique ID of backup destination (default: md5sum of destination dataset and ssh host, if present).
                                 Required if you use multiple destinations to identify snapshots.
                                 Maximum of $ID_LENGTH characters or numbers.
  --send-param     [parameters]  Parameters used for 'zfs send' command. If set these parameters are use and all other
                                 settings (see below) are ignored.
  --recv-param     [parameters]  Parameters used for 'zfs receive' command. If set these parameters are use and all other
                                 settings (see below) are ignored.
  --bookmark                     Use bookmark (if supported) instead of snapshot on source dataset.
                                 Ignored if '-ss, --src-count' is greater 1.
  --resume                       Make sync resume able and resume interrupted streams. User '-s' option during receive.
  --intermediary                 Use '-I' instead of '-i' while sending to keep intermediary snapshots.
                                 If set created but not send snapshots are kept, otherwise the are deleted.
  --mount                        Try to mount received dataset on destination. Option '-u' is NOT used during receive.
  --no-override                  By default option '-F' is used during receive to discard changes made in destination dataset.
                                 If you use this option receive will fail if destination was changed.
  --decrypt                      By default encrypted source datasets are send in raw format using send option '-w'.
                                 This options disables that and sends encrypted (mounted) datasets in plain.
  --no-holds                     Do not put hold tag on snapshots created by this tool.

Types:
------
  'local'                       Local dataset.
  'ssh'                         Traffic is streamed from/to ssh. Only source or destination can use ssh, other need to be local.

SSH Options
-----------
If you use type 'ssh' you need to specify Host, Port, etc.
 --ssh_host [hostname]          Host to connect to.
 --ssh_port [port]              Port to use (default: 22).
 --ssh_user [port]              User used for connection. If not set current user is used.
 --ssh_key  [keyfile]           Key to use for connection. If not set default key is used.
 --ssh_opt  [options]           Options used for connection (i.e: '-oStrictHostKeyChecking=accept-new').

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
  log_debug "$(build_cmd "$SRC_TYPE" "zfs allow -u $current_user send,snapshot,hold $SRC_DATASET")"
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
  log_debug "$(build_cmd "$DST_TYPE" "zfs allow -u $current_user compression,mountpoint,create,mount,receive $DST_DATASET")"
}

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
  --SSH_KEY)
    SSH_HOST="$2"
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
  log "executing: '$1'" "$LOG_CMD"
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
  if [ -f "$CONFIG_FILE" ]; then
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
    exit $EXIT_ERROR
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
function zfs_snapshot_rename_cmd() {
  if [ "$RECURSIVE" == "true" ]; then
    echo "$1 rename -r $2 ${2}_$SNAPSHOT_SYNCED_POSTFIX"
  else
    echo "$1 rename $2 ${2}_$SNAPSHOT_SYNCED_POSTFIX"
  fi
}

# command used to destroy a snapshot
# $1 zfs command
# $2 snapshot name
function zfs_snapshot_destroy_cmd() {
  if [ "$RECURSIVE" == "true" ]; then
    echo "$1 destroy -r $2"
  else
    echo "$1 destroy $2"
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
    if [ "$FIRST_RUN" == "true" ]; then
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
# $2 snapshot name
# $3 is resume
function zfs_snapshot_receive_cmd() {
  local cmd
  cmd="$1 receive"
  if [ -n "$RECEIVE_PARAMETER" ]; then
    cmd="$cmd $RECEIVE_PARAMETER"
  else
    if [ "$RESUME" == "true" ]; then
      cmd="$cmd -s"
    fi
    if [ "$MOUNT" == "false" ]; then
      cmd="$cmd -u"
    fi
    if [ "$FIRST_RUN" == "true" ] && [ "$DST_EXITS" == "false " ]; then
      cmd="$cmd -o readonly=on -o canmount=off"
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
function dataset_encrypted() {
  local cmd
  if [ "$1" == "true" ]; then
    cmd="$(build_cmd "$SRC_TYPE" "$(zfs_encryption_cmd $ZFS_CMD "$SRC_DATASET")")"
  else
    cmd="$(build_cmd "$DST_TYPE" "$(zfs_encryption_cmd $ZFS_CMD_REMOTE "$DST_DATASET")")"
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

function distro_dependent_commands() {
  local cmd
  local path
  local zfs_path
  local distro
  local release

  if [[ -z "$ZFS_CMD" || -z "$ZPOOL_CMD" || (-z "$MD5SUM_CMD" && -z "$ID") || (-z "$SSH_CMD" && "$SRC_TYPE" == "$TYPE_SSH") ]]; then
    distro=$($(build_cmd "$SRC_TYPE" "lsb_release --id --short"))
    case $distro in
    Ubuntu)
      release=$($(build_cmd "$SRC_TYPE" "lsb_release --release --short"))
      if [[ "${release:0:2}" -gt 19 ]]; then
        zfs_path="/usr/sbin/"
        path="/usr/bin/"
      else
        zfs_path="/sbin/"
        path="/usr/bin/"
      fi
      ;;
    Linuxmint)
      zfs_path="/sbin/"
      path="/usr/bin/"
      ;;
    *)
      zfs_path="/sbin/"
      path="/usr/bin/"
      ;;
    esac

    [ -z "$ZFS_CMD" ] && ZFS_CMD="${zfs_path}zfs"
    [ -z "$ZPOOL_CMD" ] && ZPOOL_CMD="${zfs_path}zpool"
    [ -z "$SSH_CMD" ] && SSH_CMD="${path}ssh"
    [ -z "$MD5SUM_CMD" ] && MD5SUM_CMD="${path}md5sum"
  fi

  if [[ -z "$ZFS_CMD_REMOTE" || -z "$ZPOOL_CMD_REMOTE" || (-z "$SSH_CMD" && "$DST_TYPE" == "$TYPE_SSH") ]]; then
    distro=$($(build_cmd "$DST_TYPE" "lsb_release --id --short"))
    case $distro in
    Ubuntu)
      release=$($(build_cmd "$DST_TYPE" "lsb_release --release --short"))
      if [[ "${release:0:2}" -gt 19 ]]; then
        zfs_path="/usr/sbin/"
        path="/usr/bin/"
      else
        zfs_path="/sbin/"
        path="/usr/bin/"
      fi
      ;;
    Linuxmint)
      zfs_path="/sbin/"
      path="/usr/bin/"
      ;;
    *)
      path=""
      ;;
    esac

    [ -z "$ZFS_CMD_REMOTE" ] && ZFS_CMD_REMOTE="${zfs_path}zfs"
    [ -z "$ZPOOL_CMD_REMOTE" ] && ZPOOL_CMD_REMOTE="${zfs_path}zpool"
    [ -z "$SSH_CMD" ] && SSH_CMD="${path}ssh"
  fi
}

function validate() {
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

  if [ -n "$exit_code" ]; then
    echo
    usage
    exit $exit_code
  fi

  log_debug "checking if source dataset '$SRC_DATASET' exists ..."
  if dataset_exists true; then
    log_debug "... exits."
  else
    log_error "Source dataset '$SRC_DATASET' does not exists."
    dataset_list true
    exit $EXIT_ERROR
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
    exit $EXIT_INVALID_PARAM
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
  else
    log_warn "Bookmark option --bookmark will be ignored since you are using a snapshot count $SRC_COUNT which is greater then 1."
    BOOKMARK=false
  fi

  # if we passed basic validation we load snapshots to check if this is the first sync
  load_src_snapshots
  # if we already have a sync done skip destination checks
  if [ -z "$SRC_SNAPSHOT_LAST_SYNCED" ]; then
    FIRST_RUN=true
    log_debug "checking if destination dataset '$DST_DATASET' exists ..."
    if dataset_exists false; then
      DST_EXITS=true
      log_debug "... '$DST_DATASET' exists."
      if [ "$SRC_ENCRYPTED" == "true" ]; then
        log_error "You cannot initially send an encrypted dataset into an existing one."
        exit $EXIT_ERROR
      fi
    else
      DST_EXITS=false
      if ! dataset_exists false "$(dataset_parent $DST_DATASET)"; then
        log_error "Parent dataset $(dataset_parent $DST_DATASET) does not exist."
        exit $EXIT_ERROR
      fi
      log_debug "checking if destination pool supports encryption ..."
      if pool_support_encryption false; then
        log_debug "... encryption supported"
      else
        log_debug "... encryption not supported"
        if [ "$SRC_ENCRYPTED" == "true" ]; then
          log_error "Source dataset '$SRC_DATASET' is encrypted but target pool does not support encryption."
          exit $EXIT_ERROR
        fi
      fi
    fi
  else
    # check if destination snapshot exists
    load_dst_snapshots
    if [ -z "$DST_SNAPSHOT_LAST" ] || [ "$(snapshot_name $SRC_DATASET $SRC_SNAPSHOT_LAST_SYNCED)" != "$(snapshot_name $DST_DATASET "${DST_SNAPSHOT_LAST}_${SNAPSHOT_SYNCED_POSTFIX}")" ]; then
      log_error "Synced snapshot '$SRC_SNAPSHOT_LAST_SYNCED' exists but destination has no corresponding snapshot."
      log_error "We are out of sync, please delete all source and destination snapshots and start over."
      exit $EXIT_ERROR
    fi
  fi
}

function load_src_snapshots() {
  local pattern
  local pattern_synced
  local escaped_src_dataset

  SRC_SNAPSHOTS=()
  SRC_SNAPSHOTS_SYNCED=()
  SRC_SNAPSHOT_LAST=
  SRC_SNAPSHOT_LAST_SYNCED=

  escaped_src_dataset="${SRC_DATASET//\//\\/}"
  # shellcheck disable=SC1087
  pattern="^$escaped_src_dataset[@#]${SNAPSHOT_PREFIX}_${ID}.*"
  # shellcheck disable=SC1087
  pattern_synced="^$escaped_src_dataset[@#]${SNAPSHOT_PREFIX}_${ID}.*${SNAPSHOT_SYNCED_POSTFIX}"
  if [ "$BOOKMARK" == "true" ]; then
    log_debug "getting source snapshot and bookmark list ..."
    for snap in $(dataset_list_snapshots_bookmarks true); do
      if [[ "$snap" =~ $pattern_synced ]]; then
        SRC_SNAPSHOTS_SYNCED+=("$snap")
      elif [[ "$snap" =~ $pattern ]]; then
        SRC_SNAPSHOTS+=("$snap")
      fi
    done
  else
    log_debug "getting source snapshot list ..."
    for snap in $(dataset_list_snapshots true); do
      if [[ "$snap" =~ $pattern_synced ]]; then
        SRC_SNAPSHOTS_SYNCED+=("$snap")
      elif [[ "$snap" =~ $pattern ]]; then
        SRC_SNAPSHOTS+=("$snap")
      fi
    done
  fi

  if [ ${#SRC_SNAPSHOTS[@]} -gt 0 ]; then
    SRC_SNAPSHOT_LAST=${SRC_SNAPSHOTS[*]: -1}
  fi

  if [ ${#SRC_SNAPSHOTS_SYNCED[@]} -gt 0 ]; then
    SRC_SNAPSHOT_LAST_SYNCED=${SRC_SNAPSHOTS_SYNCED[*]: -1}
  fi
}

function load_dst_snapshots() {
  local pattern
  local escaped_dst_dataset

  DST_SNAPSHOTS=()
  DST_SNAPSHOT_LAST=

  escaped_dst_dataset="${DST_DATASET//\//\\/}"
  # shellcheck disable=SC1087
  pattern="^$escaped_dst_dataset[@#]${SNAPSHOT_PREFIX}_${ID}.*"
  log_debug "getting destination snapshot list ..."
  for snap in $(dataset_list_snapshots false); do
    if [[ "$snap" =~ $pattern ]]; then
      DST_SNAPSHOTS+=("$snap")
    fi
  done

  if [ ${#DST_SNAPSHOTS[@]} -gt 0 ]; then
    DST_SNAPSHOT_LAST=${DST_SNAPSHOTS[*]: -1}
  fi
}

function do_backup() {
  local error
  local cmd

  if [ "$FIRST_RUN" == "false" ] && [ "$RESUME" == "true" ]; then
    log_info "Looking for resume token ..."
    local resume_token
    resume_token=$(dataset_resume_token)
    if [ "$resume_token" != "-" ]; then
      log_info "... resuming previous aborted sync with token '${resume_token:0:20}' ..."
      cmd="$(build_cmd "$SRC_TYPE" "$(zfs_resume_send_cmd "$ZFS_CMD" "$resume_token")") | $(build_cmd "$DST_TYPE" "$(zfs_snapshot_receive_cmd "$ZFS_CMD_REMOTE" "$DST_DATASET" "true")")"
      if execute "$cmd"; then
        log_info "... finished previous sync."
        # renaming successfully resumed snapshot
        log_info "renaming resumed snapshot ..."
        cmd="$(build_cmd "$SRC_TYPE" "$(zfs_snapshot_rename_cmd $ZFS_CMD "$SRC_SNAPSHOT_LAST")")"
        if ! execute "$cmd"; then
          log_error "Error renaming snapshot."
          log_error "You need to rename the snapshot from $SRC_SNAPSHOT_LAST to ${SRC_SNAPSHOT_LAST}_$SNAPSHOT_SYNCED_POSTFIX by yourself otherwise this snapshot stays forever."
        fi
        # reload destination snapshots to get last
        load_dst_snapshots

        # put hold on destination snapshot
        log_info "hold snapshot $DST_SNAPSHOT_LAST ..."
        cmd=$(build_cmd $DST_TYPE "$(zfs_snapshot_hold_cmd $ZFS_CMD_REMOTE "$DST_SNAPSHOT_LAST")")
        if ! execute "$cmd"; then
          log_error "Error hold snapshot $DST_SNAPSHOT_LAST."
          error=true
        fi
        log_info "Continue with new sync ..."
      else
        log_error "Error resuming previous aborted sync."
        exit $EXIT_ERROR
      fi
    else
      log_info "... no sync to resume."
    fi
  fi

  cmd="$(build_cmd "$SRC_TYPE" "$(zfs_snapshot_create_cmd "$ZFS_CMD" "$SRC_DATASET")")"
  log_info "Creating new snapshot for sync ..."
  if ! execute "$cmd"; then
    log_error "Error creating new snapshot."
    [ "$FIRST_RUN" == "true" ] && help_permissions_send
    exit $EXIT_ERROR
  fi

  load_src_snapshots

  if [ -z "$SRC_SNAPSHOT_LAST" ]; then
    log_error "No snapshot found."
    exit $EXIT_ERROR
  fi

  # put hold on source snapshot
  if [ "$NO_HOLD" = "false" ] && [ "$BOOKMARK" == "false" ]; then
    log_info "hold snapshot $snap ..."
    cmd=$(build_cmd $SRC_TYPE "$(zfs_snapshot_hold_cmd $ZFS_CMD "$SRC_SNAPSHOT_LAST")")
    if ! execute "$cmd"; then
      log_error "Error hold snapshot $snap."
      error=true
    fi
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
    # reload destination snapshots to get last
    load_dst_snapshots

    # put hold on destination snapshot
    log_info "hold snapshot $DST_SNAPSHOT_LAST ..."
    cmd=$(build_cmd $DST_TYPE "$(zfs_snapshot_hold_cmd $ZFS_CMD_REMOTE "$DST_SNAPSHOT_LAST")")
    if ! execute "$cmd"; then
      log_error "Error hold snapshot $DST_SNAPSHOT_LAST."
      error=true
    fi

    # renaming successfully sent snapshot
    log_info "renaming snapshot ..."
    cmd="$(build_cmd "$SRC_TYPE" "$(zfs_snapshot_rename_cmd $ZFS_CMD "$SRC_SNAPSHOT_LAST")")"
    if execute "$cmd"; then
      SRC_SNAPSHOT_LAST="${SRC_SNAPSHOT_LAST}_$SNAPSHOT_SYNCED_POSTFIX"
    else
      log_error "Error renaming snapshot."
      log_error "You need to rename the snapshot from $SRC_SNAPSHOT_LAST to ${SRC_SNAPSHOT_LAST}_$SNAPSHOT_SYNCED_POSTFIX by yourself to allow incremental backups again."
      exit $EXIT_ERROR
    fi

    # convert snapshot to bookmark
    if [ "$BOOKMARK" == "true" ]; then
      log_info "converting snapshot '$SRC_SNAPSHOT_LAST' to bookmark ..."
      cmd="$(build_cmd "$SRC_TYPE" "$(zfs_bookmark_create_cmd $ZFS_CMD "$SRC_SNAPSHOT_LAST")")"
      if execute "$cmd"; then
        log_info "destroying snapshot '$SRC_SNAPSHOT_LAST' ..."
        cmd="$(build_cmd "$SRC_TYPE" "$(zfs_snapshot_destroy_cmd $ZFS_CMD "$SRC_SNAPSHOT_LAST")")"
        if ! execute "$cmd"; then
          log_error "Error destroying bookmarked snapshot '$SRC_SNAPSHOT_LAST'."
          error=true
        fi
      else
        log_error "Error converting snapshot to bookmark."
        error=true
      fi
    fi
  else
    log_error "Error sending snapshot."
    [ "$FIRST_RUN" == "true" ] && help_permissions_receive
    if [ "$INTERMEDIATE" == "true" ]; then
      log_info "Keeping unsent snapshot $SRC_SNAPSHOT_LAST for later send."
    else
      log_info "Destroying unsent snapshot $SRC_SNAPSHOT_LAST ..."
      cmd="$(build_cmd "$SRC_TYPE" "$(zfs_snapshot_destroy_cmd $ZFS_CMD "$SRC_SNAPSHOT_LAST")")"
      if execute "$cmd"; then
        log_info "... snapshot destroyed."
      else
        log_error "Error destroying snapshot $SRC_SNAPSHOT_LAST"
      fi
    fi
    error=true
  fi

  if [ "$error" == "true" ]; then
    exit $EXIT_ERROR
  fi

  # cleanup successfully send snapshots on both sides
  load_src_snapshots
  if [ ${#SRC_SNAPSHOTS_SYNCED[@]} -gt "$SRC_COUNT" ]; then
    log_info "Deleting old source snapshots ..."
    for snap in "${SRC_SNAPSHOTS_SYNCED[@]::${#SRC_SNAPSHOTS_SYNCED[@]}-$SRC_COUNT}"; do
      if [[ "$snap" =~ @ ]]; then
        if [ "$NO_HOLD" = "false" ]; then
          log_info "... release snapshot $snap"
          cmd=$(build_cmd $SRC_TYPE "$(zfs_snapshot_release_cmd $ZFS_CMD "$snap")")
          if ! execute "$cmd"; then
            log_error "Error releasing snapshot $snap."
            error=true
          fi
        fi
        log_info "... deleting snapshot $snap"
        cmd=$(build_cmd $SRC_TYPE "$(zfs_snapshot_destroy_cmd $ZFS_CMD "$snap")")
      else
        log_info "... deleting bookmark $snap"
        cmd=$(build_cmd $SRC_TYPE "$(zfs_bookmark_destroy_cmd $ZFS_CMD "$snap")")
      fi
      if ! execute "$cmd"; then
        log_error "Error destroying snapshot/bookmark $snap."
        error=true
      fi
    done
  fi

  if [ ${#DST_SNAPSHOTS[@]} -gt "$DST_COUNT" ]; then
    log_info "Deleting old destination snapshots ..."
    for snap in "${DST_SNAPSHOTS[@]::${#DST_SNAPSHOTS[@]}-$DST_COUNT}"; do
      if [ "$NO_HOLD" = "false" ]; then
        log_info "... release snapshot $snap"
        cmd=$(build_cmd $DST_TYPE "$(zfs_snapshot_release_cmd $ZFS_CMD_REMOTE "$snap")")
        if ! execute "$cmd"; then
          log_error "Error releasing snapshot $snap."
          error=true
        fi
      fi
      log_info "... deleting snapshot $snap"
      cmd=$(build_cmd $DST_TYPE "$(zfs_snapshot_destroy_cmd $ZFS_CMD_REMOTE "$snap")")
      if ! execute "$cmd"; then
        log_error "Error destroying snapshot $snap."
        error=true
      fi
    done
  fi

  if [ "$error" == "true" ]; then
    exit $EXIT_ERROR
  else
    exit $EXIT_OK
  fi
}

# $1 command
function execute() {
  log_cmd "$1"
  if [ "$DRYRUN" == "true" ]; then
    log_info "dryrun ... nothing done."
    return 0
  else
    eval $1
    return
  fi
}

# main function calls
load_config
distro_dependent_commands
validate
do_backup