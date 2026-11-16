<?php
/**
 * REST routes for the ForgeDeck companion: GET-only, default-deny.
 *
 * @package ForgeDeck_Companion
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * Registers /wp-json/forgedeck/v1/{manifest,status,metrics,leads,events}.
 */
class ForgeDeck_Companion_REST {

	const REST_NAMESPACE  = 'forgedeck/v1';
	const OPTION_SETTINGS = 'forgedeck_companion_settings';
	const OPTION_TOKEN    = 'forgedeck_companion_token';
	const OPTION_SECRET   = 'forgedeck_companion_signing_secret';
	const RATE_LIMIT      = 60;
	const RATE_WINDOW     = 60;

	/**
	 * Clock override for tests (callable returning unix seconds).
	 *
	 * @var callable|null
	 */
	public static $clock = null;

	/**
	 * Per-request memo so the gate runs once even if WordPress asks twice.
	 *
	 * @var array<string,true|WP_Error>
	 */
	private static $decisions = array();

	/**
	 * Token record that passed the gate for the current request.
	 *
	 * @var array|null
	 */
	private static $token = null;

	/** Hook everything up. */
	public static function init() {
		add_action( 'rest_api_init', array( __CLASS__, 'register_routes' ) );
		add_filter( 'rest_post_dispatch', array( __CLASS__, 'shape_response' ), 10, 3 );
	}

	/** @return int */
	public static function now() {
		return null !== self::$clock ? (int) call_user_func( self::$clock ) : time();
	}

	/** Forget per-request state (tests). */
	public static function reset() {
		self::$decisions = array();
		self::$token     = null;
	}

	/** @return array normalised settings */
	public static function settings() {
		return forgedeck_normalize_settings( get_option( self::OPTION_SETTINGS, array() ) );
	}

	/** @return array[] stored token records (zero or one) */
	public static function token_records() {
		$record = get_option( self::OPTION_TOKEN, null );
		if ( ! is_array( $record ) || empty( $record['hash'] ) ) {
			return array();
		}
		return array(
			array(
				'id'         => isset( $record['id'] ) && is_string( $record['id'] ) ? $record['id'] : 'forgedeck',
				'hash'       => (string) $record['hash'],
				'scopes'     => forgedeck_sanitize_scopes( isset( $record['scopes'] ) ? $record['scopes'] : array() ),
				'revoked'    => ! empty( $record['revoked'] ),
				'expires_at' => isset( $record['expires_at'] ) && is_int( $record['expires_at'] ) ? $record['expires_at'] : null,
			),
		);
	}

	/** @return string|null signing secret, if request signing is enabled */
	public static function signing_secret() {
		$secret = get_option( self::OPTION_SECRET, '' );
		return ( is_string( $secret ) && strlen( $secret ) >= 16 ) ? $secret : null;
	}

	/** Register the read-only routes. No route accepts anything but GET. */
	public static function register_routes() {
		foreach ( array_keys( forgedeck_routes() ) as $route ) {
			register_rest_route(
				self::REST_NAMESPACE,
				'/' . $route,
				array(
					'methods'             => 'GET',
					'callback'            => array( __CLASS__, 'handle_' . $route ),
					'permission_callback' => static function ( $request ) use ( $route ) {
						return ForgeDeck_Companion_REST::authorize( $request, $route );
					},
					'show_in_index'       => false,
				)
			);
		}
	}

	/**
	 * The gate: configured -> HTTPS -> token -> rate limit -> signature -> capability -> scope.
	 *
	 * @param WP_REST_Request $request Request.
	 * @param string          $route   Route name.
	 * @return true|WP_Error
	 */
	public static function authorize( $request, $route ) {
		// Keyed by request object: a decision is never reused for a different request.
		$key = spl_object_id( $request ) . ':' . $route;
		if ( ! isset( self::$decisions[ $key ] ) ) {
			self::$decisions[ $key ] = self::decide( $request, $route );
		}
		return self::$decisions[ $key ];
	}

