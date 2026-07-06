# Variant: PostgreSQL in-cluster with Init Container (Secrets Manager) + TLS + Encryption at Rest

This variant extends `dev-postgres-efs/` with:
1. **Init container fetching the password from AWS Secrets Manager** — using
   the pod's IRSA (IAM Roles for Service Accounts) and the AWS STS/SM APIs,
   without the Secrets Store CSI driver
2. **TLS in transit** — all connections encrypted via cert-manager certificates
3. **Encryption at rest** — via EFS's built-in AES-256 volume encryption

---

## Key difference from the AKS variant: how the init container authenticates

AKS uses Azure IMDS (`http://169.254.169.254/metadata/identity/...`) to get a
bearer token with no signing complexity — a plain `curl` GET with a `Metadata: true`
header returns the token. One `curl` call to Key Vault with that token as
`Authorization: Bearer` fetches the secret.

AWS Secrets Manager requires **AWS Signature Version 4** (SigV4) signing on
every API call — a HMAC-SHA256 signature built from the request method, URL,
headers, and body, plus the request date. This is genuinely complex to implement
in pure shell/curl. Two practical options:

| Option | Image | Complexity | Size |
|---|---|---|---|
| **amazon/aws-cli** (recommended) | `amazon/aws-cli:latest` | Just `aws secretsmanager get-secret-value` | ~450MB |
| Pure curl + shell SigV4 | `curlimages/curl:8.7.1` | ~80 lines of signing code | ~8MB |

**This lab uses `amazon/aws-cli`** (the commented-out recommended block in
`05-postgres-statefulset-tls-initcontainer.yaml`) since it's simpler and less
error-prone. If image size is a concern for your environment, replace it with
a custom minimal image that includes the AWS CLI, or implement SigV4 signing
in shell.

---

## Files in this directory

| File | Purpose |
|---|---|
| `04-postgres-tls-cert.yaml` | Self-signed CA + server TLS certificate via cert-manager |
| `05-postgres-statefulset-tls-initcontainer.yaml` | PostgreSQL StatefulSet with 2 init containers + TLS ConfigMap |
| `06-app-deployment-postgres-tls.yaml` | App Deployment with TLS connection string + CA cert mount |

Depends on:
- `dev-postgres-efs/00-pvc.yaml` (EFS PVC must already be bound)
- `00b-aws-efs.sh` + `01b-install-efs-csi-driver.sh` (EFS infrastructure)
- cert-manager installed in the cluster

---

## Step-by-step

### 1. Prerequisites
```bash
./00-aws-infra.sh
./00b-aws-efs.sh
./01b-install-efs-csi-driver.sh
```

### 2. Store Postgres password in Secrets Manager
```bash
source .infra-state.env
PG_PASSWORD="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-30)"
aws secretsmanager create-secret --name eks-lab/postgres-admin-password \
  --secret-string "$PG_PASSWORD" --region "$REGION"
PG_SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id eks-lab/postgres-admin-password \
  --region "$REGION" --query ARN --output text)
```

### 3. Grant the IRSA role access to the new secret
```bash
source .infra-state.env
EXISTING_POLICY=$(aws iam get-role-policy \
  --role-name eks-lab-dotnet-app-role \
  --policy-name eks-lab-secrets-read 2>/dev/null || echo '{}')

aws iam put-role-policy \
  --role-name eks-lab-dotnet-app-role \
  --policy-name eks-lab-secrets-read \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"secretsmanager:GetSecretValue\",\"secretsmanager:DescribeSecret\"],
      \"Resource\": [\"${SECRET_ARN}\",\"${PG_SECRET_ARN}\"]
    }]
  }"
```

### 4. Install cert-manager
```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.14.0 --set crds.enabled=true
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=120s
```

### 5. Fill in placeholders and apply
```bash
source .infra-state.env
sed -i "s|<POSTGRES-SECRET-ARN>|${PG_SECRET_ARN}|g" \
  dev-postgres-efs-tls/05-postgres-statefulset-tls-initcontainer.yaml
sed -i "s|<AWS_REGION>|${REGION}|g" \
  dev-postgres-efs-tls/05-postgres-statefulset-tls-initcontainer.yaml
sed -i "s|<ECR_URI>|${ECR_URI}|g" \
  dev-postgres-efs-tls/06-app-deployment-postgres-tls.yaml

kubectl apply -f dev-postgres-efs/00-pvc.yaml
kubectl apply -f dev-postgres-efs-tls/04-postgres-tls-cert.yaml
kubectl wait --for=condition=Ready certificate/postgres-server-cert -n dev --timeout=60s
kubectl apply -f dev-postgres-efs-tls/05-postgres-statefulset-tls-initcontainer.yaml
kubectl apply -f dev-postgres-efs-tls/06-app-deployment-postgres-tls.yaml
```

### 6. Verify
```bash
kubectl logs -n dev postgres-0 -c fetch-sm-password
kubectl logs -n dev postgres-0 -c fix-cert-permissions
kubectl exec -n dev postgres-0 -- psql -U postgresadmin -c "SHOW ssl;"
```

### 7. Verify EFS encryption at rest
```bash
source .infra-state.env
aws efs describe-file-systems --file-system-id "$EFS_ID" \
  --region "$REGION" --query "FileSystems[0].Encrypted" --output text
# Should return: True
```

## Teardown (not covered by main cleanup.sh)
```bash
kubectl delete -f dev-postgres-efs-tls/
helm uninstall cert-manager -n cert-manager
aws secretsmanager delete-secret --secret-id eks-lab/postgres-admin-password \
  --force-delete-without-recovery --region "$REGION"
```
