<?php
/**
 * Pure helper functions for the ForgeDeck companion.
 *
 * This file has no side effects and calls no WordPress functions, so it can be
 * loaded and tested without WordPress (see tests/run-tests.php).
 *
 * @package ForgeDeck_Companion
 */

const FORGEDECK_SCHEMA_VERSION   = '1.0';
const FORGEDECK_MAX_SKEW_SECONDS = 300;
const FORGEDECK_MAX_LIMIT        = 100;
const FORGEDECK_DEFAULT_LIMIT    = 50;
const FORGEDECK_MAX_RANGE        = 7776000; // 90 days.

/** @return string[] */
function forgedeck_scopes() {
	return array( 'status:read', 'metrics:read', 'leads:read', 'events:read' );
}

/** @return string[] */
function forgedeck_capabilities() {
	return array( 'status', 'metrics', 'leads', 'events' );
}

/** @return string[] */
function forgedeck_environments() {
	return array( 'production', 'staging', 'development', 'preview', 'test' );
}

/** @return array<string,int> window key => seconds */
function forgedeck_windows() {
	return array(
		'24h' => 86400,
		'7d'  => 604800,
		'30d' => 2592000,
		'90d' => 7776000,
	);
}

/** @return string[] */
function forgedeck_lead_kinds() {
	return array( 'lead', 'signup', 'paid_conversion', 'renewal', 'cancellation' );
}

/** @return string[] */
function forgedeck_event_kinds() {
	return array_merge( forgedeck_lead_kinds(), array( 'deploy', 'incident' ) );
}

/** @return string[] metric names this plugin may ever emit */
function forgedeck_allowed_metrics() {
	return array( 'leads', 'signups', 'orders', 'paid_orders', 'paid_conversions', 'renewals', 'cancellations' );
}

/**
 * Route => required scope and capability (null capability = any authenticated token with the scope).
 *
 * @return array<string,array{scope:string,capability:?string}>
 */
function forgedeck_routes() {
	return array(
		'manifest' => array( 'scope' => 'status:read', 'capability' => null ),
		'status'   => array( 'scope' => 'status:read', 'capability' => 'status' ),
		'metrics'  => array( 'scope' => 'metrics:read', 'capability' => 'metrics' ),
		'leads'    => array( 'scope' => 'leads:read', 'capability' => 'leads' ),
		'events'   => array( 'scope' => 'events:read', 'capability' => 'events' ),
	);
}

/* ------------------------------------------------------------------ tokens */

/**
 * Generate a new random bearer token (256 bits). Show it once; store only its hash.
 *
 * @return string
 */
function forgedeck_generate_token() {
	return 'fdk_' . rtrim( strtr( base64_encode( random_bytes( 32 ) ), '+/', '-_' ), '=' );
}

/**
 * SHA-256 hex digest of a token. Only this digest is stored.
 *
 * @param string $token Plaintext token.
 * @return string
 */
function forgedeck_hash_token( $token ) {
	return hash( 'sha256', (string) $token );
}

/**
 * Extract the token from an "Authorization: Bearer <token>" header value.
 *
 * @param mixed $header Header value.
 * @return string|null
 */
function forgedeck_extract_bearer( $header ) {
	if ( ! is_string( $header ) || strlen( $header ) > 600 ) {
		return null;
	}
	if ( 1 !== preg_match( '/^Bearer ([A-Za-z0-9._~+\/-]{1,512}={0,2})$/D', trim( $header ), $m ) ) {
		return null;
	}
	return $m[1];
}

/**
 * Verify a presented token against stored records using constant-time digest comparison.
 *
 * Each record: array( 'id' => string, 'hash' => sha256 hex, 'scopes' => string[],
 * 'revoked' => bool, 'expires_at' => int|null (unix seconds) ).
 *
 * @param mixed $presented Presented plaintext token.
 * @param array $records   Stored token records.
 * @param int   $now       Current unix time.
 * @return array{ok:bool,reason:string,record:?array}
 */
