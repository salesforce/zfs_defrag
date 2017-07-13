# zfs_defrag
Automation of snapshotting a zfs pool and sending it to S3, destroy the pool, recreate, and import the snapshot in order to fix ZFS Fragmentation

# DISCLAIMER
_While this script does everything it can to ensure your data's integrety, this **IS** a destructive operation. Please make sure you have valid backups before beginning as we can not be responsible if something were to go wrong._

## Why does this exist?
ZFS is a copy-on-write filesystem so when you edit a file, when it is saved it copies the entire file to another location on the disk.
This prevents traditional fragmentation by keeping the entire file together.
The issue is now your free space is fragmented so the OS and filesystem need to work harder to find places to put files.
Currently ZFS has no plans to fix this and there is some further documentation  here in
[ZFS Issue 3582](https://github.com/zfsonlinux/zfs/issues/3582) which itself has multiple links showing the issues.
The long term fix is BPR (Block Pointer Rewrite) which is not currently on the roadmap.

## Prerequisites
You must have the following installed:
- s3cmd
- lsof
- pv
- pigz

Run `s3cmd --configure` to setup your keys and connection to AWS S3.
Edit `zfs_defrag.sh` to point to the correct file which defaults to `/root/.s3cmd.cfg`

**_This will also work for any internally hosted S3 compliant service such as Riak, Ceph, LeoFS, etc._**

## Before you start
On your server ensure all services which access you ZFS pools are stopped.
To find out which mount points are ZFS pools run:
```
$ zfs list -o mountpoint
MOUNTPOINT
/data
/opt
```
Then simply ensure there are no open files on each one:
```
lsof /data
lsof /opt
```
### IMPORTANT NOTE REGARDING ZVOLS
At this time this script does not support [ZVOLs](https://docs.oracle.com/cd/E18752_01/html/819-5461/gaypf.html). To quote [Jim Salter](http://jrs-s.net/2016/06/16/psa-snapshots-are-better-than-zvols/)
> If you have a dataset that’s occupying 85% of your pool, you can snapshot that dataset any time you like. If you have a ZVOL that’s occupying 85% of your pool, you cannot snapshot it, period. This is one of those things that both tyros and vets tend to immediately balk at – I must be misunderstanding something, right? Surely it doesn’t work that way? Afraid it does.
To see if you are currently using a zvol simply run :
```
zfs list -t volume
no datasets available
```
This is what you want to see.


## Running Defragmentation
Your options are as follows:

- -c <New create statement> - Used for if you want to make changes to how your zfs pool was originally created
    - ex: `zfs-defrag.sh -c "zpool create -f data sdb log sdc1 cache sdc2"`
- -x <new options> - Used for if you simply want to add extra "-o" options to your "zfs create" statements
    - ex: `zfs-defgrag.sh -x "-o ashift=12"`
- -y - For defaulting to yes to all questions to use in a semi-hands off state
 **NOTE** This will NOT bypass if there are open files! (hence the semi-hands off)
- -h - Print this help

In general if you want your zfs pool to be setup exactly as it was you don't need any options: `zfs-defrag.sh`

### What happens during the run

- Get default ZFS options and change some in order to speed up zfs send and recieve
-  Look for mountpoints via `zfs list` and checks each one for open files.
    - In this part we will exit hard if any are found
-  Check existing fragmentation.
- Grab `zfs history ${POOL}` to get the original create command in order to re-create it as is (unless one of the above options are given)
- Snapshot the ZFS pool recursively
- Send the snapshot to S3 (or S3 compliant service as defined in your s3cmd.cfg)
- Checks for open files again in case any service started up or someone went into a target directory, etc
    - At this point the script will go into a wait state until you tell it to continue and loop until all mounts are clear
- Destroys the zfs pool
- Re-creates the zfs pool
- Receives the snapshot back from S3
- Re-mounts all of your mountpoints via `zfs mount -a`
- Runs a cleanup
    - deletes local snapshots
    - delete remote snapshots from s3
    - sets zfs settings back to your original settings.
