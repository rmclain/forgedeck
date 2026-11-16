# Deployment fingerprint

ForgeDeck compares the commit it sees in your repository with the commit that is actually
running. For that, the running system has to know what it is. The recipe: **CI writes a
small JSON file into the build artifact, and the companion's status endpoint serves it.**

Do not compute the SHA at runtime (`git rev-parse` in production is slow, usually
impossible because `.git` is not shipped, and reports the wrong thing after a hot-fix copy).

## The file: `forgedeck-release.json`

```json
{
  "commit_sha": "0123456789abcdef0123456789abcdef01234567",
  "version": "1.8.2",
  "build_id": "4821",
  "built_at": "2026-11-14T12:21:07Z"
}
```

(Example values, not live data.)

| Field | Required | Meaning |
| --- | --- | --- |
| `commit_sha` | yes | Full 40-character Git SHA of the built commit |
| `version` | recommended | Human version: a tag (`v1.8.2`), `package.json` version, or `git describe` output |
| `build_id` | recommended | CI run identifier, unique per build |
| `built_at` | yes | UTC build time, `YYYY-MM-DDTHH:MM:SSZ` |
| `deployed_at` | optional | UTC time this build went live, if your deploy step can write it |

Rules:

- The file contains **no secrets**. It is safe to bake into an image.
- Write it once per build, into the artifact (image layer, release tarball, upload
  bundle), not onto a shared volume that outlives a deploy.
- Never commit it. `Companions/.gitignore` ignores `forgedeck-release.json`; add the same
  line to your product's `.gitignore`.
- If `deployed_at` is absent the companions report `built_at` as `deployed_at`. For an
  exact deploy time, have the deploy step add the field (see below).

## How each companion reads it

| Package | How |
| --- | --- |
| Node | `providers: { release: loadReleaseFile(process.env.FORGEDECK_RELEASE_FILE \|\| 'forgedeck-release.json') }` |
| Python | `CompanionConfig(release=load_release_file(os.environ.get("FORGEDECK_RELEASE_FILE", "forgedeck-release.json")))` |
| WordPress | Reads `wp-content/forgedeck-release.json`; override the path with `define( 'FORGEDECK_RELEASE_FILE', '/path/file.json' );` in `wp-config.php` |

Load the file once at start-up (Node, Python). A missing or invalid file yields
`commit_sha: null`, which ForgeDeck shows as "revision unknown" rather than guessing.

## GitHub Actions

```yaml
name: build

on:
  push:
    branches: [main]
    tags: ['v*']

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # tags are needed for `git describe`

      - name: Write forgedeck-release.json
        env:
          COMMIT_SHA: ${{ github.sha }}
          BUILD_ID: ${{ github.run_id }}-${{ github.run_attempt }}
          REF_TYPE: ${{ github.ref_type }}
          REF_NAME: ${{ github.ref_name }}
        run: |
          set -euo pipefail
          if [ "$REF_TYPE" = "tag" ]; then
            VERSION="$REF_NAME"
          else
            VERSION="$(git describe --tags --always --dirty)"
          fi
          BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          jq -n \
            --arg commit_sha "$COMMIT_SHA" \
            --arg version "$VERSION" \
            --arg build_id "$BUILD_ID" \
            --arg built_at "$BUILT_AT" \
            '{commit_sha: $commit_sha, version: $version, build_id: $build_id, built_at: $built_at}' \
            > forgedeck-release.json
          cat forgedeck-release.json

      # ...then build the artifact so that it CONTAINS the file, for example:
      - name: Build image
        run: docker build -t example/app:${{ github.sha }} .
```

Values are passed through `env:` and `jq --arg` rather than interpolated into the script,
so a branch or tag name cannot inject shell or JSON.

### Dockerfile

```dockerfile
# The file was written by CI before `docker build`, so it is part of the build context.
COPY forgedeck-release.json /app/forgedeck-release.json
ENV FORGEDECK_RELEASE_FILE=/app/forgedeck-release.json
```

Make sure `.dockerignore` does not exclude `forgedeck-release.json`.

### Recording the deploy time (optional)

In the deploy job, after the new version is live, on the target:

```sh
tmp="$(mktemp)"
jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {deployed_at: $t}' forgedeck-release.json > "$tmp"
mv "$tmp" forgedeck-release.json
```

On immutable platforms where the artifact cannot be edited, pass the time as an
environment variable instead and merge it in your release provider:

```js
release: () => ({ ...loadReleaseFile('forgedeck-release.json'), deployed_at: process.env.DEPLOYED_AT })
```

### WordPress

For a site deployed by CI (rsync, SFTP, or a release zip), write the file in the same
step and ship it as `wp-content/forgedeck-release.json`. Block direct web access to it if
you prefer not to expose the SHA without a token (it is not secret, but there is no reason
to publish it):

```apache
# wp-content/.htaccess
<Files "forgedeck-release.json">
  Require all denied
</Files>
```

```nginx
location = /wp-content/forgedeck-release.json { deny all; }
```

## Multi-instance deployments

Each instance serves its own baked-in file, so during a rolling deploy consecutive status
requests may report different SHAs. If you have a registry of instances (orchestrator API,
heartbeat table), also return the optional `instances` list from the status endpoint so
ForgeDeck can show "2 of 3 on new revision":

```json
"instances": [
  {"id": "web-1", "commit_sha": "0123456789abcdef0123456789abcdef01234567"},
  {"id": "web-2", "commit_sha": "fedcba9876543210fedcba9876543210fedcba98"}
]
```

## Verifying

```sh
curl -s -H "Authorization: Bearer $FORGEDECK_TOKEN" https://app.example.com/_forgedeck/v1/status | jq .release
git rev-parse HEAD   # on the commit you believe is deployed
```