function forgedeck_verify_token( $presented, array $records, $now ) {
	if ( ! is_string( $presented ) || '' === $presented ) {
		return array( 'ok' => false, 'reason' => 'missing', 'record' => null );
	}
	$digest = forgedeck_hash_token( $presented );
	$match  = null;
	foreach ( $records as $record ) {
		if ( ! is_array( $record ) || empty( $record['hash'] ) || ! is_string( $record['hash'] ) ) {
			continue;
		}
		if ( 1 !== preg_match( '/^[0-9a-f]{64}$/D', $record['hash'] ) ) {
			continue;
		}
		// No early exit: every record is compared.
		if ( hash_equals( $record['hash'], $digest ) && null === $match ) {
			$match = $record;
		}
	}
	if ( null === $match ) {
		return array( 'ok' => false, 'reason' => 'unknown', 'record' => null );
	}
	if ( ! empty( $match['revoked'] ) ) {
		return array( 'ok' => false, 'reason' => 'revoked', 'record' => $match );
	}
	if ( isset( $match['expires_at'] ) && null !== $match['expires_at'] && $now >= (int) $match['expires_at'] ) {
		return array( 'ok' => false, 'reason' => 'expired', 'record' => $match );
	}
	return array( 'ok' => true, 'reason' => '', 'record' => $match );
}

/**
 * Does the token record carry the scope?
 *
 * @param mixed  $record Token record.
 * @param string $scope  Scope name.
 * @return bool
 */
function forgedeck_has_scope( $record, $scope ) {
	return is_array( $record ) && isset( $record['scopes'] ) && is_array( $record['scopes'] )
		&& in_array( $scope, $record['scopes'], true )
		&& in_array( $scope, forgedeck_scopes(), true );
}

/**
 * Keep only known scopes, in canonical order.
 *
 * @param mixed $scopes Raw scopes.
 * @return string[]
 */
function forgedeck_sanitize_scopes( $scopes ) {
	if ( ! is_array( $scopes ) ) {
		return array();
	}
	return array_values( array_filter( forgedeck_scopes(), static function ( $s ) use ( $scopes ) {
		return in_array( $s, $scopes, true );
	} ) );
}

/* ------------------------------------------------------------------ windows, limits */

/**
 * Validate a metrics window. Returns its length in seconds, or null if not allowed.
 *
 * @param mixed $window Raw window parameter.
 * @return int|null
 */
function forgedeck_validate_window( $window ) {
	if ( ! is_string( $window ) ) {
		return null;
	}
	$windows = forgedeck_windows();
	return array_key_exists( $window, $windows ) ? $windows[ $window ] : null;
}

/**
 * Parse a page-size limit: integer 1..100, else null.
 *
 * @param mixed $raw Raw parameter.
 * @return int|null
 */
function forgedeck_parse_limit( $raw ) {
	if ( ! is_string( $raw ) || 1 !== preg_match( '/^[0-9]{1,4}$/D', $raw ) ) {
		return null;
	}
	$n = (int) $raw;
	return ( $n >= 1 && $n <= FORGEDECK_MAX_LIMIT ) ? $n : null;
}

/**
 * Parse a strict ISO-8601 timestamp to unix seconds, or null.
 *
 * @param mixed $raw Raw value.
 * @return int|null
 */
function forgedeck_parse_time( $raw ) {
	if ( ! is_string( $raw ) || 1 !== preg_match( '/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/D', $raw ) ) {
		return null;
	}
	$normalized = preg_replace( '/\.\d+/', '', $raw );
	$dt         = DateTimeImmutable::createFromFormat( 'Y-m-d\TH:i:sP', str_replace( 'Z', '+00:00', $normalized ) );
	$errors     = DateTimeImmutable::getLastErrors();
	if ( false === $dt || ( is_array( $errors ) && ( $errors['warning_count'] > 0 || $errors['error_count'] > 0 ) ) ) {
		return null;
	}
	return $dt->getTimestamp();
}

/**
 * Format unix seconds as 2026-11-15T16:00:00Z.
 *
 * @param int $timestamp Unix seconds.
 * @return string
 */
function forgedeck_iso( $timestamp ) {
	return gmdate( 'Y-m-d\TH:i:s\Z', (int) $timestamp );
}