	/**
	 * @param WP_REST_Request $request Request.
	 * @param string          $route   Route name.
	 * @return true|WP_Error
	 */
	private static function decide( $request, $route ) {
		$now      = self::now();
		$settings = self::settings();
		$records  = self::token_records();
		$routes   = forgedeck_routes();

		// Default deny: nothing is served until a product id and a token exist.
		if ( '' === $settings['product_id'] || empty( $records ) ) {
			return self::error( 503, 'not_configured', 'Companion is not configured' );
		}

		$remote = isset( $_SERVER['REMOTE_ADDR'] ) ? (string) wp_unslash( $_SERVER['REMOTE_ADDR'] ) : 'unknown'; // phpcs:ignore WordPress.Security.ValidatedSanitizedInput.InputNotSanitized
		if ( ! forgedeck_is_secure_request( is_ssl(), $remote, $settings['trust_proxy'], $request->get_header( 'x_forwarded_proto' ) ) ) {
			return self::error( 403, 'https_required', 'HTTPS is required' );
		}

		$check = forgedeck_verify_token( forgedeck_extract_bearer( $request->get_header( 'authorization' ) ), $records, $now );
		if ( ! $check['ok'] ) {
			$limited = self::rate_limit( 'addr:' . $remote, $now );
			if ( null !== $limited ) {
				return $limited;
			}
			return self::error( 401, 'unauthorized', 'Missing or invalid bearer token', array( 'WWW-Authenticate' => 'Bearer' ) );
		}
		$token = $check['record'];

		$limited = self::rate_limit( 'token:' . $token['id'], $now );
		if ( null !== $limited ) {
			return $limited;
		}

		$secret = self::signing_secret();
		if ( null !== $secret ) {
			$timestamp = $request->get_header( 'x_forgedeck_timestamp' );
			$signature = $request->get_header( 'x_forgedeck_signature' );
			// The request target exactly as the client sent it (works for /wp-json/... and /_forgedeck/v1/...).
			$target = isset( $_SERVER['REQUEST_URI'] ) ? (string) wp_unslash( $_SERVER['REQUEST_URI'] ) : ''; // phpcs:ignore WordPress.Security.ValidatedSanitizedInput.InputNotSanitized
			$result = forgedeck_verify_signature( $secret, $timestamp, $signature, (string) $request->get_method(), $target, $now );
			if ( ! $result['ok'] ) {
				return self::error( 401, 'invalid_signature', 'Missing, invalid or stale request signature' );
			}
			$nonce_key = forgedeck_nonce_key( $timestamp, $signature );
			if ( false !== get_transient( $nonce_key ) ) {
				return self::error( 401, 'replayed_request', 'Request signature was already used' );
			}
			set_transient( $nonce_key, 1, FORGEDECK_MAX_SKEW_SECONDS * 2 + 1 );
		}

		// Unknown routes and disabled capabilities are indistinguishable.
		if ( ! isset( $routes[ $route ] ) ) {
			return self::error( 404, 'not_found', 'Not found' );
		}
		$capability = $routes[ $route ]['capability'];
		if ( null !== $capability && ! in_array( $capability, forgedeck_enabled_capabilities( $settings ), true ) ) {
			return self::error( 404, 'not_found', 'Not found' );
		}
		if ( ! forgedeck_has_scope( $token, $routes[ $route ]['scope'] ) ) {
			return self::error( 403, 'insufficient_scope', 'Token lacks scope ' . $routes[ $route ]['scope'] );
		}

		self::$token = $token;
		return true;
	}

