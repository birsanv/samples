# ACM RH OV ( RedHat OpenShift Virtualization ) backup and restore using OADP and ACM Policies

This policy can be used to backup and restore RHOV resources running on managed clusters or hub. 
The policy is installed on the hub and is placed on managed clusters ( or hub ) using a label annotation `acm-virt-config`:`value`, where `value` is the name of a ConfigMap, available on the hub in the same namespace with this policy. This ConfigMap defines the backup configuration for the cluster, such as : OADP version, backup schedule cron job, backup storage location, backup storage credentials.
An example of such configuration is available [here](./acm-virt-config-14.yaml) and [here](./acm-virt-config-13.yaml).

Run `oc apply -k virt ` to install all policies.

The [`acm-dr-virt-install`](./policies/acm-dr-virt-install.yaml) Policy installs OADP on the cluster tagged with the `acm-virt-config`:`value` label, creates the DPA and and the velero secret.

The [`acm-dr-virt-backup`](./policies/acm-dr-virt-backup.yaml) Policy backs up all vms with a `cluster.open-cluster-management.io/backup-vm`  label:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm2
  namespace: default
  labels:
    cluster.open-cluster-management.io/backup-vm: twice_a_day
```

<br>Note</br>:
The name of the `cluster.open-cluster-management.io/backup-vm` label is customizable using the `backup_label_name` property available with the [config policy](./acm-virt-config.yaml). The Policy looks for the label name as specified by this property.

The [`acm-dr-virt-restore`](./policies/acm-dr-virt-restore.yaml) Policy restore vms by UID.

# Scenario

How this works:

## VMs running on managed clusters or hub

- The user wants to enable virt backup on a managed cluster `cls1`:
  1. User creates a velero secret on the hub `hub-secret`, in the namespace where the policy is installed
  2. User creates a ConfigMap on the hub, in the namespace where the policy is installed - let's say [acm-virt-config13.yaml](./acm-virt-config-13.yaml) : the cluster is an OCP 4.12 so it has to install OADP 1.3; 
  3. The user applies on ManagedCluster `cls` this label : `acm-virt-config=acm-virt-config13` . This will result in the Policies being placed on this cluster. 

- As soon as the `acm-virt-config` label is set on the ManagedCluster `cls` resource, the `acm-virt-backup` policy is placed on the `cls` managed cluster.

The Policy looks for `kubevirt.io.VirtualMachine` on the cluster having a `cluster.open-cluster-management.io/backup-vm` label. It only goes to the next steps if such resources are found.

<b>Note</b>:
If the vm that needs to be backed up is running on the hub, the Policy will assume the OADP namespace is fixed to `open-cluster-management-backup` and will not try to install OADP because this should be installed by the backup chart when the backup component is enabled on  the MCH resource.

# Backup schedules 

The `cluster.open-cluster-management.io/backup-vm` value represents the name of the cron job to be used by this vm. The list of valid cron jobs is defined by the user using the `schedule_hub_config_name` property on the `acm-virt-config` ConfigMap. This property points to a cronjob map, see [schedule-cron.yaml](schedule-cron.yaml) as an example. All VirtualMachine are being backed up using one schedule per cron job. The velero `Schedule` name is `acm-rho-virt-schedule-<cron-job-name>`. 
Which means, if you want group vms in the same backup, you need to use the same cron schedule name for all vms.

If you want to have 2 vms in separate backups, they have to use a different name for the cron name for their schedule, even if the actual cron job is the same. For example, to backup vm1 and vm2 every hour but use different backups, create 2 cron job properties in the [schedule-cron.yaml](schedule-cron.yaml) ConfigMap, `vm1_each_hour: 0 * 1 * *` and `vm2_each_hour: 0 * 1 * *`. Since the cron job names are different, ththe vms will be backed up by different velero schedules,`acm-rho-virt-schedule-vm1-each-hour` and `acm-rho-virt-schedule-vm2-each-hour`.


## ConfigMap set by using the ManagedCluster acm-virt-config label

  1. The Policies use the `acm-virt-config13.yaml` ConfigMap ( in the documentation we refer to `acm-virt-config13.yaml` but the name is defined by the ManagedCluster acm-virt-config label) to read the user configuration, such as OADP version to be installed, namespace name for the OADP version, backup storage location, velero secret, backup schedule cron job ConfigMap.
  2. The `acm-dr-virt-install` Policy copies over from the hub to the managed cluster:
    - the velero secret `hub-secret` and store it under a Secret with a name as defined by the `credentials_name` ConfigMap value. The user should have created in the Policy namespace a Secret with a name as defined by the `credentials_hub_secret_name` propoerty.
    - the configmap `acm-virt-config13.yaml`. The user should have created a ConfigMap in the Policy namespace with a name as defined by the ManagedCluster `acm-virt-config` label.
    - the cron schedule ConfigMap defined by the `schedule_hub_config_name` property. The policy checks if the user has created a configmap on the hub cluster with the name as defined by the `schedule_hub_config_name` property and shows a violation if missing. This ConfigMap contains all cron jobs a VM can use when defining a backup schedule. See [schedule-cron.yaml](schedule-cron.yaml) as an example. 
    The user should create a ConfigMap set values such as : `daily_8am`: `0 8 * * *`.  Each vm that wants to be backed up should add a label in this format : `cluster.open-cluster-management.io/backup-vm: twice_a_day`, where `twice_a_day` is a valid cron job name defined in the ConfigMap. 

## acm-dr-virt-install Policy

 The [`acm-dr-virt-install`](./policies/acm-dr-virt-install.yaml) Policy installs, if not already installed, OADP at specified version and creates the DPA resource using the `acm-virt-config13.yaml` ConfigMap `dpa_spec` property (updates DPA is already created). If the vm runs on the hub, so the Policy is placed on the hub, the `acm-dr-virt-install` Policy just checks if OADP is installed and DPA created.

 When uninstalled or disabled, it deletes all resources created directly by the Policy.

## acm-dr-virt-backup Policy

The [`acm-dr-virt-backup`](./policies/acm-dr-virt-backup.yaml) Policy is used to backup one or more vms on the cluster where is placed. It depends on the `acm-dr-virt-install` Policy to setup and configure OADP and DPA and is not enabled until the `acm-dr-virt-install` Policy has no violations.

- The Policy creates a velero `Schedule` using the `acm-virt-config13.yaml` ConfigMap settings. It finds all VM's resources running on the cluster with a `cluster.open-cluster-management.io/backup-vm: cron_job_name` label, where `cron_job_name` is the name of the cron schedule used to backup this vm. The `cron_job_name` should be a valid property, defined by the [schedule-cron.yaml](schedule-cron.yaml) ConfigMap.

It creates a velero `Schedule` for each cron job name. All VirtualMachine are being backed up using one schedule per cron job. The velero `Schedule` name is `acm-rho-virt-schedule-<cron-job-name>`. 
Which means, if you want group vms in the same backup, on the same cluster, you need to use the same cron schedule name for all vms.

The generated backup includes all vms and all related resources, PVCs. See below an example of a Schedule with 3 VMs found.

- The Policy checks the status of the velero Backup and DataUpload resources and reports on violations.

- When uninstalled or disabled, it deletes all resources created directly by the Policy.

<b>Note:</b>
If the cluster where the VM's are running is the hub cluster then 
- the OADP ns is fixed to `open-cluster-management-backup` since this is the namespace where OADP is installed when the hub backup is enabled.
- the OADP is not installed by the Policy, it waits for the backup operator to be enabled and to install the OADP as per ACM version
- DPA or Velero secret resource are not created by the Policy, the Policy just informs on missing resources. The Policy will update the DPA with the OADP required config in order to backup the VM data but leaves the other settings unchanged.
- The VM schedule is not created unless there is an ACM hub BackupSchedule running.

Velero schedule sample, with 3 virtualmachines.kubevirt.io resources found on the managed cluster, `vm-1` in `vm-1-ns`, `vm-2` and `vm-3` in `default`:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm1
  namespace: vm1-ns
  labels:
    cluster.open-cluster-management.io/backup-vm: twice_a_day
```

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm2
  namespace: default
  labels:
    cluster.open-cluster-management.io/backup-vm: twice_a_day
