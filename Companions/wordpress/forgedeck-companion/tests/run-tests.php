<?php
/**
 * Standalone tests for the pure functions. Runs without WordPress:
 *
 *     php tests/run-tests.php
 *
 * @package ForgeDeck_Companion
 */

if ( 'cli' !== PHP_SAPI ) {
	exit; // Tests never run over HTTP.
}

require __DIR__ . '/harness.php';
require dirname( __DIR__ ) . '/includes/functions.php';

$now = 1794758400; // 2026-11-15T16:00:00Z.

t( 'token hashing', static function () {
	same( 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', forgedeck_hash_token( 'abc' ) );
	$a = forgedeck_generate_token();
	$b = forgedeck_generate_token();
	ok( 1 === preg_match( '/^fdk_[A-Za-z0-9_-]{43}$/', $a ), 'token format' );
	ok( $a !== $b, 'tokens are random' );
} );

t( 'extract bearer', static function () {
	same( 'abc.DEF-123_x', forgedeck_extract_bearer( 'Bearer abc.DEF-123_x' ) );
	foreach ( array( 'bearer abc', 'Basic abc', 'Bearer ', 'Bearer a b', null, 'Bearer ' . str_repeat( 'a', 2000 ), "Bearer abc\n" . 'x' ) as $bad ) {
		same( null, forgedeck_extract_bearer( $bad ) );
	}
} );

t( 'token verification: ok, unknown, revoked, expired', static function () use ( $now ) {
	$records = array(
		array( 'id' => 'good', 'hash' => forgedeck_hash_token( 'good-token-0123456789' ), 'scopes' => array( 'status:read' ), 'revoked' => false, 'expires_at' => null ),
		array( 'id' => 'revoked', 'hash' => forgedeck_hash_token( 'revoked-token-0123456789' ), 'scopes' => array( 'status:read' ), 'revoked' => true, 'expires_at' => null ),
		array( 'id' => 'expired', 'hash' => forgedeck_hash_token( 'expired-token-0123456789' ), 'scopes' => array( 'status:read' ), 'revoked' => false, 'expires_at' => $now - 1 ),
		array( 'id' => 'future', 'hash' => forgedeck_hash_token( 'future-token-0123456789' ), 'scopes' => array( 'status:read' ), 'revoked' => false, 'expires_at' => $now + 86400 ),
		array( 'id' => 'corrupt', 'hash' => 'not-a-hash' ),
		'garbage',
	);
	$good = forgedeck_verify_token( 'good-token-0123456789', $records, $now );
	same( true, $good['ok'] );
	same( 'good', $good['record']['id'] );
	same( true, forgedeck_verify_token( 'future-token-0123456789', $records, $now )['ok'] );
	same( 'unknown', forgedeck_verify_token( 'nope-token-0123456789', $records, $now )['reason'] );
	same( 'revoked', forgedeck_verify_token( 'revoked-token-0123456789', $records, $now )['reason'] );
	same( 'expired', forgedeck_verify_token( 'expired-token-0123456789', $records, $now )['reason'] );
	same( 'missing', forgedeck_verify_token( null, $records, $now )['reason'] );
	same( 'missing', forgedeck_verify_token( '', $records, $now )['reason'] );
	same( false, forgedeck_verify_token( $records[0]['hash'], $records, $now )['ok'], 'the stored hash is not a credential' );
	same( false, forgedeck_verify_token( 'not-a-hash', $records, $now )['ok'] );
	same( 'unknown', forgedeck_verify_token( 'good-token-0123456789', array(), $now )['reason'], 'no records => deny' );
} );

t( 'scope check', static function () {
	$record = array( 'scopes' => array( 'status:read', 'admin:write' ) );
	same( true, forgedeck_has_scope( $record, 'status:read' ) );
	same( false, forgedeck_has_scope( $record, 'leads:read' ) );
	same( false, forgedeck_has_scope( $record, 'admin:write' ), 'unknown scopes never grant anything' );
	same( false, forgedeck_has_scope( null, 'status:read' ) );
	same( false, forgedeck_has_scope( array(), 'status:read' ) );
	same( array( 'status:read', 'leads:read' ), forgedeck_sanitize_scopes( array( 'leads:read', 'evil', 'status:read' ) ) );
	same( array(), forgedeck_sanitize_scopes( 'status:read' ) );
} );

t( 'window validation', static function () {
	same( 86400, forgedeck_validate_window( '24h' ) );
	same( 604800, forgedeck_validate_window( '7d' ) );
	same( 2592000, forgedeck_validate_window( '30d' ) );
	same( 7776000, forgedeck_validate_window( '90d' ) );
	foreach ( array( '1h', '365d', '91d', '', '24H', '24h ', 'all', null, 24, array( '24h' ), '7d,30d' ) as $bad ) {
		same( null, forgedeck_validate_window( $bad ) );
	}
} );

t( 'limit and time parsing', static function () use ( $now ) {
	same( 1, forgedeck_parse_limit( '1' ) );
	same( 100, forgedeck_parse_limit( '100' ) );
	foreach ( array( '0', '101', '1000', '-1', 'abc', '1.5', '', '1e2', null, 5 ) as $bad ) {
		same( null, forgedeck_parse_limit( $bad ) );
	}
	same( $now, forgedeck_parse_time( '2026-11-15T16:00:00Z' ) );
	same( $now, forgedeck_parse_time( '2026-11-15T17:00:00+01:00' ) );
	same( $now, forgedeck_parse_time( '2026-11-15T16:00:00.123Z' ) );
	foreach ( array( 'yesterday', '2026-11-15', '2026-11-15 16:00:00', '2026-13-45T99:00:00Z', '', null ) as $bad ) {
		same( null, forgedeck_parse_time( $bad ) );
	}
	same( '2026-11-15T16:00:00Z', forgedeck_iso( $now ) );
} );

t( 'range resolution is bounded to 90 days', static function () use ( $now ) {
	$default = forgedeck_resolve_range( null, null, $now );
	same( true, $default['ok'] );
	same( $now - 7776000, $default['since'] );
	same( true, forgedeck_resolve_range( '2026-08-17T16:00:00Z', '2026-11-15T16:00:00Z', $now )['ok'] );
	same( 'invalid_range', forgedeck_resolve_range( '2026-08-17T15:59:59Z', '2026-11-15T16:00:00Z', $now )['code'] );
	same( 'invalid_range', forgedeck_resolve_range( '2026-11-15T16:00:00Z', '2026-11-14T16:00:00Z', $now )['code'] );
	same( 'invalid_time', forgedeck_resolve_range( 'yesterday', null, $now )['code'] );
	same( 'invalid_time', forgedeck_resolve_range( null, 'tomorrow', $now )['code'] );
} );

t( 'signature check', static function () use ( $now ) {
	$secret = 'signing-secret-0123456789';
	$path   = '/_forgedeck/v1/metrics?window=24h';
	same( "1794758400\nGET\n/_forgedeck/v1/metrics?window=24h", forgedeck_canonical_string( '1794758400', 'get', $path ) );
	$sig = forgedeck_sign_request( $secret, (string) $now, 'GET', $path );
	// Same vector as contract/README.md and the Node/Python test suites.
	same( '8e06b08e0d1b608b4be2b998316ad034375c056a8b375707af02dfe86f31a01b', $sig );
	same( true, forgedeck_verify_signature( $secret, (string) $now, $sig, 'GET', $path, $now )['ok'] );
	same( true, forgedeck_verify_signature( $secret, (string) $now, strtoupper( $sig ), 'GET', $path, $now )['ok'] );
	same( true, forgedeck_verify_signature( $secret, (string) $now, $sig, 'GET', $path, $now + 300 )['ok'] );
	same( 'stale_timestamp', forgedeck_verify_signature( $secret, (string) $now, $sig, 'GET', $path, $now + 301 )['reason'] );
	same( 'stale_timestamp', forgedeck_verify_signature( $secret, (string) $now, $sig, 'GET', $path, $now - 301 )['reason'] );
	same( 'bad_signature', forgedeck_verify_signature( $secret, (string) $now, $sig, 'GET', '/_forgedeck/v1/metrics?window=7d', $now )['reason'] );
	same( 'bad_signature', forgedeck_verify_signature( $secret, (string) $now, $sig, 'POST', $path, $now )['reason'] );
	same( 'bad_signature', forgedeck_verify_signature( 'another-secret-0123456789', (string) $now, $sig, 'GET', $path, $now )['reason'] );
	same( 'bad_signature', forgedeck_verify_signature( $secret, (string) $now, 'zz', 'GET', $path, $now )['reason'] );
	same( 'bad_signature', forgedeck_verify_signature( $secret, (string) $now, null, 'GET', $path, $now )['reason'] );
	same( 'bad_timestamp', forgedeck_verify_signature( $secret, 'abc', $sig, 'GET', $path, $now )['reason'] );
	same( 'bad_timestamp', forgedeck_verify_signature( $secret, null, $sig, 'GET', $path, $now )['reason'] );
	same( 'bad_timestamp', forgedeck_verify_signature( $secret, $now, $sig, 'GET', $path, $now )['reason'], 'timestamp must be the header string' );
	ok( forgedeck_nonce_key( '1', 'AB' ) === forgedeck_nonce_key( '1', 'ab' ), 'nonce key is case-insensitive on the signature' );
	ok( forgedeck_nonce_key( '1', 'ab' ) !== forgedeck_nonce_key( '2', 'ab' ), 'nonce key depends on the timestamp' );
	ok( strlen( forgedeck_nonce_key( '1', 'ab' ) ) <= 64, 'nonce key fits in a transient name' );
} );

t( 'rate limit step', static function () {
	$t0     = 1000000;
	$bucket = null;
	for ( $i = 0; $i < 3; $i++ ) {
		$step   = forgedeck_rate_limit_step( $bucket, $t0 + $i, 3, 60 );
		$bucket = $step['bucket'];
		same( true, $step['allowed'] );
	}
	$blocked = forgedeck_rate_limit_step( $bucket, $t0 + 20, 3, 60 );
	same( false, $blocked['allowed'] );
	same( 40, $blocked['retry_after'] );
	same( true, forgedeck_rate_limit_step( $blocked['bucket'], $t0 + 60, 3, 60 )['allowed'], 'new window' );
	same( true, forgedeck_rate_limit_step( 'corrupt', $t0, 3, 60 )['allowed'] );
	same( true, forgedeck_rate_limit_step( false, $t0, 3, 60 )['allowed'], 'missing transient' );
} );

t( 'transport check', static function () {
	foreach ( array( '127.0.0.1', '127.1.2.3', '::1', '::ffff:127.0.0.1' ) as $a ) {
		same( true, forgedeck_is_loopback( $a ) );
	}
	foreach ( array( '10.0.0.1', '203.0.113.5', '1127.0.0.1', '', null ) as $a ) {
		same( false, forgedeck_is_loopback( $a ) );
	}
	same( true, forgedeck_is_secure_request( true, '203.0.113.5', false, null ) );
	same( false, forgedeck_is_secure_request( false, '203.0.113.5', false, null ) );
	same( true, forgedeck_is_secure_request( false, '127.0.0.1', false, null ) );
	same( false, forgedeck_is_secure_request( false, '203.0.113.5', false, 'https' ), 'header ignored without opt-in' );
	same( true, forgedeck_is_secure_request( false, '10.0.0.2', true, 'https' ) );
	same( true, forgedeck_is_secure_request( false, '10.0.0.2', true, 'https, http' ) );
	same( false, forgedeck_is_secure_request( false, '127.0.0.1', true, 'http' ), 'plain HTTP relayed by a local proxy' );
} );

t( 'cursor', static function () use ( $now ) {
	$c = forgedeck_encode_cursor( '2026-11-15T15:00:00Z', 'evt_lead_001' );
	// Byte-identical to the Node and Python encodings.
	same( 'eyJ2IjoxLCJ0IjoiMjAyNi0xMS0xNVQxNTowMDowMFoiLCJpZCI6ImV2dF9sZWFkXzAwMSJ9', $c );
	same( array( 't' => $now - 3600, 'id' => 'evt_lead_001' ), forgedeck_decode_cursor( $c ) );
	$b64 = static function ( $s ) {
		return rtrim( strtr( base64_encode( $s ), '+/', '-_' ), '=' );
	};
	foreach ( array( '', 'not base64!!', 'e30', $b64( '{"v":1,"t":"nope","id":"x"}' ), $b64( '{"v":2,"t":"2026-11-15T15:00:00Z","id":"x"}' ), str_repeat( 'a', 600 ), null, 42 ) as $bad ) {
		same( null, forgedeck_decode_cursor( $bad ) );
	}
} );

t( 'email masking', static function () {
	same( 'j***@e***.com', forgedeck_mask_email( 'john@example.com' ) );
	same( 'a***@m***.uk', forgedeck_mask_email( 'Ann.Smith@Mail.Example.co.uk' ) );
	foreach ( array( 'not-an-email', 'a@b', null, 5 ) as $bad ) {
		same( null, forgedeck_mask_email( $bad ) );
	}
} );

t( 'metrics whitelist', static function () {
	$raw = array( 'signups' => 9, 'leads' => 12, 'orders' => '5', 'paid_orders' => -1, 'customer_emails' => array( 'a@b.com' ), 'revenue' => 100 );
	same( array( 'leads' => 12, 'signups' => 9 ), forgedeck_sanitize_metrics( $raw, forgedeck_allowed_metrics() ) );
	same( array(), forgedeck_sanitize_metrics( 'nope', forgedeck_allowed_metrics() ) );
} );

t( 'item sanitising and pagination', static function () use ( $now ) {
	$raw = array( 'id' => 'evt_1', 'kind' => 'lead', 'occurred_at' => '2026-11-15T12:00:00Z', 'source' => 'contact_form', 'email' => 'john@example.com', 'name' => 'John', 'phone' => '555' );
	$s   = forgedeck_sanitize_item( $raw, forgedeck_lead_kinds() );
	same( array( 'id' => 'evt_1', 'kind' => 'lead', 'occurred_at' => '2026-11-15T12:00:00Z', 'source' => 'contact_form', 'title' => 'New lead', 'value_cents' => null ), $s['item'] );
	same( 'j***@e***.com', forgedeck_sanitize_item( $raw, forgedeck_lead_kinds(), true )['item']['label'] );
	same( null, forgedeck_sanitize_item( array_merge( $raw, array( 'kind' => 'deploy' ) ), forgedeck_lead_kinds() ) );
	same( null, forgedeck_sanitize_item( array_merge( $raw, array( 'id' => 'has space' ) ), forgedeck_lead_kinds() ) );
	same( null, forgedeck_sanitize_item( array_merge( $raw, array( 'occurred_at' => 'nope' ) ), forgedeck_lead_kinds() ) );
	same( null, forgedeck_sanitize_item( 'x', forgedeck_lead_kinds() ) );

	$items = array();
	for ( $i = 1; $i <= 7; $i++ ) {
		$items[] = array( 'id' => 'evt_' . $i, 'kind' => 'lead', 'occurred_at' => $now - $i * 3600, 'email' => 'p' . $i . '@example.com' );
	}
	$items[] = array( 'id' => 'evt_old', 'kind' => 'lead', 'occurred_at' => $now - 100 * 86400 );
	$seen    = array();
	$after   = null;
	$pages   = 0;
	do {
		$page = forgedeck_paginate( $items, forgedeck_lead_kinds(), $now - 7776000, $now, $after, 3 );
		foreach ( $page['items'] as $item ) {
			$seen[] = $item['id'];
		}
		$after = null === $page['next_cursor'] ? null : forgedeck_decode_cursor( $page['next_cursor'] );
		++$pages;
	} while ( null !== $after && $pages < 10 );
	same( 3, $pages );
	same( array( 'evt_7', 'evt_6', 'evt_5', 'evt_4', 'evt_3', 'evt_2', 'evt_1' ), $seen );
	ok( false === strpos( json_encode( forgedeck_paginate( $items, forgedeck_lead_kinds(), $now - 7776000, $now, null, 100 ) ), '@' ), 'no contact data' );
} );

t( 'release and health normalisation', static function () {
	same( array( 'commit_sha' => null, 'version' => null, 'deployed_at' => null ), forgedeck_normalize_release( null ) );
	same(
		array( 'commit_sha' => 'abcdef1', 'version' => '1.2.3', 'deployed_at' => '2026-11-14T12:00:00Z', 'build_id' => '42', 'built_at' => '2026-11-14T12:00:00Z' ),
		forgedeck_normalize_release( array( 'commit_sha' => 'ABCDEF1', 'version' => '1.2.3', 'built_at' => '2026-11-14T12:00:00Z', 'build_id' => '42', 'extra' => 'x' ) )
	);
	same( array( 'state' => 'healthy', 'checks' => array() ), forgedeck_normalize_health( null ) );
	same(
		array( 'state' => 'unhealthy', 'checks' => array( array( 'id' => 'database', 'state' => 'healthy' ), array( 'id' => 'queue', 'state' => 'degraded' ), array( 'id' => 'x', 'state' => 'unhealthy' ) ) ),
		forgedeck_normalize_health( array( array( 'id' => 'database', 'state' => 'healthy', 'error' => 'dsn' ), array( 'id' => 'queue', 'state' => 'degraded' ), array( 'id' => 'x', 'state' => '??' ), 'junk' ) )
	);
} );

t( 'settings: everything off by default, strict normalisation', static function () {
	$d = forgedeck_default_settings();
	same( array(), forgedeck_enabled_capabilities( $d ) );
	same( false, $d['woocommerce_counts'] );
	same( false, $d['trust_proxy'] );
	same( false, $d['pretty_path'] );
	same( $d, forgedeck_normalize_settings( null ) );
	same( $d, forgedeck_normalize_settings( array() ) );
	$s = forgedeck_normalize_settings(
		array(
			'product_id'   => ' Example-Product ',
			'environment'  => 'staging',
			'capabilities' => array( 'status' => '1', 'metrics' => 'yes', 'leads' => 0, 'admin' => '1' ),
			'trust_proxy'  => 'true',
			'evil'         => 'x',
		)
	);
	same( 'example-product', $s['product_id'] );
	same( 'staging', $s['environment'] );
	same( array( 'status' ), forgedeck_enabled_capabilities( $s ) );
	same( false, $s['trust_proxy'] );
	ok( ! isset( $s['evil'] ) && ! isset( $s['capabilities']['admin'] ), 'unknown keys dropped' );
	same( '', forgedeck_normalize_settings( array( 'product_id' => 'Bad Product!' ) )['product_id'] );
	same( 'production', forgedeck_normalize_settings( array( 'environment' => 'prod' ) )['environment'] );
} );

finish();
