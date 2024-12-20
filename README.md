# zfs-backup
**PLEASE NOTE:** This script is in **BETA** stage. Use with care and not in production.

ZFS Backup is a bash based backup solution for ZFS, leveraging the ZFS command line tools `zfs` and `zpool`.
It supports transfer of encrypted datasets, resuming aborted streams, bookmarks and many more.

The intention of this project is to create a simple to use backup solution for ZFS without other dependencies like
python, perl, go, ... on the source or target machine.

Please note that this is not a snapshot spawning local backup like `zfs-auto-snapshot` or others. 
Single purpose is to back up your datasets to another machine or drive for disaster recovery.

At the moment it supports two kinds of source or targets 'local' and 'ssh', while only one can use 'ssh'.
You can pull or push datasets from or to a remote machine as well as backup to a locally attached external drive.  
## Usage
```shell
Usage:
------
zfs-backup -s pool/data -d pool/backup -dt ssh --ssh_host 192.168.1.1 --ssh_user backup ... [--help]
zfs-backup -c configFile ... [--help]
```
## Help
```shell
Help:
=====
Parameters
----------
  -c,  --config    [file]        Config file to load parameter from (default: ).
  --create-config                Create a config file base on given commandline parameters.
                                 If a config file ('-c') is use the output is written to that file.

  -s,  --src       [name]        Name of the sending dataset (source).
  -st, --src-type  [ssh|local]   Type of source dataset: 'local' or 'ssh' (default: local).
  -ss, --src-snaps [count]       Number (greater 0) of successful sent snapshots to keep on source side (default: 1).
  -d,  --dst       [name]        Name of the receiving dataset (destination).
  -dt, --dst-type  [ssh|local]   Type of destination dataset (default: 'local').
  -ds, --dst-snaps [count]       Number (greater 0) of successful received snapshots to keep on destination side (default: 1).
  -dp, --dst-prop  [properties]  Properties to set on destination after first sync. User ',' separated list of 'property=value'
                                 If 'inherit' is used as value 'zfs inherit' is executed otherwise 'zfs set'.
                                 Default: 'canmount=off,mountpoint=none,readonly=on'
  -i,  --id        [name]        Unique ID of backup destination (default: md5sum of destination dataset and ssh host, if present).
                                 Required if you use multiple destinations to identify snapshots. Maximum of 10 characters or numbers.
  --send-param     [parameters]  Parameters used for 'zfs send' command. If set these parameters are use and all other settings (see below) are ignored.
  --recv-param     [parameters]  Parameters used for 'zfs receive' command. If set these parameters are use and all other settings (see below) are ignored.
  --bookmark                     Use bookmark (if supported) instead of snapshot on source dataset. Ignored if '-ss, --src-count' is greater 1.
  --resume                       Make sync resume able and resume interrupted streams. User '-s' option during receive.
  --intermediary                 Use '-I' instead of '-i' while sending to keep intermediary snapshots.
                                 If set, created but not send snapshots are kept, otherwise they are deleted.
  --mount                        Try to mount received dataset on destination. Option '-u' is NOT used during receive.
  --no-override                  By default option '-F' is used during receive to discard changes made in destination dataset.
                                 If you use this option receive will fail if destination was changed.
  --decrypt                      By default encrypted source datasets are send in raw format using send option '-w'.
                                 This options disables that and sends encrypted (mounted) datasets in plain.
  --no-holds                     Do not put hold tag on snapshots created by this tool.
  --only-if        [command]     Command or script to check preconditions, if command fails backup is not started.
                                 Examples:
                                 check IP: [[ \"\$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')\" =~ 192\.168\.2.* ]]
                                 check wifi: [[ \"\$(iwgetid -r)\" == \"ssidname\" ]]
  --pre-run        [command]     Command or script to be executed before anything else is done (i.e. init a wireguard tunnel).
  --post-run       [command]     Command or script to be executed after the this script is finished.
  --pre-snapshot   [command]     Command or script to be executed before snapshot is made (i.e. to lock databases).
  --post-snapshot  [command]     Command or script to be executed after snapshot is made.
  
  --restore                      Restore a previous made backup. Source and destination are switched and the lastest snapshot will be restored.
  --restore-destroy              WARNING if this option is set option '-F' is used during receive and the existing dataset will be destroyed.

  -v,  --verbose                 Print executed commands and other debugging information.
  --dryrun                       Do check inputs, dataset existence,... but do not create or destroy snapshot or transfer data.
  --version                      Print version.

Types:
------
  'local'                       Local dataset.
  'ssh'                         Traffic is streamed from/to ssh. Only source or destination can use ssh, other need to be local.

SSH Options
-----------
If you use type 'ssh' you need to specify Host, Port, etc.
 --ssh_host [hostname]          Host to connect to.
 --ssh_port [port]              Port to use (default: 22).
 --ssh_user [username]          User used for connection. If not set current user is used.
 --ssh_key  [keyfile]           Key to use for connection. If not set default key is used.
 --ssh_opt  [options]           Options used for connection (i.e: '-oStrictHostKeyChecking=accept-new').

Help
----
  -h,  --help              Print this message.
```
## Example Setup
Here you find a setup example using a separate backup user, ssh target and more. 
You probably need to adjust this to your needs.

Aim is to back up the local dataset `rpool/data` to a remote machine with IP 
`192.168.1.1` using ssh and a backup user `zfsbackup` to dataset `storage/zfsbackup`. 