/**
 * Resolve the since/until range for list endpoints.
 *
 * @param mixed $since_raw Raw since (or null).
 * @param mixed $until_raw Raw until (or null).
 * @param int   $now       Current unix time.
 * @return array{ok:bool,code?:string,message?:string,since?:int,until?:int}
 */
function forgedeck_resolve_range( $since_raw, $until_raw, $now ) {
	$until = $now;
	if ( null !== $until_raw ) {
		$until = forgedeck_parse_time( $until_raw );
		if ( null === $until ) {
			return array( 'ok' => false, 'code' => 'invalid_time', 'message' => 'until must be an ISO-8601 timestamp such as 2026-11-15T16:00:00Z' );
		}
	}
	$since = $until - FORGEDECK_MAX_RANGE;
	if ( null !== $since_raw ) {
		$since = forgedeck_parse_time( $since_raw );
		if ( null === $since ) {
			return array( 'ok' => false, 'code' => 'invalid_time', 'message' => 'since must be an ISO-8601 timestamp such as 2026-11-15T16:00:00Z' );
		}
	}
	if ( $since >= $until ) {
		return array( 'ok' => false, 'code' => 'invalid_range', 'message' => 'since must be earlier than until' );
	}
	if ( $until - $since > FORGEDECK_MAX_RANGE ) {
		return array( 'ok' => false, 'code' => 'invalid_range', 'message' => 'time range must not exceed 90 days' );
	}
	return array( 'ok' => true, 'since' => $since, 'until' => $until );
}

/* ------------------------------------------------------------------ signing */

/**
 * The signed string: "<timestamp>\n<METHOD>\n<path-with-query>".
 *
 * @param string $timestamp       Unix seconds as sent.
 * @param string $method          HTTP method.
 * @param string $path_with_query Request target as sent by the client.
 * @return string
 */
function forgedeck_canonical_string( $timestamp, $method, $path_with_query ) {
	return $timestamp . "\n" . strtoupper( $method ) . "\n" . $path_with_query;
}

/**
 * Hex HMAC-SHA256 signature for a request.
 *
 * @param string $secret          Signing secret.
 * @param string $timestamp       Unix seconds.
 * @param string $method          HTTP method.
 * @param string $path_with_query Request target.
 * @return string
 */
function forgedeck_sign_request( $secret, $timestamp, $method, $path_with_query ) {
	return hash_hmac( 'sha256', forgedeck_canonical_string( $timestamp, $method, $path_with_query ), (string) $secret );
}

/**
 * Verify a request signature and its timestamp freshness.
 *
 * @param string $secret          Signing secret.
 * @param mixed  $timestamp       X-ForgeDeck-Timestamp header.
 * @param mixed  $signature       X-ForgeDeck-Signature header.
 * @param string $method          HTTP method.
 * @param string $path_with_query Request target.
 * @param int    $now             Current unix time.
 * @param int    $max_skew        Allowed clock skew in seconds.
 * @return array{ok:bool,reason:string}
 */
function forgedeck_verify_signature( $secret, $timestamp, $signature, $method, $path_with_query, $now, $max_skew = FORGEDECK_MAX_SKEW_SECONDS ) {
	if ( ! is_string( $timestamp ) || 1 !== preg_match( '/^[0-9]{1,12}$/D', $timestamp ) ) {
		return array( 'ok' => false, 'reason' => 'bad_timestamp' );
	}
	if ( ! is_string( $signature ) || 1 !== preg_match( '/^[0-9a-fA-F]{64}$/D', $signature ) ) {
		return array( 'ok' => false, 'reason' => 'bad_signature' );
	}
	if ( abs( (int) $now - (int) $timestamp ) > $max_skew ) {
		return array( 'ok' => false, 'reason' => 'stale_timestamp' );
	}
	$expected = forgedeck_sign_request( $secret, $timestamp, $method, $path_with_query );
	if ( ! hash_equals( $expected, strtolower( $signature ) ) ) {
		return array( 'ok' => false, 'reason' => 'bad_signature' );
	}
	return array( 'ok' => true, 'reason' => '' );
}

