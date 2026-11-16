<?php
/**
 * Tests for the REST gate and handlers against minimal in-memory WordPress stubs.
 * Runs without WordPress and touches no site:
 *
 *     php tests/run-rest-tests.php
 *
 * These stubs imitate only the handful of WordPress functions the plugin calls; they are a
 * safety net, not a substitute for trying the plugin on a disposable WordPress install.
 *
 * @package ForgeDeck_Companion
 */

if ( 'cli' !== PHP_SAPI ) {
	exit; // Tests never run over HTTP.
}

require __DIR__ . '/harness.php';

// ---------------------------------------------------------------- WordPress stubs
define( 'ABSPATH', __DIR__ . '/' );
define( 'WP_CONTENT_DIR', sys_get_temp_dir() . '/forgedeck-companion-test-' . getmypid() );

$GLOBALS['stub'] = array( 'options' => array(), 'transients' => array(), 'filters' => array(), 'routes' => array(), 'ssl' => false, 'db_ok' => true, 'woo_queries' => array() );

function get_option( $name, $default = false ) {
	return array_key_exists( $name, $GLOBALS['stub']['options'] ) ? $GLOBALS['stub']['options'][ $name ] : $default;
}
function update_option( $name, $value ) {
	$GLOBALS['stub']['options'][ $name ] = $value;
	return true;
}
function delete_option( $name ) {
	unset( $GLOBALS['stub']['options'][ $name ] );
	return true;
}
function get_transient( $name ) {
	return array_key_exists( $name, $GLOBALS['stub']['transients'] ) ? $GLOBALS['stub']['transients'][ $name ] : false;
}
function set_transient( $name, $value ) {
	$GLOBALS['stub']['transients'][ $name ] = $value;
	return true;
}
function add_action() {}
function add_filter( $name, $fn ) {
	$GLOBALS['stub']['filters'][ $name ][] = $fn;
}
function apply_filters( $name, $value, ...$args ) {
	foreach ( isset( $GLOBALS['stub']['filters'][ $name ] ) ? $GLOBALS['stub']['filters'][ $name ] : array() as $fn ) {
		$value = $fn( $value, ...$args );
	}
	return $value;
}
function is_ssl() {
	return $GLOBALS['stub']['ssl'];
}
function wp_unslash( $v ) {
	return $v;
}
function register_rest_route( $ns, $route, $args ) {
	$GLOBALS['stub']['routes'][ '/' . $ns . $route ] = $args;
}

class WP_Error {
	public $code;
	public $message;
	public $data;
	public function __construct( $code, $message, $data ) {
		$this->code    = $code;
		$this->message = $message;
		$this->data    = $data;
	}
}

class WP_REST_Response {
	private $data;
	private $status;
	public $headers = array();
	public function __construct( $data = null, $status = 200 ) {
		$this->data   = $data;
		$this->status = $status;
	}
	public function get_data() {
		return $this->data;
	}
	public function set_data( $d ) {
		$this->data = $d;
	}
	public function get_status() {
		return $this->status;
	}
	public function header( $k, $v ) {
		$this->headers[ $k ] = $v;
	}
}

class WP_REST_Request {
	private $method;
	private $route;
	private $params;
	private $headers = array();
	public function __construct( $method, $route, array $params = array(), array $headers = array() ) {
		$this->method = $method;
		$this->route  = $route;
		$this->params = $params;
		foreach ( $headers as $k => $v ) {
			$this->headers[ strtolower( str_replace( '-', '_', $k ) ) ] = $v;
		}
	}
	public function get_header( $k ) {
		$k = strtolower( str_replace( '-', '_', $k ) );
		return isset( $this->headers[ $k ] ) ? $this->headers[ $k ] : null;
	}
	public function get_param( $k ) {
		return isset( $this->params[ $k ] ) ? $this->params[ $k ] : null;
	}
	public function get_route() {
		return $this->route;
	}
	public function get_method() {
		return $this->method;
	}
}

class Stub_WPDB {
	public $users = 'wp_users';
	public function prepare( $sql, ...$args ) {
		return vsprintf( str_replace( '%s', "'%s'", $sql ), $args );
	}
	public function get_var( $sql ) {
		if ( ! $GLOBALS['stub']['db_ok'] ) {
			return null;
		}
		return 'SELECT 1' === $sql ? '1' : '9';
	}
}
$GLOBALS['wpdb'] = new Stub_WPDB();

require dirname( __DIR__ ) . '/includes/functions.php';
require dirname( __DIR__ ) . '/includes/class-forgedeck-companion-rest.php';

