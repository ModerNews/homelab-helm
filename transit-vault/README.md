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

Everything below is a one-time, by-hand bootstrap - nothing in the cluster holds a
Vault token to do it for you, deliberately ("Why no init Job" below).

1. Let ArgoCD sync the `vault` StatefulSet.

2. Initialize and unseal it manually:

   ```bash
   kubectl exec -n transit-vault -it transit-vault-0 -- vault operator init
   # store the unseal keys and root token somewhere safe (e.g. a password manager)
   kubectl exec -n transit-vault -it transit-vault-0 -- vault operator unseal
   # repeat with 3 distinct key shares
   ```

3. In the same session, bootstrap the transit engine and mint the token the remote
   Vault will seal against. The last command prints the token - copy it straight
   into your password manager, it is shown only once:

   ```bash
   kubectl exec -n transit-vault -it transit-vault-0 -- sh -c '
     vault login <root token from step 2>

     vault secrets enable transit
     vault write -f transit/keys/remote-vault-unseal

     vault policy write transit-unseal - <<EOF
   path "transit/encrypt/remote-vault-unseal" {
     capabilities = ["update"]
   }
   path "transit/decrypt/remote-vault-unseal" {
     capabilities = ["update"]
   }
   EOF

     vault token create -orphan -period=768h -policy=transit-unseal -field=token
   '
   ```

   The token is periodic, not expiring: the remote Vault's seal client renews it
   automatically as long as it stays in continuous use. It is `-orphan` so revoking
   the root token later does not take it down with it.

4. Configure the remote Vault with that token - see "Remote Vault seal stanza" below.
   That cluster is unmanaged from here, so this is always a manual copy.

5. Configure this cluster's own side - the `secret/` KV mount, Kubernetes auth, the
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

## Why no init Job

This chart used to ship a Job that enabled `transit`, wrote the key and policy, and
stored a minted token in a Secret. It was removed rather than fixed, because the
work it did is one-time bootstrap that cannot be made to converge:

- It could not run before a human had already run `vault operator init` and
  `vault operator unseal`, so it never removed a manual step - it only moved four
  `vault` commands out of the session where you are already typing by hand.
- Feeding it a Vault token meant keeping one in a Secret (`transit-vault-root-token`,
  applied out of band), plus a ServiceAccount with rights to create Secrets in the
  namespace. Both existed purely to hand a token back to a human, who then copied it
  into the remote cluster manually.
- As a Kubernetes Job it had no stable resting state. `spec.template` is immutable,
  so editing it failed the sync; the workaround (`Replace=true,Force=true`) made
  ArgoCD delete and recreate the Job on *every* sync, so it re-fired continuously
  instead of once.

If this ever wants to be declarative again, the right home is Terraform, next to the
`secret/` mount and OIDC config it already manages - not a Job in this chart.
## Remote Vault seal stanza

On the remote Vault instance, add:

```hcl
seal "transit" {
  address         = "https://transit-vault.gruzin.eu"
  token           = "<token from step 3>"
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