/**
 * Storage key for the replay cache entry of a (timestamp, signature) pair.
 *
 * @param string $timestamp Timestamp header.
 * @param string $signature Signature header.
 * @return string
 */
function forgedeck_nonce_key( $timestamp, $signature ) {
	return 'forgedeck_nonce_' . substr( hash( 'sha256', $timestamp . ':' . strtolower( $signature ) ), 0, 40 );
}

/* ------------------------------------------------------------------ rate limiting, transport */

/**
 * One step of a fixed-window rate limiter. Pure: the caller persists the returned bucket.
 *
 * @param mixed $bucket Previous bucket array( 'start' => int, 'count' => int ) or anything else.
 * @param int   $now    Current unix time.
 * @param int   $limit  Requests allowed per window.
 * @param int   $window Window length in seconds.
 * @return array{allowed:bool,retry_after:int,bucket:array{start:int,count:int}}
 */
function forgedeck_rate_limit_step( $bucket, $now, $limit = 60, $window = 60 ) {
	if ( ! is_array( $bucket ) || ! isset( $bucket['start'], $bucket['count'] ) || $now - (int) $bucket['start'] >= $window ) {
		$bucket = array( 'start' => (int) $now, 'count' => 0 );
	}
	$bucket['count'] = (int) $bucket['count'] + 1;
	if ( $bucket['count'] > $limit ) {
		return array(
			'allowed'     => false,
			'retry_after' => max( 1, (int) $bucket['start'] + $window - (int) $now ),
			'bucket'      => $bucket,
		);
	}
	return array( 'allowed' => true, 'retry_after' => 0, 'bucket' => $bucket );
}

/**
 * Is the address a loopback address?
 *
 * @param mixed $addr Remote address.
 * @return bool
 */
function forgedeck_is_loopback( $addr ) {
	if ( ! is_string( $addr ) ) {
		return false;
	}
	if ( 0 === strpos( $addr, '::ffff:' ) ) {
		$addr = substr( $addr, 7 );
	}
	return '::1' === $addr || 1 === preg_match( '/^127(\.\d{1,3}){3}$/D', $addr );
}

/**
 * Decide whether the request arrived over an acceptable transport.
 *
 * @param bool   $is_ssl      Whether the connection to PHP is TLS.
 * @param mixed  $remote_addr REMOTE_ADDR.
 * @param bool   $trust_proxy Whether X-Forwarded-Proto may be trusted (operator opt-in).
 * @param mixed  $forwarded   X-Forwarded-Proto header value.
 * @return bool
 */
function forgedeck_is_secure_request( $is_ssl, $remote_addr, $trust_proxy, $forwarded ) {
	if ( $trust_proxy && is_string( $forwarded ) && '' !== $forwarded ) {
		$parts = explode( ',', $forwarded );
		return 'https' === strtolower( trim( $parts[0] ) );
	}
	if ( $is_ssl ) {
		return true;
	}
	return forgedeck_is_loopback( $remote_addr );
}

/* ------------------------------------------------------------------ cursors, redaction */

/**
 * Opaque cursor: base64url(JSON {v, t, id}) of the last item returned.
 *
 * @param string $occurred_at ISO timestamp.
 * @param string $id          Item id.
 * @return string
 */
function forgedeck_encode_cursor( $occurred_at, $id ) {
	$json = json_encode( array( 'v' => 1, 't' => $occurred_at, 'id' => $id ), JSON_UNESCAPED_SLASHES );
	return rtrim( strtr( base64_encode( $json ), '+/', '-_' ), '=' );
}

/**
 * Decode a cursor. Returns array( 't' => unix seconds, 'id' => string ) or null.
 *
 * @param mixed $cursor Raw cursor.
 * @return array{t:int,id:string}|null
 */