	/**
	 * Best-effort fixed-window limiter stored in transients.
	 *
	 * @param string $key Bucket key.
	 * @param int    $now Current time.
	 * @return WP_Error|null Error when the limit is exceeded.
	 */
	private static function rate_limit( $key, $now ) {
		$name = 'forgedeck_rl_' . substr( hash( 'sha256', $key ), 0, 40 );
		$step = forgedeck_rate_limit_step( get_transient( $name ), $now, self::RATE_LIMIT, self::RATE_WINDOW );
		set_transient( $name, $step['bucket'], self::RATE_WINDOW * 2 );
		if ( ! $step['allowed'] ) {
			return self::error( 429, 'rate_limited', 'Too many requests', array( 'Retry-After' => (string) $step['retry_after'] ) );
		}
		return null;
	}

	/**
	 * @param int    $status  HTTP status.
	 * @param string $code    Error code.
	 * @param string $message Message.
	 * @param array  $headers Extra response headers.
	 * @return WP_Error
	 */
	private static function error( $status, $code, $message, array $headers = array() ) {
		return new WP_Error(
			$code,
			$message,
			array(
				'status'            => $status,
				'forgedeck_headers' => $headers,
			)
		);
	}

	/**
	 * Give every response in our namespace the contract shape and no-store headers.
	 *
	 * @param WP_HTTP_Response $response Response.
	 * @param WP_REST_Server   $server   Server.
	 * @param WP_REST_Request  $request  Request.
	 * @return WP_HTTP_Response
	 */
	public static function shape_response( $response, $server, $request ) {
		$route = (string) $request->get_route();
		if ( 0 !== strpos( $route, '/' . self::REST_NAMESPACE ) || ! is_object( $response ) ) {
			return $response;
		}
		$response->header( 'Cache-Control', 'no-store' );
		$response->header( 'X-Content-Type-Options', 'nosniff' );
		$data = $response->get_data();
		if ( $response->get_status() >= 400 && is_array( $data ) && isset( $data['code'] ) && ! isset( $data['error'] ) ) {
			$code    = (string) $data['code'];
			$message = isset( $data['message'] ) ? (string) $data['message'] : 'Error';
			if ( isset( $data['data']['forgedeck_headers'] ) && is_array( $data['data']['forgedeck_headers'] ) ) {
				foreach ( $data['data']['forgedeck_headers'] as $name => $value ) {
					$response->header( $name, $value );
				}
			} else {
				// WordPress' own errors (e.g. rest_no_route): do not echo details.
				$code    = 404 === $response->get_status() ? 'not_found' : 'invalid_request';
				$message = 404 === $response->get_status() ? 'Not found' : 'Invalid request';
			}
			$response->set_data( forgedeck_error_body( $code, $message ) );
		}
		return $response;
	}

	/**
	 * Fields common to every success body. product_id and environment come from
	 * stored settings only, never from the request.
	 *
	 * @param array $settings Settings.
	 * @return array
	 */
	private static function base_body( array $settings ) {
		return array(
			'schema_version' => FORGEDECK_SCHEMA_VERSION,
			'product_id'     => $settings['product_id'],
			'environment'    => $settings['environment'],
			'observed_at'    => forgedeck_iso( self::now() ),
		);
	}

	/**
	 * @param array $body   Body.
	 * @param int   $status Status.
	 * @return WP_REST_Response
	 */
	private static function respond( array $body, $status = 200 ) {
		return new WP_REST_Response( $body, $status );
	}

	/**
	 * @param string $code    Error code.
	 * @param string $message Message.
	 * @return WP_REST_Response
	 */
	private static function bad_request( $code, $message ) {
		return self::respond( forgedeck_error_body( $code, $message ), 400 );
	}

	/** @return WP_REST_Response */
	public static function handle_manifest() {
		$settings = self::settings();
		$body     = self::base_body( $settings );

		$body['component_ids']    = array( $settings['component_id'] );
		$body['capabilities']     = forgedeck_enabled_capabilities( $settings );
		$body['scopes']           = is_array( self::$token ) ? self::$token['scopes'] : array();
		$body['windows']          = array_keys( forgedeck_windows() );
		$body['signing_required'] = null !== self::signing_secret();
		$body['metadata']         = (object) array(
			'platform'           => 'wordpress',
			'woocommerce_active' => self::woocommerce_active() ? 'yes' : 'no',
		);
		$body['companion']        = array(
			'name'    => 'forgedeck-companion-wordpress',
			'version' => defined( 'FORGEDECK_COMPANION_VERSION' ) ? FORGEDECK_COMPANION_VERSION : '1.0.0',
		);
		return self::respond( $body );
	}

