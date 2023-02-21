# app-backup-policies
Application DR using ACM policies 
------

- [Scenario](#scenario)
- [Prerequisites](#prerequisites)
  - [Apply policies on the hub](#apply-policies-on-the-hub)
  - [Setup hdr-app-configmap ConfigMap](#setup-hdr-app-configmap-configmap)
  - [Install policy](#install-policy)
    - [Prereq for placing this policy on the hub](#prereq-for-placing-this-policy-on-the-hub)
  - [Install report policy](#install-report-policy)
- [Backup applications](#backup-applications)
- [Restore applications](#restore-applications)
- [Testing Scenario - pacman](#testing-scenario)

------

## Scenario
The Policies available here provide backup and restore support for stateful applications running on  managed clusters or hub. Velero is used to backup and restore applications data. The product is installed using the OADP operator, which the `oadp-hdr-app-install` policy installs and configure on each target cluster.

You can use these policies to backup stateful applications (`oadp-hdr-app-backup` policy) or to restore applications backups (`oadp-hdr-app-restore` policy).

The policies should be installed on the hub managing clusters where you want to create stateful applications backups, or the hub managing clusters where you plan to restore the application backups. 

Both backup and restore policies can be installed on the same hub, if this hub manages clusters where applications need to be backed up or restored. A managed cluster can either be a backup target or a restore target though, not both at the same time. 


## Prerequisites


### Setup hdr-app-configmap ConfigMap

Before you install the policies on the hub, you have to update the `hdr-app-configmap` ConfigMap values. 

You create the configmap on the hub, the same hub where the policies will be installed.

The configmap sets configuration options for the backup storage location, for the backup schedule backing up applications, and for the restore resource used to restore applications backups.

Make sure you <b>update all settings with valid values</b> before applying the `hdr-app-configmap` resource on the hub.

<b>Note</b>:

The `dpa.spec` property defines the storage location properties. The default value shows the `dpa.spec` format for using an S3 bucket. Update this to match the type of storage location you want to use.


### Apply policies on the hub

1. Run `oc apply -k ./` to apply all resources at the same time on the hub. 

2. On the cluster you want to backup or restore apps set this label : acm-pv-dr-install="true". 
This places the `oadp-hdr-app-install` policy on this cluster, and this policy installs velero and configures the connections to the storage.

3. For running a backup or restore operation on the managed cluster:
  - On the cluster you want to backup the apps set this label : acm-pv-dr="backup". 
This places the the `oadp-hdr-app-backup` policy on this cluster, which schedules the backups.
  - On the cluster you want to restore the apps set this label : acm-pv-dr="restore". 
This places the the `oadp-hdr-app-restore` policy on this cluster, which creates a restore operation.


### Install policy 


This policy is `oadp-hdr-app-install` 

Create this policy on the hub managing clusters where you want to create stateful applications backups,
or where you restore these backup.  
The policy is set to enforce.

Make sure the `hdr-app-configmap`'s storage settings are properly set before applying this policy.

The  `oadp-hdr-app-install` installs velero and configures the connection to the storage.

The  `oadp-hdr-app-install-report` reports on any runtime or configuration error.

#### Prereq for placing this policy on the hub


<b>Important:</b>

If the hub is one of the clusters where this policy will be placed, and the `backupNS=open-cluster-management-backup` then first enable cluster-backup on `MultiClusterHub`. 

The MultiClusterHub resource looks for the cluster-backup option and if set to false, it uninstalls OADP from the `open-cluster-management-backup` and deletes the namespace.


### Install report policy

Install report policy is `oadp-hdr-app-install-report` 


This policy reports on any configuration errors for the application backup or restore scenarios.
Install this policy on the hub, after you install the oadp-hdr-app-install policy

The policy is set to inform as it only validates the installed configuration.

## Backup applications

If the hub manages clusters where stateful applications are running, and you want to create backups for these applications, then on the hub you must apply the `oadp-hdr-app-backup` policy.


If the managed cluster (or hub) has the label `acm-pv-dr=backup` then the oadp-hdr-app-backup policy 
is propagated to this cluster for an application backup schedule. This cluster produces applications backups.
Make sure the `hdr-app-configmap`'s backup schedule resource settings are properly set before applying this policy.

This policy is enforced by default.

This policy creates a velero schedule to all managed clusters with a label `acm-pv-dr=backup`.
The schedule is used to backup applications resources and PVs.
The schedule uses the `backup.nsToBackup` `hdr-app-configmap` property to specify the namespaces for the applications to backup. 


## Restore applications

If the hub manages clusters where stateful applications backups must be restored, then you must install the `oadp-hdr-app-restore` policy.

If the managed cluster (or hub) has the label `acm-pv-dr=restore` then the oadp-hdr-app-restore policy 
is propagated to this cluster for backup restore operation. This cluster restores applications backup.
Make sure the `hdr-app-configmap`'s restore resource settings are properly set before applying this policy.

This policy is enforced by default.

This policy creates a velero restore resource to all managed clusters 
with a label `acm-pv-dr=restore`. The restore resource is used to restore applications resources and PVs
from a selected backup.
The restore uses the `nsToRestore` hdr-app-configmap property to specify the namespaces for the applications to restore.


<b>Note:</b>
1. The restore operation doesn't update PV or PVC resources if the restored resource is already on the cluster where the app data is restored. Make sure your application is not installed on that cluster before the restore operation is executed - the PV or PVC available with the restore app should not exist on the restore cluster prior to the restore operation.
2. The restore cluster must be able to access the region where the restore PV and snapshots are located.
3. The restore cluster must have a `VolumeSnapshotLocation` velero resource with the same name as the one used by the backup `volumeSnapshotLocations` property. The `VolumeSnapshotLocation` resource from the restore cluster must point to the backed up PV snapshots location, otherwise the restore operation will fail to restore the PV.



## Testing scenario

Use the pacman app to test the policies. (You can use 2 separate hubs for the sample below, each managing one cluster. Place the pacman app on the hub managing c1)

1. On the hub, have 2 managed clusters c1 and c1.
2. On the hub, create the pacman application subscription 
- create an app in the `pacman-ns` namespace, of type git and point to this app https://github.com/tesshuflower/demo/tree/main/pacman
- place this app on c1
- play the app, create some users and save the data.
- verify that you can see the saved data when you launch the pcman again.
3. On the hub, install the polices above, using the instructions from the readme. 
4. Place the `oadp-hdr-app-install` policy on c1 and c2 : create this label on both clusters `acm-pv-dr-install="true"`

Backup step:<br>

5. Place the backup policy on c1 : create this label on c1 `acm-pv-dr=backup`
6. On the hub, set the `backup.nsToBackup: "[\"pacman-ns\"]" ` on the `hdr-app-configmap` resource. This will backup all resources from the `pacman-ns`


Restore step:<br>

7. On the hub, on the `hdr-app-configmap` resource:
- set the `restore.nsToRestore: "[\"pacman-ns\"]" `. This will restore all resources from the `pacman-ns`
- set the `restore.backupName:` and use a backup name created from step 6
8. Place the retore policy on c2 : create this label on c1 `acm-pv-dr=restore`
9. You should see the pacman app on c2; launch the pacman app and verify that you see the data saved when running the app on c1.