function forgedeck_decode_cursor( $cursor ) {
	if ( ! is_string( $cursor ) || '' === $cursor || strlen( $cursor ) > 512 || 1 !== preg_match( '/^[A-Za-z0-9_-]+$/D', $cursor ) ) {
		return null;
	}
	$raw = base64_decode( strtr( $cursor, '-_', '+/' ), true );
	if ( false === $raw ) {
		return null;
	}
	$obj = json_decode( $raw, true );
	if ( ! is_array( $obj ) || ! isset( $obj['v'], $obj['t'], $obj['id'] ) || 1 !== $obj['v'] ) {
		return null;
	}
	if ( ! is_string( $obj['id'] ) || '' === $obj['id'] || strlen( $obj['id'] ) > 128 ) {
		return null;
	}
	$t = forgedeck_parse_time( $obj['t'] );
	if ( null === $t ) {
		return null;
	}
	return array( 't' => $t, 'id' => $obj['id'] );
}

/**
 * "john@example.com" => "j***@e***.com"; null if not email-shaped.
 *
 * @param mixed $email Raw address.
 * @return string|null
 */
function forgedeck_mask_email( $email ) {
	if ( ! is_string( $email ) || 1 !== preg_match( '/^([^@\s]+)@([^@\s.]+)((?:\.[^@\s.]+)*)\.([^@\s.]+)$/D', trim( $email ), $m ) ) {
		return null;
	}
	return strtolower( substr( $m[1], 0, 1 ) . '***@' . substr( $m[2], 0, 1 ) . '***.' . $m[4] );
}

/**
 * Trim, strip control characters and cap the length of a display string.
 *
 * @param mixed $value Raw value.
 * @param int   $max   Maximum length.
 * @return string|null
 */
function forgedeck_short_string( $value, $max ) {
	if ( ! is_string( $value ) && ! is_int( $value ) && ! is_float( $value ) ) {
		return null;
	}
	$s = trim( preg_replace( '/[\x00-\x1f\x7f]/', ' ', (string) $value ) );
	return '' === $s ? null : substr( $s, 0, $max );
}

/**
 * Keep only whitelisted, integer-valued counters.
 *
 * @param mixed    $raw     Raw metrics.
 * @param string[] $allowed Allowed metric names.
 * @return array<string,int>
 */
function forgedeck_sanitize_metrics( $raw, array $allowed ) {
	$out = array();
	if ( ! is_array( $raw ) ) {
		return $out;
	}
	foreach ( $allowed as $name ) {
		if ( isset( $raw[ $name ] ) && is_int( $raw[ $name ] ) && $raw[ $name ] >= 0 ) {
			$out[ $name ] = $raw[ $name ];
		}
	}
	return $out;
}

/**
 * Whitelist the fields of a lead/event item. Nothing outside this list is ever emitted.
 *
 * @param mixed    $raw          Raw item.
 * @param string[] $kinds        Allowed kinds.
 * @param bool     $masked_label Whether to add a masked label from $raw['email'].
 * @return array|null array( 'item' => array, 't' => int ) or null.
 */
function forgedeck_sanitize_item( $raw, array $kinds, $masked_label = false ) {
	if ( ! is_array( $raw ) || ! isset( $raw['id'], $raw['kind'], $raw['occurred_at'] ) ) {
		return null;
	}
	if ( ! is_string( $raw['id'] ) || 1 !== preg_match( '/^[A-Za-z0-9_.:-]{1,128}$/D', $raw['id'] ) ) {
		return null;
	}
	if ( ! in_array( $raw['kind'], $kinds, true ) ) {
		return null;
	}
	$t = is_int( $raw['occurred_at'] ) ? $raw['occurred_at'] : forgedeck_parse_time( $raw['occurred_at'] );
	if ( null === $t ) {
		return null;
	}
	$titles = array(
		'lead'            => 'New lead',
		'signup'          => 'New signup',
		'paid_conversion' => 'Paid conversion',
		'renewal'         => 'Renewal',
		'cancellation'    => 'Cancellation',
		'deploy'          => 'Deploy',
		'incident'        => 'Incident',
	);
	$title  = isset( $raw['title'] ) ? forgedeck_short_string( $raw['title'], 120 ) : null;
	$source = ( isset( $raw['source'] ) && is_string( $raw['source'] ) && 1 === preg_match( '/^[A-Za-z0-9_.-]{1,64}$/D', $raw['source'] ) ) ? $raw['source'] : 'unknown';
	$item   = array(
		'id'          => $raw['id'],
		'kind'        => $raw['kind'],
		'occurred_at' => forgedeck_iso( $t ),
		'source'      => $source,
		'title'       => null !== $title ? $title : $titles[ $raw['kind'] ],
		'value_cents' => ( isset( $raw['value_cents'] ) && is_int( $raw['value_cents'] ) ) ? $raw['value_cents'] : null,
	);
	if ( $masked_label && isset( $raw['email'] ) ) {
		$label = forgedeck_mask_email( $raw['email'] );
		if ( null !== $label ) {
			$item['label'] = $label;
		}
	}
	return array( 'item' => $item, 't' => $t );
}