// ---------------------------------------------------------------- helpers
const TOKEN  = 'fdk_test_token_0123456789abcdefghij';
const NOW    = 1794758400; // 2026-11-15T16:00:00Z.
const SECRET = 'signing-secret-0123456789';

ForgeDeck_Companion_REST::$clock = static function () {
	return $GLOBALS['stub']['now'];
};
ForgeDeck_Companion_REST::register_routes();

function fresh( array $settings = array(), $scopes = null, array $token_overrides = array() ) {
	$GLOBALS['stub']['options']    = array();
	$GLOBALS['stub']['transients'] = array();
	$GLOBALS['stub']['filters']    = array();
	$GLOBALS['stub']['ssl']        = false;
	$GLOBALS['stub']['db_ok']      = true;
	$GLOBALS['stub']['now']        = NOW;
	$_SERVER['REMOTE_ADDR']        = '127.0.0.1';
	update_option(
		'forgedeck_companion_settings',
		array_merge(
			array(
				'product_id'   => 'example-product',
				'environment'  => 'production',
				'capabilities' => array( 'status' => true, 'metrics' => true, 'leads' => true, 'events' => true ),
			),
			$settings
		)
	);
	if ( false !== $scopes ) {
		update_option(
			'forgedeck_companion_token',
			array_merge(
				array( 'id' => 'wp-test', 'hash' => forgedeck_hash_token( TOKEN ), 'scopes' => null === $scopes ? forgedeck_scopes() : $scopes, 'revoked' => false ),
				$token_overrides
			)
		);
	}
}

/** Dispatch like WP_REST_Server would: permission_callback, callback, rest_post_dispatch. */
function call( $route, array $params = array(), array $headers = array(), $token = TOKEN, $method = 'GET' ) {
	ForgeDeck_Companion_REST::reset();
	$path  = '/forgedeck/v1/' . $route;
	$query = $params ? '?' . http_build_query( $params ) : '';
	if ( ! isset( $headers['__uri'] ) ) {
		$_SERVER['REQUEST_URI'] = '/wp-json' . $path . $query;
	} else {
		$_SERVER['REQUEST_URI'] = $headers['__uri'];
		unset( $headers['__uri'] );
	}
	if ( null !== $token ) {
		$headers['Authorization'] = 'Bearer ' . $token;
	}
	$request = new WP_REST_Request( $method, $path, $params, $headers );
	if ( ! isset( $GLOBALS['stub']['routes'][ $path ] ) || $GLOBALS['stub']['routes'][ $path ]['methods'] !== $method ) {
		$response = new WP_REST_Response( array( 'code' => 'rest_no_route', 'message' => 'No route was found matching the URL and request method.', 'data' => array( 'status' => 404 ) ), 404 );
	} else {
		$args    = $GLOBALS['stub']['routes'][ $path ];
		$allowed = call_user_func( $args['permission_callback'], $request );
		// WordPress may consult the callback again; the decision must be stable and counted once.
		same( $allowed, call_user_func( $args['permission_callback'], $request ) );
		if ( true === $allowed ) {
			$response = call_user_func( $args['callback'], $request );
		} else {
			$response = new WP_REST_Response( array( 'code' => $allowed->code, 'message' => $allowed->message, 'data' => $allowed->data ), $allowed->data['status'] );
		}
	}
	$response = ForgeDeck_Companion_REST::shape_response( $response, null, $request );
	return array(
		'status'  => $response->get_status(),
		'body'    => json_decode( json_encode( $response->get_data() ), true ),
		'raw'     => json_encode( $response->get_data() ),
		'headers' => $response->headers,
	);
}

function signed( $uri, $now = NOW, $secret = SECRET, $method = 'GET' ) {
	return array(
		'X-ForgeDeck-Timestamp' => (string) $now,
		'X-ForgeDeck-Signature' => forgedeck_sign_request( $secret, (string) $now, $method, $uri ),
		'__uri'                 => $uri,
	);
}

// ---------------------------------------------------------------- tests
t( 'routes: exactly five, all GET-only, hidden from the index', static function () {
	same( array( '/forgedeck/v1/manifest', '/forgedeck/v1/status', '/forgedeck/v1/metrics', '/forgedeck/v1/leads', '/forgedeck/v1/events' ), array_keys( $GLOBALS['stub']['routes'] ) );
	foreach ( $GLOBALS['stub']['routes'] as $args ) {
		same( 'GET', $args['methods'] );
		same( false, $args['show_in_index'] );
		ok( is_callable( $args['permission_callback'] ) && is_callable( $args['callback'] ) );
	}
} );

