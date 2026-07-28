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

3. Put the root token in a secret the init Job can read:

   ```bash
   cp vault-root-token.example.yaml vault-root-token.yaml
   # fill in the real token
   kubectl apply -f vault-root-token.yaml
   ```

4. Let the init Job (re)run - it enables the `transit` engine, creates the
   `remote-vault-unseal` key and `transit-unseal` policy, and writes a
   periodic token into `secret/transit-vault-unseal-token`. It is idempotent
   and safe to re-run on every deploy - it leaves the token alone once created.

5. Copy the token out to configure the remote Vault:

   ```bash
   kubectl get secret -n transit-vault transit-vault-unseal-token \
     -o jsonpath='{.data.token}' | base64 -d
   ```

## Remote Vault seal stanza

On the remote Vault instance, add:

```hcl
seal "transit" {
  address         = "https://transit-vault.gruzin.eu"
  token           = "<token from step 5>"
  disable_renewal = "false"
  key_name        = "remote-vault-unseal"
  mount_path      = "transit/"
}
```

After every restart of this transit Vault, someone has to run
`vault operator unseal` again before the remote Vault can unseal itself.
