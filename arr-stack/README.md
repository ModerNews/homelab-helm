# arr-stack: tags, subtitles and request routing

How anime and non-anime are separated without separate instances, and how tags
carry that separation from Jellyseerr through Sonarr/Radarr into Bazarr.

Written against the versions this chart actually runs. Behaviour below was
verified against these, not taken from documentation - the Bazarr wiki's settings
page is self-declared outdated, so the settings names here come from the live
`/api/system/settings` response.

| component  | version       |
|------------|---------------|
| Sonarr     | 4.0.20.3014   |
| Radarr     | v5            |
| Bazarr     | 1.6.1         |
| Jellyseerr | 3.4.1         |
| Recyclarr  | 8.7.2         |

---

## Topology, and why it is one instance each

One Sonarr, one Radarr, one Bazarr. Anime is differentiated *within* Sonarr
rather than by running a second copy.

Sonarr already separates anime per series:

- **Series Type: Anime** - absolute episode numbering and anime-style parsing
- **Quality Profile** - per series, so `[Anime] Remux-1080p` and `WEB-1080p` coexist
- **Root Folder** - per series, so anime lands in `/data/contents/anime`
- **Tags** - per series, used for release profiles and for Bazarr (below)

The single thing that is **not** per-series is the **quality definition** - the
MB/min size table under Settings -> Quality. It is one table per instance. The
API makes this explicit: a quality definition object has `minSize`, `maxSize`,
`preferredSize` and no `profileId` or `tags` field, while a quality *profile*
has no size fields at all.

This matters because the TRaSH tables differ sharply:

| quality             | `series` min | `anime` min |
|---------------------|--------------|-------------|
| WEBDL-1080p         | 15 MB/min    | 5 MB/min    |
| Bluray-1080p        | 50.4         | 5           |
| Bluray-1080p Remux  | 69.1         | 5           |

Anime compresses well; a good 1080p anime WEB release often sits at 6-8 MB/min
and the `series` table would reject it as too small. So this chart sets
`quality_definition: anime` instance-wide and accepts that live action loses its
size floor, leaning on custom format scoring to reject weak encodes instead.

**If you ever want the live-action size floor back, that is the one reason to
split Sonarr again.** Nothing else here requires it.

A second consequence, in Bazarr's favour: Bazarr connects to exactly one Sonarr
(`settings.sonarr` is an object, not a list). One Sonarr means one Bazarr.

---

## Bazarr: language profiles and tags

### Profiles, not providers

Tags assign **language profiles**. They do not select providers.
`general.enabled_providers` is a flat, instance-wide list - every enabled
provider is queried for every item, and results are ranked by score. There is no
per-series or per-tag provider routing.

This is usually fine: **animesub.info (ANSI) only indexes Polish anime
subtitles**, so it returns nothing for live action on its own. Provider
separation happens by catalogue, not configuration. Enable ANSI alongside
OpenSubtitles and let it self-limit.

### One profile per item

An item gets exactly **one** language profile. Two single-language profiles
(`Polish`, `English`) means a series is Polish-or-English, never both. For both
languages, use one profile with two language items and **cutoff: none** - a
cutoff stops fetching once that language is satisfied.

### The settings that matter

From `/api/system/settings`, under `general`:

| setting                  | purpose                                              |
|--------------------------|------------------------------------------------------|
| `serie_default_enabled`  | auto-assign a profile to every new series             |
| `serie_default_profile`  | which profile that is                                 |
| `movie_default_enabled`  | same, for movies                                      |
| `movie_default_profile`  | which profile that is                                 |
| `serie_tag_enabled`      | let Sonarr tags assign profiles                       |
| `movie_tag_enabled`      | let Radarr tags assign profiles                       |
| `remove_profile_tags`    | tags that *strip* a profile instead of assigning one  |

and per language profile, a `tag` field - the Sonarr/Radarr tag that selects it.

Under `sonarr` / `radarr`, `excluded_tags` is separate and blunter: it excludes
tagged items from Bazarr entirely.

### Defaults and tags work together

Defaults catch everything; tags override specific items. Enable both - tags
alone leave untagged items with no profile and therefore no subtitles.

---

## The intended setup

The goal here: **English everywhere, Polish only for anime and for specific
requests.**

### 1. Language profiles

Create two:

| name    | languages | cutoff | tag         |
|---------|-----------|--------|-------------|
| `EN`    | en        | none   | *(empty)*   |
| `PL+EN` | pl, en    | none   | `subs-pl`   |

`cutoff: none` on `PL+EN` matters - with a cutoff at `pl`, English never gets
fetched.

### 2. Defaults

```
serie_default_enabled = true    serie_default_profile = EN
movie_default_enabled = true    movie_default_profile = EN
serie_tag_enabled     = true
movie_tag_enabled     = true
```

Everything gets English automatically. Anything tagged `subs-pl` in Sonarr or
Radarr gets `PL+EN` instead.

Note `serie_default_profile` and `movie_default_profile` are independent, so one
Bazarr can apply different defaults to series and movies.