/**
 * Sanitize, filter, order and page raw items.
 *
 * @param mixed      $raw_items    Raw items from the site.
 * @param string[]   $kinds        Allowed kinds.
 * @param int        $since        Range start (unix).
 * @param int        $until        Range end (unix).
 * @param array|null $after        Decoded cursor or null.
 * @param int        $limit        Page size.
 * @param bool       $masked_label Whether to add masked labels.
 * @return array{items:array,next_cursor:?string}
 */
function forgedeck_paginate( $raw_items, array $kinds, $since, $until, $after, $limit, $masked_label = false ) {
	$rows = array();
	foreach ( is_array( $raw_items ) ? $raw_items : array() as $raw ) {
		$s = forgedeck_sanitize_item( $raw, $kinds, $masked_label );
		if ( null === $s || $s['t'] < $since || $s['t'] > $until ) {
			continue;
		}
		if ( null !== $after && ! ( $s['t'] > $after['t'] || ( $s['t'] === $after['t'] && strcmp( $s['item']['id'], $after['id'] ) > 0 ) ) ) {
			continue;
		}
		$rows[] = $s;
	}
	usort( $rows, static function ( $a, $b ) {
		if ( $a['t'] !== $b['t'] ) {
			return $a['t'] < $b['t'] ? -1 : 1;
		}
		return strcmp( $a['item']['id'], $b['item']['id'] );
	} );
	$page  = array_slice( $rows, 0, $limit );
	$items = array();
	foreach ( $page as $row ) {
		$items[] = $row['item'];
	}
	$next = null;
	if ( count( $rows ) > $limit && ! empty( $items ) ) {
		$last = $items[ count( $items ) - 1 ];
		$next = forgedeck_encode_cursor( $last['occurred_at'], $last['id'] );
	}
	return array( 'items' => $items, 'next_cursor' => $next );
}

/**
 * Normalise a release fingerprint (see contract/deployment-fingerprint.md).
 *
 * @param mixed $raw Decoded forgedeck-release.json or similar.
 * @return array
 */
function forgedeck_normalize_release( $raw ) {
	$r   = is_array( $raw ) ? $raw : array();
	$sha = ( isset( $r['commit_sha'] ) && is_string( $r['commit_sha'] ) && 1 === preg_match( '/^[0-9a-fA-F]{7,40}$/D', $r['commit_sha'] ) ) ? strtolower( $r['commit_sha'] ) : null;
	$dep = isset( $r['deployed_at'] ) ? forgedeck_parse_time( $r['deployed_at'] ) : null;
	$blt = isset( $r['built_at'] ) ? forgedeck_parse_time( $r['built_at'] ) : null;
	$out = array(
		'commit_sha'  => $sha,
		'version'     => isset( $r['version'] ) ? forgedeck_short_string( $r['version'], 64 ) : null,
		'deployed_at' => null !== $dep ? forgedeck_iso( $dep ) : null,
	);
	$build_id = isset( $r['build_id'] ) ? forgedeck_short_string( $r['build_id'], 128 ) : null;
	if ( null !== $build_id ) {
		$out['build_id'] = $build_id;
	}
	if ( null !== $blt ) {
		$out['built_at'] = forgedeck_iso( $blt );
		if ( null === $out['deployed_at'] ) {
			$out['deployed_at'] = $out['built_at'];
		}
	}
	return $out;
}