```

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm3
  namespace: default
  labels:
    cluster.open-cluster-management.io/backup-vm: daily_8am
```

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: acm-rho-virt-schedule-twice-a-day
  namespace: oadp-ns
spec:
  paused: false
  schedule: 0 */12 * * *
  skipImmediately: false
  template:
    defaultVolumesToFsBackup: false
    includeClusterResources: true
    includedNamespaces:
      - vm-1-ns
      - default
    orLabelSelectors:
      - matchExpressions:
          - key: app
            operator: In
            values:
              - vm-1
              - vm-2
      - matchExpressions:
          - key: kubevirt.io/domain
            operator: In
            values:
              - vm-1
              - vm-2
    snapshotMoveData: true
    ttl: 24h
```

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: acm-rho-virt-schedule-daily-8am
  namespace: oadp-ns
spec:
  paused: false
  schedule: 0 8 * * *
  skipImmediately: false
  template:
    defaultVolumesToFsBackup: false
    includeClusterResources: true
    includedNamespaces:
      - default
    orLabelSelectors:
      - matchExpressions:
          - key: app
            operator: In
            values:
              - vm-3
      - matchExpressions:
          - key: kubevirt.io/domain
            operator: In
            values:
              - vm-3
    snapshotMoveData: true
    ttl: 24h
```

## acm-dr-virt-restore Policy

The [`acm-dr-virt-restore`](./policies/acm-dr-virt-restore.yaml) Policy restores one or more vms on the cluster where the policy is placed. It depends on the `acm-dr-virt-install` Policy to setup and configure OADP and DPA and is not enabled until the `acm-dr-virt-install` Policy has no violations.

Use the `restore_hub_config_name` property to specify what vms to restore. 
The value of the `restore_hub_config_name` property should be the name of the ConfigMap defining the restore information. This ConfigMap must be created by the user on the hub, under the Policy namespace. See [restore-config](./restore-config.yaml) ConfigMap as a sample.

In this ConfigMap you define the name of the velero restore (`restoreName` property, for example `restoreName: "acm-restore-twice-a-day-20241208155210"`), the name of the backup to restore (`backupName` property, for example backupName: `acm-rho-virt-schedule-twice-a-day-20241208155210`) and the list of vms UIDs, space separated, that you want to restore ( `vmsUID` property, for example `vmsUID: "b0ed31e9-ee17-4a59-9aa5-76b15a10ee42 uid2"`).


To get the UID of the VM you want to restore, open up the velero Backup wnd look for the labels section. Each VM that has been backed up by this velero Backup should have a label annotation in this format : `UID: vmns--vmname`. So if you know the name and ns of the VM you want to restore, you find the vm UID by looking for the label with this value `vmns--vmname`. See an example below:

```yaml
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: acm-rho-virt-schedule-daily-8am-20241209080052
  labels:
    457622ca-ab0a-474e-a6a9-cb7caf4a0a8b: mysql-persistent--fedora-todolist
```