	/** @return WP_REST_Response */
	public static function handle_status() {
		$settings = self::settings();
		$enabled  = forgedeck_enabled_capabilities( $settings );
		$metrics  = array();
		if ( in_array( 'metrics', $enabled, true ) && forgedeck_has_scope( self::$token, 'metrics:read' ) ) {
			foreach ( self::collect_metrics( '24h', 86400 ) as $name => $value ) {
				$metrics[ $name . '_24h' ] = $value;
			}
		}
		return self::respond(
			array(
				'schema_version' => FORGEDECK_SCHEMA_VERSION,
				'product_id'     => $settings['product_id'],
				'component_id'   => $settings['component_id'],
				'environment'    => $settings['environment'],
				'observed_at'    => forgedeck_iso( self::now() ),
				'release'        => self::release(),
				'health'         => self::health(),
				'metrics'        => (object) $metrics,
				'capabilities'   => $enabled,
			)
		);
	}

	/**
	 * @param WP_REST_Request $request Request.
	 * @return WP_REST_Response
	 */
	public static function handle_metrics( $request ) {
		$window  = $request->get_param( 'window' );
		$window  = null === $window ? '24h' : $window;
		$seconds = forgedeck_validate_window( $window );
		if ( null === $seconds ) {
			return self::bad_request( 'invalid_window', 'window must be one of: ' . implode( ', ', array_keys( forgedeck_windows() ) ) );
		}
		$body            = self::base_body( self::settings() );
		$body['window']  = $window;
		$body['source']  = 'wordpress';
		$body['metrics'] = (object) self::collect_metrics( $window, $seconds );
		return self::respond( $body );
	}

	/**
	 * @param WP_REST_Request $request Request.
	 * @return WP_REST_Response
	 */
	public static function handle_leads( $request ) {
		return self::handle_list( $request, 'forgedeck_companion_leads', forgedeck_lead_kinds() );
	}

	/**
	 * @param WP_REST_Request $request Request.
	 * @return WP_REST_Response
	 */
	public static function handle_events( $request ) {
		return self::handle_list( $request, 'forgedeck_companion_events', forgedeck_event_kinds() );
	}

	/**
	 * Shared list handler. Items come only from a site-defined filter and are reduced to the
	 * contract's whitelisted fields; this plugin never reads contact data itself.
	 *
	 * @param WP_REST_Request $request Request.
	 * @param string          $filter  Filter supplying raw items.
	 * @param string[]        $kinds   Allowed kinds.
	 * @return WP_REST_Response
	 */
	private static function handle_list( $request, $filter, array $kinds ) {
		$limit     = FORGEDECK_DEFAULT_LIMIT;
		$raw_limit = $request->get_param( 'limit' );
		if ( null !== $raw_limit ) {
			$limit = forgedeck_parse_limit( $raw_limit );
			if ( null === $limit ) {
				return self::bad_request( 'invalid_limit', 'limit must be an integer between 1 and ' . FORGEDECK_MAX_LIMIT );
			}
		}
		$after      = null;
		$raw_cursor = $request->get_param( 'cursor' );
		if ( null !== $raw_cursor ) {
			$after = forgedeck_decode_cursor( $raw_cursor );
			if ( null === $after ) {
				return self::bad_request( 'invalid_cursor', 'cursor is not valid' );
			}
		}
		$range = forgedeck_resolve_range( $request->get_param( 'since' ), $request->get_param( 'until' ), self::now() );
		if ( ! $range['ok'] ) {
			return self::bad_request( $range['code'], $range['message'] );
		}
		$query = array(
			'since' => $range['since'],
			'until' => $range['until'],
			'after' => $after,
			'limit' => $limit + 1,
		);
		$page  = forgedeck_paginate( apply_filters( $filter, array(), $query ), $kinds, $range['since'], $range['until'], $after, $limit, false );
		$body  = self::base_body( self::settings() );

		$body['items']       = $page['items'];
		$body['next_cursor'] = $page['next_cursor'];
		return self::respond( $body );
	}

