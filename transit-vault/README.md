# Transit Vault

Standalone Vault instance whose only job is running a `transit` secrets
engine for the **remote** Vault instance's auto-unseal (`seal "transit"`
stanza). It is the root of trust, so it seals/unseals itself the normal way
(Shamir shares) - nothing in this cluster auto-unseals it.

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