t( 'default deny: fresh install serves nothing', static function () {
	fresh();
	$GLOBALS['stub']['options'] = array(); // Exactly what a new site has: no options at all.
	foreach ( array( 'manifest', 'status', 'metrics', 'leads', 'events' ) as $route ) {
		$r = call( $route );
		same( 503, $r['status'], $route );
		same( 'not_configured', $r['body']['error']['code'] );
	}
} );

t( 'default deny: no token, or no product id => 503', static function () {
	fresh( array(), false );
	same( 503, call( 'status' )['status'] );
	fresh( array( 'product_id' => '' ) );
	same( 503, call( 'status' )['status'] );
} );

t( 'default deny: capabilities off => 404, manifest shows none', static function () {
	fresh( array( 'capabilities' => array() ) );
	foreach ( array( 'status', 'metrics', 'leads', 'events' ) as $route ) {
		same( 404, call( $route )['status'], $route );
	}
	$m = call( 'manifest' );
	same( 200, $m['status'] );
	same( array(), $m['body']['capabilities'] );
} );

t( 'non-GET methods and unknown routes are 404 in the contract error shape', static function () {
	fresh();
	foreach ( array( 'POST', 'PUT', 'DELETE', 'PATCH' ) as $method ) {
		$r = call( 'status', array(), array(), TOKEN, $method );
		same( 404, $r['status'] );
		same( array( 'schema_version' => '1.0', 'error' => array( 'code' => 'not_found', 'message' => 'Not found' ) ), $r['body'] );
	}
	same( 404, call( 'admin' )['status'] );
	same( 404, call( 'tokens' )['status'] );
} );

t( '401: missing, wrong, revoked, expired tokens', static function () {
	fresh();
	foreach ( array( null, 'wrong-token-000000000000', forgedeck_hash_token( TOKEN ) ) as $tok ) {
		$r = call( 'status', array(), array(), $tok );
		same( 401, $r['status'] );
		same( 'unauthorized', $r['body']['error']['code'] );
		same( 'Bearer', $r['headers']['WWW-Authenticate'] );
		ok( ! isset( $r['body']['release'] ) );
	}
	same( 401, call( 'status', array( 'token' => TOKEN ), array(), null )['status'], 'token in query string is not accepted' );
	fresh( array(), null, array( 'revoked' => true ) );
	same( 401, call( 'status' )['status'] );
	fresh( array(), null, array( 'expires_at' => NOW + 1 ) );
	same( 200, call( 'status' )['status'] );
	$GLOBALS['stub']['now'] = NOW + 1;
	same( 401, call( 'status' )['status'] );
} );

t( '403: scope checks per route', static function () {
	$want = array( 'manifest' => 'status:read', 'status' => 'status:read', 'metrics' => 'metrics:read', 'leads' => 'leads:read', 'events' => 'events:read' );
	foreach ( forgedeck_scopes() as $scope ) {
		foreach ( $want as $route => $needed ) {
			fresh( array(), array( $scope ) );
			$r = call( $route );
			same( $needed === $scope ? 200 : 403, $r['status'], "$scope -> $route" );
			if ( 403 === $r['status'] ) {
				same( 'insufficient_scope', $r['body']['error']['code'] );
			}
		}
	}
	fresh( array(), array( 'admin:write', 'bogus' ) );
	same( 403, call( 'status' )['status'], 'unknown stored scopes grant nothing' );
} );

t( 'status: canonical shape, config-sourced identity', static function () {
	fresh();
	$r = call( 'status', array( 'product_id' => 'evil', 'environment' => 'staging' ), array( 'X-Product-Id' => 'evil' ) );
	same( 200, $r['status'] );
	same(
		array(
			'schema_version' => '1.0',
			'product_id'     => 'example-product',
			'component_id'   => 'wordpress',
			'environment'    => 'production',
			'observed_at'    => '2026-11-15T16:00:00Z',
			'release'        => array( 'commit_sha' => null, 'version' => null, 'deployed_at' => null ),
			'health'         => array( 'state' => 'healthy', 'checks' => array( array( 'id' => 'database', 'state' => 'healthy' ) ) ),
			'metrics'        => array( 'signups_24h' => 9 ),
			'capabilities'   => array( 'status', 'metrics', 'leads', 'events' ),
		),
		$r['body']
	);
	ok( false === strpos( $r['raw'], 'evil' ) );
	same( 'no-store', $r['headers']['Cache-Control'] );
} );

