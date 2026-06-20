# EKS + RDS SQL Server Lab — Setup Guide

This is the AWS/EKS equivalent of the AKS lab, covering the same six
requirements with AWS-native primitives:

| AKS lab | EKS lab |
|---|---|
| AKS | EKS (provisioned via `eksctl`) |
| ACR | ECR |
| Azure Key Vault | AWS Secrets Manager |
| Azure SQL + Private Endpoint | RDS SQL Server, private subnet, security-group-restricted |
| Azure AD Workload Identity | IRSA (IAM Roles for Service Accounts) |
| `--network-policy azure` (built-in) | Calico in policy-only mode on top of VPC CNI (separate install) |
| AGIC (Application Gateway Ingress Controller) | AWS Load Balancer Controller + ALB Ingress |

## Quickest path: one script

```bash
chmod +x run-all.sh
./run-all.sh
```

Expect ~35-45 minutes total — RDS provisioning alone typically takes
10-15 minutes, and the EKS cluster itself another 10-15. The script pauses
once partway through and asks you to manually create the application
database (see below) before continuing, since RDS has no API equivalent
to Azure SQL's `az sql db create` for SQL Server engines.

If you'd rather run things manually instead, the sections below describe
what `run-all.sh` does step by step.

## Prerequisites

Run `install-tools.sh` first if you don't already have `aws`, `eksctl`,
`kubectl`, `helm`, `jq`, and `docker` installed:

```bash
chmod +x install-tools.sh
./install-tools.sh
# log out and back in (or: newgrp docker)
aws configure   # set access key, secret key, default region
```

## Apply order (manual, if not using run-all.sh)

### 1. AWS infrastructure
```bash
./00-aws-infra.sh
```
Creates the EKS cluster (via `eksctl`, which also provisions the VPC,
subnets, and NAT gateway), ECR repo, RDS SQL Server instance in a private
subnet, a security group restricting RDS access to the EKS node security
group only, and the initial Secrets Manager secret.

### 2. Create the application database
RDS gives you a SQL Server *instance*, but not a named database inside
it — that's a SQL-level operation, not an AWS API call. Once
`00-aws-infra.sh` finishes, get the password and connect:
```bash
aws secretsmanager get-secret-value --secret-id eks-lab/sql-credentials \
  --region <region> --query SecretString --output text | jq -r .password
```
Then, from a pod inside the cluster (so it can actually reach the private
RDS endpoint):
```bash
kubectl run sqlcmd-tmp --rm -it --restart=Never -n default \
  --image=mcr.microsoft.com/mssql-tools -- \
  /opt/mssql-tools/bin/sqlcmd -S <rds-endpoint> -U sqladmin -P '<password>' \
  -Q "CREATE DATABASE appdb;"
```

### 3. IRSA, Secrets Store CSI driver, ALB controller, Calico
```bash
./01-aws-lbc-and-identity.sh
```
This is the step with no single-flag AKS equivalent — on AKS,
`--enable-addons azure-keyvault-secrets-provider` and
`--network-policy azure` did this in one command each. On EKS it's four
separate installs: an IAM role (IRSA) for the pod, the Secrets Store CSI
driver + AWS provider (Helm), the AWS Load Balancer Controller (Helm), and
Calico (Tigera operator, policy-only mode on top of VPC CNI).

### 4. Fill in placeholders
| Placeholder | Where | Source |
|---|---|---|
| `<POD-IAM-ROLE-ARN>` | 01 | printed by `01-aws-lbc-and-identity.sh` / `.infra-state.env` |
| `<SQL-SECRET-ARN>` | 02 | `.infra-state.env` (`SECRET_ARN`) |
| `<ECR_URI>` | 04, build-and-push.sh | `.infra-state.env` |
| `<AWS_REGION>` | build-and-push.sh | `.infra-state.env` |
| `<ALB-SUBNET-CIDRS>` | 05 | see note below — **not auto-fillable with a correct value until after the ALB exists** |

`run-all.sh` auto-fills everything except the NetworkPolicy's ALB CIDR,
which it defaults to the full VPC CIDR as a safe starting point (broader
than ideal, but functionally correct) and prints instructions to narrow
afterward — see "Why the NetworkPolicy already accounts for the ALB"
below for why this matters.

### 5. Build, push, apply
```bash
./build-and-push.sh
kubectl apply -f k8s/dev/00-namespace.yaml
kubectl apply -f k8s/dev/01-serviceaccount.yaml
kubectl apply -f k8s/dev/02-secretproviderclass.yaml
kubectl apply -f k8s/dev/03-configmap.yaml
kubectl apply -f k8s/dev/04-deployment-service.yaml
kubectl apply -f k8s/dev/05-networkpolicy.yaml
kubectl apply -f k8s/dev/07-ingress-alb.yaml
```