/**
 * Normalise health checks: only id + state are exposed; overall state is the worst one.
 *
 * @param mixed $checks Raw list of array( 'id' => string, 'state' => string ).
 * @return array{state:string,checks:array}
 */
function forgedeck_normalize_health( $checks ) {
	$states = array( 'healthy', 'degraded', 'unhealthy' );
	$out    = array();
	$worst  = 0;
	foreach ( is_array( $checks ) ? array_slice( $checks, 0, 50 ) : array() as $check ) {
		if ( ! is_array( $check ) || ! isset( $check['id'] ) || ! is_string( $check['id'] ) || 1 !== preg_match( '/^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/D', $check['id'] ) ) {
			continue;
		}
		$state = ( isset( $check['state'] ) && in_array( $check['state'], $states, true ) ) ? $check['state'] : 'unhealthy';
		$out[] = array( 'id' => $check['id'], 'state' => $state );
		$worst = max( $worst, (int) array_search( $state, $states, true ) );
	}
	return array( 'state' => $states[ $worst ], 'checks' => $out );
}

/* ------------------------------------------------------------------ settings */

/**
 * Default settings: every capability OFF, nothing optional enabled.
 *
 * @return array
 */
function forgedeck_default_settings() {
	return array(
		'product_id'         => '',
		'environment'        => 'production',
		'component_id'       => 'wordpress',
		'capabilities'       => array(
			'status'  => false,
			'metrics' => false,
			'leads'   => false,
			'events'  => false,
		),
		'woocommerce_counts' => false,
		'trust_proxy'        => false,
		'pretty_path'        => false,
	);
}

/**
 * Sanitize raw settings (from the database or a form) into the canonical shape.
 * Unknown keys are dropped; anything not strictly enabled stays off.
 *
 * @param mixed $raw Raw settings.
 * @return array
 */
function forgedeck_normalize_settings( $raw ) {
	$out = forgedeck_default_settings();
	if ( ! is_array( $raw ) ) {
		return $out;
	}
	foreach ( array( 'product_id', 'component_id' ) as $key ) {
		if ( isset( $raw[ $key ] ) && is_string( $raw[ $key ] ) ) {
			$candidate = strtolower( trim( $raw[ $key ] ) );
			if ( 1 === preg_match( '/^[a-z0-9][a-z0-9._-]{0,62}$/D', $candidate ) ) {
				$out[ $key ] = $candidate;
			}
		}
	}
	if ( isset( $raw['environment'] ) && in_array( $raw['environment'], forgedeck_environments(), true ) ) {
		$out['environment'] = $raw['environment'];
	}
	$on = static function ( $v ) {
		return true === $v || 1 === $v || '1' === $v;
	};
	if ( isset( $raw['capabilities'] ) && is_array( $raw['capabilities'] ) ) {
		foreach ( forgedeck_capabilities() as $cap ) {
			$out['capabilities'][ $cap ] = isset( $raw['capabilities'][ $cap ] ) && $on( $raw['capabilities'][ $cap ] );
		}
	}
	foreach ( array( 'woocommerce_counts', 'trust_proxy', 'pretty_path' ) as $flag ) {
		$out[ $flag ] = isset( $raw[ $flag ] ) && $on( $raw[ $flag ] );
	}
	return $out;
}

/**
 * Names of the enabled capabilities, in canonical order.
 *
 * @param array $settings Normalised settings.
 * @return string[]
 */
function forgedeck_enabled_capabilities( array $settings ) {
	$enabled = array();
	foreach ( forgedeck_capabilities() as $cap ) {
		if ( isset( $settings['capabilities'][ $cap ] ) && true === $settings['capabilities'][ $cap ] ) {
			$enabled[] = $cap;
		}
	}
	return $enabled;
}

/**
 * Contract error body.
 *
 * @param string $code    Machine-readable code.
 * @param string $message Human-readable message.
 * @return array
 */
function forgedeck_error_body( $code, $message ) {
	return array(
		'schema_version' => FORGEDECK_SCHEMA_VERSION,
		'error'          => array(
			'code'    => $code,
			'message' => $message,
		),
	);
}
