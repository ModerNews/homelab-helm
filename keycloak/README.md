# Keycloak

The cluster's OIDC provider. Everything is operator custom resources - there is no
upstream Helm chart involved and no config-as-code side channel.

| Resource | Purpose |
|---|---|
| `Keycloak` | the instance itself; the operator builds the Deployment, Service and admin Secret |
| `KeycloakRealmImport` | the `homelab` realm, its `groups` client scope and realm groups |
| `KeycloakOIDCClient` | one per app, in that app's namespace |
| `Cluster` (CNPG) | Postgres, matching immich/paperless |

The operator is installed straight from upstream kustomize - see
`.argocd/keycloakOperatorApplication.yaml`. It is deployed **cluster-wide**, because
the client CRs live in each app's namespace and the namespace-scoped variant only
watches its own.

## How a credential reaches an app

Each app owns its client. There is nothing about a client in this chart - the
`KeycloakOIDCClient` and its `VaultStaticSecret` live in the app's own chart, in the
app's own namespace:

| App | Where |
|---|---|
| Immich | `immich/templates/oidc-client.yaml` |
| Paperless-ngx | `paperless/templates/oidc-client.yaml` |
| ArgoCD | `ArgoCD/templates/oidc-client.yaml` |
| Jellyseerr | `arr-stack/templates/jellyseerr-oidc-client.yaml` |
| Memos | `memos/templates/oidc-client.yaml` |

```
Vault  secret/oidc/<app>   (one client_secret key)
   |
   '- VaultStaticSecret -> Secret/oidc-<app> in the app's namespace
        |- KeycloakOIDCClient reads it via auth.secretRef -> configures Keycloak
        '- the app reads the same Secret
```

Both consumers sit in the same namespace and read the same object, so the two sides
of the integration cannot drift apart. Nothing is generated at render time, so there
is no `ignoreDifferences` anywhere and no drift to suppress - Vault is the source of
truth and a re-sync is a no-op.

Memos is the one exception to "in the app's chart": its upstream chart is published
only as a git repo, so `memos/` is a small local chart carried as an extra source on
the Application. See `.argocd/memosApplication.yaml`.

## Adding a client

1. Add it to the client map in `terraform/oidc-clients.tf` and `terraform apply`.
   That generates the credential, writes it to `secret/oidc/grafana`, and binds the
   new namespace on the Vault role in one step.

2. Add an `oidc:` block to the app's own `values.yaml`:

   ```yaml
   oidc:
     enabled: true
     clientId: grafana
     displayName: Grafana
     keycloakCRName: keycloak
     realm: homelab
     vault:
       mount: secret
       path: oidc/grafana
       refreshAfter: 1h
     redirectUris:
       - https://grafana.gruzin.eu/login/generic_oauth
   ```

3. Copy `oidc-client.yaml` into that chart's `templates/`.

4. Point the app at `Secret/oidc-grafana`, key `client_secret`.

Issuer for any new client: `https://sso.gruzin.eu/realms/homelab`

Two apps need more than the plain template. ArgoCD sets
`destination.labels: {app.kubernetes.io/part-of: argocd}`, without which ArgoCD will
not resolve `$oidc-argocd:client_secret`. Paperless adds a
`destination.transformation.template` that renders its whole
`PAPERLESS_SOCIALACCOUNT_PROVIDERS` JSON from the same Vault value.

## First login

The operator generates the initial admin credentials:

```sh
export KUBECONFIG=~/.kube/config.homelab
kubectl -n keycloak get secret keycloak-initial-admin \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Then create your user in the `homelab` realm and add it to `argocd-admins` if you
want ArgoCD admin via SSO.

## Client status

| Client | App-side config | Wired declaratively |
|---|---|---|
| ArgoCD | `oidc.config` in `argocd-cm`, `$oidc-argocd:client_secret` | yes |
| Paperless-ngx | `PAPERLESS_SOCIALACCOUNT_PROVIDERS` env var | yes |
| Immich | config file + init-container substitution | yes |
| Memos | instance settings UI only | **client only** |
| Jellyseerr | `settings.json` / UI, preview image only | **client only** |

The last two have no file- or env-based OIDC configuration, so although the
Keycloak client and the Secret both exist, the pairing is entered once in the app's
own UI. Neither is a Keycloak limitation and neither would be fixed by a different
IdP.

- **Memos**: Settings → SSO → Create → OAuth2 (custom template). Endpoints are under
  `https://sso.gruzin.eu/realms/homelab/protocol/openid-connect/`.
- **Jellyseerr**: OIDC is still behind the `preview-new-oidc` image tag, which
  `arr-stack` does not pin. The client exists so adopting it later is an image bump
  plus a UI pairing.

Read either credential with:

```sh
kubectl -n memos get secret oidc-memos -o jsonpath='{.data.client_secret}' | base64 -d; echo
```

## Known limitations

- `KeycloakRealmImport` is **create-only** - the operator does not reconcile updates
  or deletions. Edits to `templates/realm.yaml` after the first sync must also be
  made in the Keycloak UI. This is tolerable because the realm only carries the
  shell; clients are separate CRs with full update support.
- `KeycloakOIDCClient` has no field for assigning client scopes, which is why the
  `groups` scope is added to `defaultDefaultClientScopes` in the realm import
  instead. If the groups claim does not appear in tokens after a fresh install,
  check that the scope is attached to the client in the UI.
- `client-admin-api:v2` must stay enabled on the `Keycloak` CR. Without it the
  operator has no client management API and every `KeycloakOIDCClient` fails.