Please note that using ZFS on Linux as non-root user could be troublesome, because some features like bookmarks
require root permission. Furthermore, the current ZFS permission system does not allow strict separation of
destroy permissions for snapshots, so your backup user needs nearly full permission on datasets to back up.   

On source (local machine) create a new user `zfsbackup` to perform the backups
```shell
sudo adduser --system --home /opt/zfs-backup --shell /bin/bash --group zfsbackup
```
Download script to destination (i.e. `/opt/zfs-backup`) using git, wget, browser or the tool you like best 
```shell
cd /opt
sudo -u zfsbackup git clone https://github.com/selbitschka/zfs-backup.git
```
or
```shell
sudo su zfsbackup
cd /opt/zfs-backup
wget https://raw.githubusercontent.com/selbitschka/zfs-backup/master/zfs-backup.sh
```

On target (192.168.1.1) create the same user
```shell
ssh user@192.168.1.1
sudo useradd -m zfsbackup
sudo passwd zfsbackup
```
Create ssh key and copy it to target machine (as user `zfsbackup`)
```shell
sudo -u zfsbackup ssh-keygen
sudo -u zfsbackup ssh-copy-id zfsbackup@192.168.1.1
```
Test connection and accept key of target system (as user `zfsbackup`)
```shell
sudo -u zfsbackup ssh zfsbackup@192.168.1.1
```
Create parent dataset on target (192.168.1.1) and give `zfsbackup` user required permissions to receive streams
```shell
ssh user@192.168.1.1
sudo zfs create -o readonly=on -o canmount=off storage/zfsbackup
sudo zfs allow -u zfsbackup compression,create,mount,receive storage/zfsbackup
sudo zfs allow -d -u zfsbackup canmount,destroy,hold,mountpoint,readonly,release storage/zfsbackup
sudo zfs allow storage/zfsbackup
---- Permissions on storage/zfsbackup ---------------------
Descendent permissions:
	user zfsbackup zfsbackup canmount,destroy,hold,mountpoint,readonly,release
Local+Descendent permissions:
	user zfsbackup compression,create,mount,receive
```
Allow user `zfsbackup` to perform backup tasks on source dataset `rpool/data` (local machine)
```shell
sudo zfs allow -u zfsbackup destroy,hold,release,send,snapshot rpool/data
sudo zfs allow rpool/data
---- Permissions on rpool/data -------------------------
Local+Descendent permissions:
	user zfsbackup destroy,hold,release,send,snapshot
```
At the moment it is not possible to delegate only snapshot destroy permission. Your backup user can
delete the dataset as well. Be aware of that!

Test backup with `--dryrun` and `-v` option to see debug output
```shell
sudo -u zfsbackup ./zfs-backup.sh \
    -s rpool/data \
    -d storage/zfsbackup/data \
    -dt ssh \
    --ssh_host 192.168.1.1 \
    --dryrun \
    -v
```
You should see something like this
```shell
checking if source dataset 'rpool/data' exists ...
executing: '/sbin/zfs list -H rpool/data'
... exits.
checking if source dataset 'rpool/data' is encrypted ...
executing: '/sbin/zfs get -Hp -o value encryption rpool/data'
... source is encrypted
getting source snapshot list ...
executing: '/sbin/zfs list -Hp -t snapshot -o name -s creation rpool/data'
checking if destination dataset 'storage/zfsbackup/data' exists ...
executing: '/usr/bin/ssh -p 22 -o ConnectTimeout=10 192.168.1.1  /usr/sbin/zfs list -H storage/zfsbackup/data'
executing: '/usr/bin/ssh -p 22 -o ConnectTimeout=10 192.168.1.1  /usr/sbin/zfs list -H storage/zfsbackup'
checking if destination pool supports encryption ...
executing: '/usr/bin/ssh -p 22 -o ConnectTimeout=10 192.168.1.1  /usr/sbin/zpool get -Hp -o value feature@encryption storage'
... encryption supported
Creating new snapshot for sync ...
executing: '/sbin/zfs snapshot rpool/data@bkp_7f4183fe60_20200717_140515'
dryrun ... nothing done.
getting source snapshot list ...
executing: '/sbin/zfs list -Hp -t snapshot -o name -s creation rpool/data'
No snapshot found.
```
Since we have done a dryrun no snapshot was generated and `No snapshot found.` for sync.
If there were any ssh or dataset configuration problems you would have seen an error.

Now you can generate a config for further use
```shell
sudo -u zfsbackup ./zfs-backup.sh \
    -s rpool/data \
    -d storage/zfsbackup/data \
    -dt ssh \
    --ssh_host 192.168.1.1 \
    --create-config \
    --config data_backup.config
```
Now you can execute the backup with
```shell
sudo -u zfsbackup ./zfs-backup.sh -c data_backup.config
```
of create a cronjob
```shell
* 12	* * *	zfsbackup    cd /opt/zfs-backup && ./zfs-backup.sh -c data_backup.config
```
## Planned features
* Recursive backups (implemented but not tested yet)
  
## Bugs and feature requests
Please feel free to [open a GitHub issue](https://github.com/selbitschka/zfs-backup/issues/new) for feature requests and bugs.

## License
**MIT License**

Copyright (c) 2022 Stefan Selbitschka

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.