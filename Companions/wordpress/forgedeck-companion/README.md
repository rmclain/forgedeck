# ForgeDeck Companion for WordPress

A small plugin that exposes the read-only ForgeDeck endpoints through the WordPress REST
API. Contract: `../../contract/README.md`.

**Install it yourself, deliberately.** ForgeDeck never installs this plugin. Try it on a
staging or disposable site first.

## URLs

The routes live in the REST namespace `forgedeck/v1`:

```
https://example.com/wp-json/forgedeck/v1/manifest
https://example.com/wp-json/forgedeck/v1/status
https://example.com/wp-json/forgedeck/v1/metrics?window=24h
https://example.com/wp-json/forgedeck/v1/leads
https://example.com/wp-json/forgedeck/v1/events
```

(With plain permalinks: `https://example.com/?rest_route=/forgedeck/v1/status`.)

Optional rewrite: tick "Also answer at /_forgedeck/v1/…" on the settings page to
additionally serve `https://example.com/_forgedeck/v1/status` etc. It adds one rewrite
rule and needs pretty permalinks. It is off by default.

## Setup

1. Copy the `forgedeck-companion` folder into `wp-content/plugins/` and activate it.
   Activation enables nothing: no token exists and every capability is off.
2. Settings → ForgeDeck Companion (requires `manage_options`):
   - Set the **Product ID** (must match ForgeDeck) and **Environment**.
   - Tick the capabilities you want. All are off by default.
   - Choose scopes and press **Generate token**. The token is displayed once; only its
     SHA-256 hash is stored. **Rotate** replaces it; **Revoke** disables it.
3. Enter the URL and token in ForgeDeck.

Until a product ID and a token exist the endpoints answer `503`; a disabled capability
answers `404`.

## What is exposed

| Capability | Data |
| --- | --- |
| `status` | Release fingerprint from `wp-content/forgedeck-release.json` if present (see `../../contract/deployment-fingerprint.md`), database health |
| `metrics` | `signups`: number of user registrations in the window. With "Include WooCommerce order counts" ticked **and** WooCommerce active: `orders` and `paid_orders` (processing + completed) |
| `leads`, `events` | Nothing by default. Items appear only if your own code supplies them via the filters below |

Aggregate counts only. The plugin does not read or return names, email addresses,
addresses, order contents or order totals.

## Hooks

```php
// Add an aggregate counter. Allowed names: leads, signups, orders, paid_orders,
// paid_conversions, renewals, cancellations. Values must be non-negative integers.
add_filter( 'forgedeck_companion_metrics', function ( $metrics, $window, $seconds ) {
	$metrics['leads'] = my_form_entry_count_since( time() - $seconds );
	return $metrics;
}, 10, 3 );

// Supply lead/event items. Only id, kind, occurred_at, source, title and value_cents are kept.
add_filter( 'forgedeck_companion_leads', function ( $items, $query ) {
	// $query: since, until (unix), after (decoded cursor or null), limit.
	$items[] = array( 'id' => 'evt_form_123', 'kind' => 'lead', 'occurred_at' => 1794751500, 'source' => 'contact_form' );
	return $items;
}, 10, 2 );

// forgedeck_companion_events works the same and also allows kinds deploy and incident.
// forgedeck_companion_health_checks: add array( 'id' => 'cache', 'state' => 'healthy' ).
// forgedeck_companion_release: override the release array.
```

## Security notes

- `permission_callback` on every route: HTTPS (or loopback), bearer token hash check in
  constant time, rate limit (60/min, stored in transients, best effort), optional HMAC
  signature with replay protection, capability, scope.
- Routes are `GET` only and hidden from the REST index. Other methods get `404`.
- Some hosts strip the `Authorization` header before PHP sees it. If every request gets
  `401`, add to `.htaccess`:
  `RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]`
- Request signing (optional): the signing secret must be stored readable in the options
  table, unlike the token. The signed path is the path the client requested, e.g.
  `/wp-json/forgedeck/v1/status`.
- Behind a load balancer that terminates TLS, WordPress must either detect HTTPS itself
  (`is_ssl()`) or you tick "Trust X-Forwarded-Proto".
- Page caches must not cache `/wp-json/forgedeck/` (responses send `Cache-Control: no-store`).
- Uninstalling deletes all plugin options. Deactivating stops serving immediately.

## Tests (no WordPress needed)

```sh
php tests/run-tests.php        # pure functions: hashing, verification, scopes, windows, signatures, ...
php tests/run-rest-tests.php   # the REST gate and handlers against in-memory WordPress stubs
find . -name '*.php' -exec php -l {} \;
```

The stub-based tests are a safety net; they do not replace trying the plugin on a
disposable WordPress install. The settings page and the WooCommerce counts have not been
exercised by automated tests. Leave `tests/` out when you copy the plugin to a site.