	/** @return bool */
	private static function woocommerce_active() {
		return class_exists( 'WooCommerce' ) && function_exists( 'wc_get_orders' );
	}

	/**
	 * Aggregate counters only. No rows, names, addresses or order contents are read out.
	 *
	 * @param string $window  Window key.
	 * @param int    $seconds Window length.
	 * @return array<string,int>
	 */
	private static function collect_metrics( $window, $seconds ) {
		global $wpdb;
		$settings = self::settings();
		$since    = self::now() - $seconds;
		$metrics  = array();

		$signups = $wpdb->get_var( $wpdb->prepare( "SELECT COUNT(*) FROM {$wpdb->users} WHERE user_registered >= %s", gmdate( 'Y-m-d H:i:s', $since ) ) );
		if ( null !== $signups ) {
			$metrics['signups'] = (int) $signups;
		}

		// WooCommerce order COUNTS: only if WooCommerce is active and the admin switched them on.
		if ( $settings['woocommerce_counts'] && self::woocommerce_active() ) {
			$metrics['orders']      = self::count_orders( $since, array_keys( wc_get_order_statuses() ) );
			$metrics['paid_orders'] = self::count_orders( $since, array( 'wc-processing', 'wc-completed' ) );
		}

		/**
		 * Let the site add its own aggregate counters (e.g. 'leads' from a form plugin).
		 * Only names in forgedeck_allowed_metrics() with non-negative integer values survive.
		 */
		$metrics = apply_filters( 'forgedeck_companion_metrics', $metrics, $window, $seconds );
		return forgedeck_sanitize_metrics( $metrics, forgedeck_allowed_metrics() );
	}

	/**
	 * @param int      $since    Unix time.
	 * @param string[] $statuses Order statuses.
	 * @return int
	 */
	private static function count_orders( $since, array $statuses ) {
		$result = wc_get_orders(
			array(
				'type'         => 'shop_order',
				'status'       => $statuses,
				'date_created' => '>=' . (int) $since,
				'limit'        => 1,
				'paginate'     => true,
				'return'       => 'ids',
			)
		);
		return ( is_object( $result ) && isset( $result->total ) ) ? (int) $result->total : 0;
	}

	/** @return array release block from the CI-written fingerprint file, if present */
	private static function release() {
		$path = defined( 'FORGEDECK_RELEASE_FILE' ) ? (string) FORGEDECK_RELEASE_FILE : WP_CONTENT_DIR . '/forgedeck-release.json';
		$raw  = null;
		if ( is_readable( $path ) ) {
			$contents = file_get_contents( $path ); // phpcs:ignore WordPress.WP.AlternativeFunctions.file_get_contents_file_get_contents
			$raw      = false === $contents ? null : json_decode( $contents, true );
		}
		return forgedeck_normalize_release( apply_filters( 'forgedeck_companion_release', $raw ) );
	}

	/** @return array health block */
	private static function health() {
		global $wpdb;
		$db_ok  = '1' === (string) $wpdb->get_var( 'SELECT 1' );
		$checks = array(
			array(
				'id'    => 'database',
				'state' => $db_ok ? 'healthy' : 'unhealthy',
			),
		);
		/** Add checks as array( 'id' => ..., 'state' => healthy|degraded|unhealthy ). Only id + state are exposed. */
		$checks = apply_filters( 'forgedeck_companion_health_checks', $checks );
		return forgedeck_normalize_health( $checks );
	}
}