t( 'status: empty metrics is a JSON object; release file is read; db failure => unhealthy', static function () {
	fresh( array(), array( 'status:read' ) );
	$r = call( 'status' );
	ok( false !== strpos( $r['raw'], '"metrics":{}' ), 'metrics must encode as {} not []' );

	@mkdir( WP_CONTENT_DIR );
	file_put_contents( WP_CONTENT_DIR . '/forgedeck-release.json', '{"commit_sha":"0123456789abcdef0123456789abcdef01234567","version":"1.8.2","build_id":"77","built_at":"2026-11-14T12:30:00Z","secret":"x"}' );
	$r = call( 'status' );
	same( array( 'commit_sha' => '0123456789abcdef0123456789abcdef01234567', 'version' => '1.8.2', 'deployed_at' => '2026-11-14T12:30:00Z', 'build_id' => '77', 'built_at' => '2026-11-14T12:30:00Z' ), $r['body']['release'] );
	unlink( WP_CONTENT_DIR . '/forgedeck-release.json' );
	rmdir( WP_CONTENT_DIR );

	$GLOBALS['stub']['db_ok'] = false;
	$r                        = call( 'status' );
	same( 200, $r['status'] );
	same( 'unhealthy', $r['body']['health']['state'] );
} );

t( 'metrics: windows validated, counters whitelisted, WooCommerce absent => no order counts', static function () {
	fresh( array( 'woocommerce_counts' => true ) );
	add_filter( 'forgedeck_companion_metrics', static function ( $m ) {
		return array_merge( $m, array( 'leads' => 12, 'customer_emails' => array( 'a@b.com' ), 'revenue' => 5 ) );
	} );
	foreach ( array( '24h', '7d', '30d', '90d' ) as $w ) {
		$r = call( 'metrics', array( 'window' => $w ) );
		same( 200, $r['status'] );
		same( array( 'schema_version' => '1.0', 'product_id' => 'example-product', 'environment' => 'production', 'observed_at' => '2026-11-15T16:00:00Z', 'window' => $w, 'source' => 'wordpress', 'metrics' => array( 'leads' => 12, 'signups' => 9 ) ), $r['body'] );
	}
	same( '24h', call( 'metrics' )['body']['window'] );
	foreach ( array( '1h', '365d', '', '24H', 'all' ) as $w ) {
		$r = call( 'metrics', array( 'window' => $w ) );
		same( 400, $r['status'], "window=$w" );
		same( 'invalid_window', $r['body']['error']['code'] );
	}
} );

t( 'leads/events: empty by default; site-supplied items are redacted, bounded and paged', static function () {
	fresh();
	$r = call( 'leads' );
	same( 200, $r['status'] );
	same( array(), $r['body']['items'] );
	same( null, $r['body']['next_cursor'] );

	add_filter( 'forgedeck_companion_leads', static function () {
		$items = array();
		for ( $i = 1; $i <= 7; $i++ ) {
			$items[] = array( 'id' => 'evt_' . $i, 'kind' => 'lead', 'occurred_at' => NOW - $i * 3600, 'source' => 'contact_form', 'email' => "p$i@example.com", 'name' => 'Jane Private' );
		}
		return $items;
	} );
	$seen   = array();
	$cursor = null;
	for ( $page = 0; $page < 10; $page++ ) {
		$r = call( 'leads', array_filter( array( 'limit' => '3', 'cursor' => $cursor ) ) );
		same( 200, $r['status'] );
		foreach ( $r['body']['items'] as $item ) {
			same( array( 'id', 'kind', 'occurred_at', 'source', 'title', 'value_cents' ), array_keys( $item ) );
			$seen[] = $item['id'];
		}
		ok( false === strpos( $r['raw'], '@' ) && false === strpos( $r['raw'], 'Jane' ), 'no contact data' );
		$cursor = $r['body']['next_cursor'];
		if ( null === $cursor ) {
			break;
		}
	}
	same( array( 'evt_7', 'evt_6', 'evt_5', 'evt_4', 'evt_3', 'evt_2', 'evt_1' ), $seen );

	same( 'invalid_limit', call( 'leads', array( 'limit' => '101' ) )['body']['error']['code'] );
	same( 'invalid_limit', call( 'leads', array( 'limit' => '0' ) )['body']['error']['code'] );
	same( 'invalid_cursor', call( 'leads', array( 'cursor' => 'garbage' ) )['body']['error']['code'] );
	same( 'invalid_range', call( 'leads', array( 'since' => '2026-01-01T00:00:00Z' ) )['body']['error']['code'] );
	same( 'invalid_time', call( 'events', array( 'since' => 'yesterday' ) )['body']['error']['code'] );
	same( array(), call( 'events' )['body']['items'] );
} );