### 6. Verify DB connectivity
```bash
kubectl get pods -n dev
kubectl logs -n dev deploy/dotnet-helloworld
kubectl exec -n dev deploy/dotnet-helloworld -- env | grep SQL_
```

### 7. Verify ping/NetworkPolicy behavior
```bash
kubectl apply -f k8s/dev/06-network-test-pods.yaml
DEV_IP=$(kubectl get pod -n dev net-test-dev -o jsonpath='{.status.podIP}')
kubectl exec -n dev net-test-dev -- ping -c 3 "$DEV_IP"        # should succeed
kubectl exec -n other-ns net-test-other -- ping -c 3 "$DEV_IP" # should fail/time out
```

### 8. Verify ALB ingress
```bash
kubectl get ingress -n dev   # wait a few minutes for ADDRESS to populate
curl -v http://<ADDRESS-from-above>/
```

### 9. Rotate the SQL password later
```bash
./rotate-sql-password.sh
```

## Why the NetworkPolicy already accounts for the ALB

The AKS version of this lab hit a real bug during testing: a NetworkPolicy
scoped to allow traffic only from the `dev` namespace silently blocked
AGIC's health probes too, since AGIC's traffic is genuinely external to
the namespace from the policy's perspective — even though a completely
separate Service of `type: LoadBalancer` to the same pods worked fine,
which made the cause non-obvious at first. The fix was a second NetworkPolicy
rule explicitly allowing the App Gateway's subnet CIDR through on the
app's port only.

The exact same risk applies here: the AWS Load Balancer Controller's ALB,
running in `target-type: ip` mode, sends health-check and proxied traffic
directly to pod IPs from the ALB's own subnets — traffic that's genuinely
external to `dev` from Calico's policy-enforcement perspective, just like
AGIC's was for Azure CNI. `05-networkpolicy.yaml` includes this allowance
from the start, rather than making you rediscover the same bug.

The one thing that's *not* fully automated: which subnet CIDR to actually
allow. On AKS, the App Gateway has a single dedicated subnet decided at
infra-creation time, so the CIDR is known upfront. On EKS, the ALB
controller picks subnets dynamically (any subnet tagged
`kubernetes.io/role/elb`), and you don't know exactly which ones it used
until after the Ingress is created and the ALB exists. `run-all.sh`
defaults the NetworkPolicy to the full VPC CIDR as a safe, functional
starting point — broader than strictly necessary, but correct — and the
script prints instructions to narrow it down to the ALB's actual subnets
once you can see them:
```bash
aws elbv2 describe-load-balancers --region <region> \
  --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-dev-dotnethel')].AvailabilityZones[].SubnetId"
```
Then look up each subnet's CIDR and update the `ipBlock.cidr` in
`05-networkpolicy.yaml` (NetworkPolicy `ipBlock` only accepts one CIDR per
entry — list multiple entries under `from:` if the ALB spans more than
one subnet, which it normally does for high availability across AZs).

## Why Calico is more involved here than on AKS

AKS gives you `--network-policy azure` as a single flag at cluster
creation — Azure CNI bundles a built-in NetworkPolicy enforcement engine.
EKS's default VPC CNI does not enforce NetworkPolicy objects at all unless
you explicitly add either Calico (Tigera operator, the option used here)
or enable VPC CNI's own newer native NetworkPolicy mode (a single
`enableNetworkPolicy: "true"` config value on the `vpc-cni` addon — see
the commented alternative in `01-aws-lbc-and-identity.sh` if you'd rather
use that simpler path instead of Calico).

## Tearing everything down

```bash
./cleanup.sh
```

Unlike the AKS lab's single `az group delete`, AWS has no equivalent
single-command teardown spanning EC2/RDS/IAM/ECR — `cleanup.sh` deletes
each service in dependency order (Ingress first, to let the ALB
deprovision cleanly; then RDS; then Secrets Manager; then ECR; then the
lab's own IAM roles/policies; then the EKS cluster itself via `eksctl
delete cluster`, which also tears down the VPC/subnets/NAT gateway it
created). This is genuinely destructive and asks for confirmation unless
you pass `--yes`.

One AWS-specific risk worth knowing: if the Ingress is deleted *after* the
EKS cluster is gone (rather than before, as `cleanup.sh` does), the ALB
and its target groups/security groups become orphaned and need manual
cleanup from the EC2 console — there's no cluster left to tell AWS to
deprovision them. `cleanup.sh` deliberately deletes the Ingress and waits
60 seconds before going further, specifically to avoid this.
