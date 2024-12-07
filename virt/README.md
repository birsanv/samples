# ACM RH OV ( RedHat OpenShift Virtualization ) backup using OADP and ACM Policies

This policy can be used to backup RHOV resources running on managed clusters or hub. 
The policy is installed on the hub and is placed on managed clusters ( or hub ) using a label annotation `acm-virt-config`:`value`, where is the name of a ConfigMap, available on the hub in the same namespace with this policy. This ConfigMap defines the backup configuration for the cluster, such as : OADP version, backup schedule cron job, backup storage location, backup storage credentials.
An example of such configuration is available [here](./acm-virt-config.yaml) and [here](./acm-virt-config-13.yaml).

The Policy installs OADP on the cluster tagged with the `acm-virt-config`:`value` label, creates the DPA and creates a backup schedule to backup all VM resources.

How this works:
- The user wants to enable virt backup on a managed cluster `cls1`:
  1. User creates a velero secret on the hub `hub-secret`, in the namespace where the policy is installed
  2. User creates a ConfigMap on the hub, in the namespace where the policy is installed - let's say [acm-virt-config13.yaml](./acm-virt-config-13.yaml) : the cluster is an OCP 4.12 so it has to install OADP 1.3; 
  3. The user applies on ManagedCluster `cls` this label : acm-virt-config=acm-virt-config13.yaml 

- As soon as the `acm-virt-config` label is set on the ManagedCluster `cls` resource, the `acm-virt-backup` policy is placed on the `cls` managed cluster.

The Policy looks for `kubevirt.io.VirtualMachine` on the cluster. It only goes to the next steps if such resources are found. All VirtualMachine are being backed up using one schedule, named acm-rho-virt-schedule. If you want to backup only a subset of the VM's , use the   `backup_label_name` property on the ConfigMap to specify what label should have the VM's to be backed up. For example, is you want to backup only VM's with the label 'backup-vm', add this to  the VM ( the value can be anything , as long as the VM has the backup-vm label it will be backed up).

  1. The Policy uses the `acm-virt-config13.yaml` ConfigMap to read the user configuration, such as OADP version to be installed, namespace name for the OADP version, backup storage location, velero secret, backup schedule cron job
  2. The Policy copies over on the managed cluster 
    - the velero secret `hub-secret` and story it under a Secret with a name as defined by the `credentials_name` ConfigMap value
    - the configmap `acm-virt-backup`
    - the cron schedule ConfigMap defined by the `acm-virt-backup` `schedule_hub_config_name` property. The policy checks if the user had created a configmap on the hub cluster with the name as defined by the `schedule_hub_config_name` property and shows a violation if the user had not done that. This ConfigMap contains all the valid cron jobs a VM can use when defining a backup schedule. The user should create a ConfigMap set values such as : daily_8am: 0 8 * * *. See [schedule-cron.yaml](schedule-cron.yaml) as an example. Each vm that wants to be backed up should add a label in this format : cluster.open-cluster-management.io/backup-vm: twice_a_day, where twice_a_day is a valid cron job name defined in the ConfigMap. 

  3. The Policy installs, if not already installed, OADP at specified version and creates the DPA resource using the `acm-virt-config13.yaml` ConfigMap `dpa_spec` property (updates DPA is already created).
  4. The Policy creates a velero Schedule using the `acm-virt-config13.yaml` ConfigMap settings. It finds all VM's resources and includes each of them, plus all related resources. See below an example of a Schedule with 2 VMs found.
  5. The Policy checks the status of the velero Backup and DataUpload resources and reports on violations.
  6. When uninstalled, the Policy prunes all resources created by the Policy.

<b>Note:</b>
If the cluster where the VM's are running is the hub cluster then 
- the OADP ns is fixed to `open-cluster-management-backup` since this is the namespace where OADP is installed when the hub backup is enabled.
- the OADP is not installed by the Policy, it waits for the backup operator to be enabled and to install the OADP as per ACM version
- DPA or Velero secret resource are not created by the Policy, the Policy just informs on missing resources. The Policy will update the DPA with the OADP required config in order to backup the VM data but leaves the other settings unchanged.
- The VM schedule is not created unless there is an ACM hub BackupSchedule running.

Velero schedule sample, with 3 virtualmachines.kubevirt.io resources found on the managed cluster, `vm-1` in `vm-1-ns`, `vm-2` and `vm-3` in `default`:

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: acm-rho-virt-schedule
  namespace: oadp-ns
spec:
  paused: false
  schedule: 0 */3 * * *
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
              - vm-3
      - matchExpressions:
          - key: kubevirt.io/domain
            operator: In
            values:
              - vm-1
              - vm-2
              - vm-3
    snapshotMoveData: true
    ttl: 24h
```