t( 'HTTPS required off loopback; X-Forwarded-Proto only with opt-in', static function () {
	fresh();
	$_SERVER['REMOTE_ADDR'] = '203.0.113.7';
	$r                      = call( 'status' );
	same( 403, $r['status'] );
	same( 'https_required', $r['body']['error']['code'] );
	same( 403, call( 'status', array(), array( 'X-Forwarded-Proto' => 'https' ) )['status'], 'spoofed header ignored' );
	$GLOBALS['stub']['ssl'] = true;
	same( 200, call( 'status' )['status'] );

	fresh( array( 'trust_proxy' => true ) );
	$_SERVER['REMOTE_ADDR'] = '10.0.0.2';
	same( 200, call( 'status', array(), array( 'X-Forwarded-Proto' => 'https' ) )['status'] );
	same( 403, call( 'status', array(), array( 'X-Forwarded-Proto' => 'http' ) )['status'] );
} );

t( 'rate limit: 60/min per token => 429 + Retry-After; failed auth limited per address', static function () {
	fresh();
	for ( $i = 0; $i < 60; $i++ ) {
		same( 200, call( 'manifest' )['status'] );
	}
	$GLOBALS['stub']['now'] = NOW + 15;
	$r                      = call( 'manifest' );
	same( 429, $r['status'] );
	same( 'rate_limited', $r['body']['error']['code'] );
	same( '45', $r['headers']['Retry-After'] );
	$GLOBALS['stub']['now'] = NOW + 60;
	same( 200, call( 'manifest' )['status'] );

	fresh();
	for ( $i = 0; $i < 60; $i++ ) {
		same( 401, call( 'status', array(), array(), 'guess-0000000000000000' )['status'] );
	}
	same( 429, call( 'status', array(), array(), 'guess-0000000000000000' )['status'] );
	same( 200, call( 'status' )['status'], 'a valid token is not locked out by guesses' );
} );

t( 'signing: required when a secret is set; replay, stale and tampered requests rejected', static function () {
	fresh();
	update_option( 'forgedeck_companion_signing_secret', SECRET );
	$uri = '/wp-json/forgedeck/v1/metrics?window=7d';
	$r   = call( 'metrics', array( 'window' => '7d' ) );
	same( 401, $r['status'] );
	same( 'invalid_signature', $r['body']['error']['code'] );

	$headers = signed( $uri );
	same( 200, call( 'metrics', array( 'window' => '7d' ), $headers )['status'] );
	$replay = call( 'metrics', array( 'window' => '7d' ), $headers );
	same( 401, $replay['status'] );
	same( 'replayed_request', $replay['body']['error']['code'] );

	same( 401, call( 'metrics', array( 'window' => '7d' ), signed( $uri, NOW - 301 ) )['status'] );
	same( 401, call( 'metrics', array( 'window' => '7d' ), signed( $uri, NOW + 301 ) )['status'] );
	same( 401, call( 'metrics', array( 'window' => '7d' ), signed( $uri, NOW, 'wrong-secret-0123456789abc' ) )['status'] );
	$other          = signed( '/wp-json/forgedeck/v1/metrics?window=90d' );
	$other['__uri'] = $uri;
	same( 401, call( 'metrics', array( 'window' => '7d' ), $other )['status'], 'signature for a different query' );
	same( 401, call( 'metrics', array( 'window' => '7d' ), signed( $uri, NOW - 10 ), null )['status'], 'signature does not replace the token' );

	// The optional pretty path signs the path the client actually requested.
	$pretty = '/_forgedeck/v1/status';
	same( 200, call( 'status', array(), signed( $pretty, NOW - 5 ) )['status'] );
	ok( true === call( 'manifest', array(), signed( '/wp-json/forgedeck/v1/manifest', NOW - 6 ) )['body']['signing_required'] );
} );

t( 'manifest: safe content only', static function () {
	fresh();
	update_option( 'forgedeck_companion_signing_secret', SECRET );
	$r = call( 'manifest', array(), signed( '/wp-json/forgedeck/v1/manifest' ) );
	same( 200, $r['status'] );
	same( 'example-product', $r['body']['product_id'] );
	same( array( 'wordpress' ), $r['body']['component_ids'] );
	same( forgedeck_scopes(), $r['body']['scopes'] );
	same( array( '24h', '7d', '30d', '90d' ), $r['body']['windows'] );
	foreach ( array( TOKEN, forgedeck_hash_token( TOKEN ), SECRET ) as $needle ) {
		ok( false === strpos( $r['raw'], $needle ), 'manifest leaked a credential' );
	}
} );

finish();
