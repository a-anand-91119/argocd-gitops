# Postiz Deployment

## Secrets Management

The Postiz Helm chart (`postiz-app`) always creates a Secret named `postiz-postiz-app-secrets`, with no option to disable it or use an existing secret.

To avoid pushing secrets to git, the following workaround is implemented:

### Solution: ArgoCD Resource Exclusion + SealedSecrets

1. **ArgoCD Resource Exclusion**: The secret is excluded from ArgoCD sync via `argocd-cm` ConfigMap:
   ```yaml
   resource.exclusions: |
     - apiGroups:
       - "*"
       kinds:
       - Secret
       names:
       - postiz-postiz-app-secrets
   ```

2. **SealedSecret**: The actual secret is managed by SealedSecrets controller via `zeus-k8s/secrets/postiz-secrets.yml`

### How It Works

1. Helm chart tries to create `postiz-postiz-app-secrets` with empty values
2. ArgoCD ignores this resource due to the exclusion rule
3. SealedSecret controller creates the secret with actual values
4. Pod uses the SealedSecret-managed secret

### Updating Secrets

To update the secrets:

```bash
# Create a plain secret file (DO NOT COMMIT THIS)
cat > /tmp/postiz-secret.yml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: postiz-postiz-app-secrets
  namespace: postiz
type: Opaque
stringData:
  DATABASE_URL: "postgresql://user:pass@host:5432/db"
  REDIS_URL: "redis://:password@host:6379"
  JWT_SECRET: "your-jwt-secret"
  # Add other secrets as needed...
EOF

# Seal it
kubeseal --format yaml < /tmp/postiz-secret.yml > zeus-k8s/secrets/postiz-secrets.yml

# Clean up
rm /tmp/postiz-secret.yml

# Commit and push
git add zeus-k8s/secrets/postiz-secrets.yml
git commit -m "Update postiz secrets"
git push
```

### Required ArgoCD Configuration

If setting up from scratch, add this to `argocd-cm` ConfigMap in `argocd` namespace:

```bash
kubectl patch cm argocd-cm -n argocd --type=merge -p '
{
  "data": {
    "resource.exclusions": "- apiGroups:\n  - \"*\"\n  kinds:\n  - Secret\n  clusters:\n  - \"*\"\n  names:\n  - postiz-postiz-app-secrets\n"
  }
}'

# Restart ArgoCD to apply changes
kubectl rollout restart deployment argocd-repo-server -n argocd
kubectl rollout restart statefulset argocd-application-controller -n argocd
```

### Secret Keys

The following secret keys are used by Postiz:

| Key | Required | Description |
|-----|----------|-------------|
| `DATABASE_URL` | Yes | PostgreSQL connection string |
| `REDIS_URL` | Yes | Redis/Valkey connection string |
| `JWT_SECRET` | Yes | JWT signing secret |
| `X_API_KEY` | No | X/Twitter API key |
| `X_API_SECRET` | No | X/Twitter API secret |
| `LINKEDIN_CLIENT_ID` | No | LinkedIn OAuth client ID |
| `LINKEDIN_CLIENT_SECRET` | No | LinkedIn OAuth client secret |
| `REDDIT_CLIENT_ID` | No | Reddit OAuth client ID |
| `REDDIT_CLIENT_SECRET` | No | Reddit OAuth client secret |
| `GITHUB_CLIENT_ID` | No | GitHub OAuth client ID |
| `GITHUB_CLIENT_SECRET` | No | GitHub OAuth client secret |
| `RESEND_API_KEY` | No | Resend email API key |
| `CLOUDFLARE_ACCOUNT_ID` | No | Cloudflare R2 account ID |
| `CLOUDFLARE_ACCESS_KEY` | No | Cloudflare R2 access key |
| `CLOUDFLARE_SECRET_ACCESS_KEY` | No | Cloudflare R2 secret key |
| `CLOUDFLARE_BUCKETNAME` | No | Cloudflare R2 bucket name |
| `CLOUDFLARE_BUCKET_URL` | No | Cloudflare R2 bucket URL |
