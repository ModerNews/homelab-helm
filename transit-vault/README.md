# Vault (transit-vault)

The cluster's only Vault. It does two jobs:

1. **Root of trust for the remote Vault.** A `transit` secrets engine that the
   remote (WMS-DEV) instance points its `seal "transit"` stanza at for auto-unseal.
2. **This cluster's secret store.** A `secret/` KV v2 mount holding one entry per
   OIDC client at `secret/oidc/<app>`, which the
   [Vault Secrets Operator](../vault-secrets-operator) materialises into app
   namespaces. Anything still applied by hand (`mail-secret`, `argocd-secret`, the
   Cloudflare token) belongs here too.

Because it is the root of trust it seals/unseals itself the normal way (Shamir
shares) - nothing auto-unseals it.

```
transit-vault --(transit engine)--> remote WMS-DEV Vault
      '-------(secret/ + VSO)-----> app namespaces
```

The name is a leftover from job 1 and is deliberately kept: the remote cluster's
seal stanza points at `transit-vault.gruzin.eu`, and that cluster is unmanaged from
here, so renaming would mean a seal migration over there. `vault.gruzin.eu` is an
ingress alias on the same instance.

## Why not two Vaults

A separate secrets Vault auto-unsealing against this one was built and then removed.
It looked tidier, but this instance still has to be unsealed by hand first, so the
chain cost ~250Mi on an 8GB node to save exactly zero manual steps - a reboot needed
one `vault operator unseal` either way.

The isolation it bought was also thinner than it appears. Vault's policy engine is
the real boundary: the `oidc-read` policy is scoped to `secret/data/oidc/*`, so a
compromised app namespace cannot reach `transit/` whether or not the two live in the
same process. Splitting only helps against an attacker who already has the Vault
process or a root token - and both instances ran on the same node under the same
cluster admin anyway.

If the remote Vault is ever something whose blast radius you want genuinely
separated from homelab app secrets, that argues for moving it off this node, not for
a second Vault beside it.

## First deploy

1. Let ArgoCD sync the `vault` StatefulSet (the init Job will crash-loop
   harmlessly until step 2-3 are done - that's expected).

2. Initialize and unseal it manually:

   ```bash
   kubectl exec -n transit-vault -it transit-vault-0 -- vault operator init
   # store the unseal keys and root token somewhere safe (e.g. a password manager)
   kubectl exec -n transit-vault -it transit-vault-0 -- vault operator unseal
   # repeat with 3 distinct key shares
   ```

3. Using the root token, mint a narrowly-scoped token for the init Job instead
   of handing it root - it only ever needs to mount `transit`, write one
   policy, and issue one child token:

   ```bash
   kubectl exec -n transit-vault -it transit-vault-0 -- sh -c '
     vault login <root token>

     vault policy write transit-init - <<EOF
   path "sys/mounts/transit" {
     capabilities = ["create", "read", "update", "sudo"]
   }
   path "sys/policies/acl/transit-unseal" {
     capabilities = ["create", "update"]
   }
   path "transit/keys/remote-vault-unseal" {
     capabilities = ["create", "update"]
   }
   path "auth/token/create" {
     capabilities = ["create", "update", "sudo"]
   }
   EOF

     vault token create -orphan -policy=transit-init -period=768h -field=token
   '
   ```

   The root token is only needed for this one session - discard it (or lock it
   away offline) afterwards, don't store it in the cluster.

4. Put the scoped token in the secret the init Job reads (still named after
   the values.yaml `rootTokenSecretName` field, but holds the scoped token
   from step 3, not the actual root token):

   ```bash
   cp vault-root-token.example.yaml vault-root-token.yaml
   # fill in the token from step 3, not the root token
   kubectl apply -f vault-root-token.yaml
   ```

5. Let the init Job (re)run - it enables the `transit` engine, creates the
   `remote-vault-unseal` key and `transit-unseal` policy, and writes a
   periodic token into `secret/transit-vault-unseal-token`. It is idempotent
   and safe to re-run on every deploy - it leaves the token alone once created.

6. Copy the token out to configure the remote Vault:

   ```bash
   kubectl get secret -n transit-vault transit-vault-unseal-token \
     -o jsonpath='{.data.token}' | base64 -d
   ```

7. Configure this cluster's own side - the `secret/` KV mount, Kubernetes auth, the
   `oidc-read` policy, the `vso` role and one credential per OIDC client. All of
   that is declared in [terraform/](../terraform):

   ```bash
   export VAULT_ADDR=https://vault.gruzin.eu
   export VAULT_TOKEN=<root token from step 2>

   cd terraform
   terraform init
   terraform apply
   ```

   Discard the root token afterwards - nothing in the cluster needs it.

## Remote Vault seal stanza

On the remote Vault instance, add:

```hcl
seal "transit" {
  address         = "https://transit-vault.gruzin.eu"
  token           = "<token from step 6>"
  disable_renewal = "false"
  key_name        = "remote-vault-unseal"
  mount_path      = "transit/"
}
```

After every restart of this transit Vault, someone has to run
`vault operator unseal` again before the remote Vault can unseal itself.


## After a node reboot

Vault comes back sealed. Until it is unsealed, VSO cannot read anything and the
remote Vault cannot unseal either.

```bash
kubectl exec -n transit-vault -it transit-vault-0 -- vault operator unseal   # x3 shares
```

Pods that already hold their credential keep running, so SSO only breaks if
something restarts during the window. ArgoCD keeps `admin.enabled: true`, and Immich
and Paperless keep their local logins, so the cluster stays reachable meanwhile.

## Rotating an OIDC credential

```bash
cd terraform
terraform apply -replace='random_password.oidc["immich"]'
```

VSO rewrites the Secret and the Keycloak operator reconciles the new value onto the
client - both read the same object, so they cannot end up disagreeing. Restart the
app if it only reads its credential at startup (Immich does).

## Known trade-off

The `vso` role binds the `default` ServiceAccount of each app namespace, and
`oidc-read` is granted on `secret/oidc/*` rather than per-app paths. Any pod in those
namespaces could therefore read another app's client secret. That is a deliberate
single-tenant trade against maintaining a ServiceAccount, role and policy per app;
both are declared in `terraform/main.tf` if you ever want to split them.