### 3. Tag anime in Sonarr

Tag anime series `subs-pl`. Since anime already needs a distinct quality profile
and root folder, add the tag while setting those - it is the same screen.

### 4. Providers

Enable **OpenSubtitles** and **ANSI**. Configure **AniDB** - it drives anime
episode matching, which is what makes ANSI lookups resolve correctly.

---

## Jellyseerr: routing requests

### Anime fields, not a second server

Each Sonarr entry under Settings -> Services carries a parallel set of anime
fields:

```
activeProfileId       activeAnimeProfileId
activeDirectory       activeAnimeDirectory
activeLanguageProfileId  activeAnimeLanguageProfileId
tags                  animeTags
```

Jellyseerr detects anime and applies the `Anime*` variants **on the selected
server**. So one Sonarr entry handles both:

```
series -> /data/contents/tvseries  [WEB-1080p]
anime  -> /data/contents/anime     [[Anime] Remux-1080p]   animeTags: subs-pl
```

Setting `animeTags: subs-pl` closes the loop: Jellyseerr tags the anime request,
Sonarr stores the tag, Bazarr sees it and assigns `PL+EN`. No manual tagging.

> **Do not point the anime fields at the non-anime folder/profile.** If
> `activeAnimeDirectory` equals `activeDirectory`, anime is silently treated as
> ordinary series - the most common misconfiguration here.

### Per-user tags

`tagRequests: true` makes Jellyseerr tag every request with the requesting user
(`1-gruzin`, `2-someone`). Point a language profile's `tag` at one of those and
that person's requests get Polish automatically.

### Override rules

Jellyseerr 2.2+ supports override rules (`/api/v1/overrideRule`) matching on
genre, keyword, or user, and applying a different **root folder, quality profile
or tags**.

For "Polish subs on anime movies", where Radarr has no anime fields of its own,
a rule matching the `Animation` genre or an `anime` keyword and applying tag
`subs-pl` is the clean way to do it.

**Override rules cannot switch to a different Sonarr/Radarr instance** - they
only modify parameters on the selected one ([jellyseerr#1560]). This is another
reason the single-instance layout is the supported path: a two-instance split
cannot be driven from Jellyseerr's rules alone.

---

## End-to-end

```
Jellyseerr request
  ├─ anime?  → activeAnimeProfileId / activeAnimeDirectory / animeTags: subs-pl
  ├─ rule?   → override rule applies tags (e.g. Animation genre → subs-pl)
  └─ user?   → tagRequests adds "1-gruzin"
        ↓
Sonarr / Radarr   (tag stored on the series/movie)
        ↓
Bazarr            serie_tag_enabled / movie_tag_enabled
                  tag subs-pl → PL+EN profile, otherwise default EN
        ↓
Subtitles         OpenSubtitles (all) + ANSI (Polish anime only)
```

---

## Gotchas

**Recyclarr instance names must be unique across services.** `--instance` takes
a bare name with no service qualifier, so `main` under both sonarr and radarr
collides and recyclarr **silently drops both** - visible only as
`[DBG] Duplicate instances: ["main"]` at debug level. Hence `series` and
`movies` in `values.yaml`.

**Recyclarr custom format groups apply to every profile in an instance** unless
scoped with `assign_scores_to`. With two profiles under one Sonarr, unscoped
live-action groups would land on the anime profile too.

**Recyclarr `include:` no longer resolves.** As of 8.x the official
config-templates provider ships zero includes - `config list templates
--includes` returns 0. Use `recyclarr config create -t <template>` and inline
the result.

**Sonarr's `AllowedHosts` breaks in-cluster callers.** Setting it to only the
external hostname makes Kestrel reject every request whose `Host` header differs
with `400 Invalid Hostname`, including Prowlarr, Bazarr, recyclarr and homepage.
Include the service DNS names, or leave it empty.

**`DisabledForLocalAddresses` does nothing behind Traefik.** Sonarr logs
`Unknown proxy` and refuses to treat proxied requests as local, so the login
page still appears. Reach it directly (`kubectl port-forward`) if you need to
bypass auth.

**Jellyseerr root folders must match Radarr/Sonarr.** `activeDirectory` is
stored in Jellyseerr independently; if a mount layout changes (for example
`/movies` becoming `/data/contents/movies`), requests point at a root folder
that no longer exists.

---

## References

- [Recyclarr - custom format groups](https://recyclarr.dev/guide/cf-groups/)
- [jellyseerr#1560 - override rules cannot target instances][jellyseerr#1560]
- [Bazarr wiki - settings](https://wiki.bazarr.media/Additional-Configuration/Settings/) (marked outdated upstream; prefer `/api/system/settings`)
- [TRaSH Guides - Sonarr quality profiles](https://trash-guides.info/Sonarr/sonarr-setup-quality-profiles/)
- [TRaSH Guides - Radarr quality profiles](https://trash-guides.info/Radarr/radarr-setup-quality-profiles/)

[jellyseerr#1560]: https://github.com/fallenbagel/jellyseerr/issues/1560
