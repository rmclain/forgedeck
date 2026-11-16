<?php
/**
 * Settings page: Settings -> ForgeDeck Companion.
 *
 * @package ForgeDeck_Companion
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * Minimal admin UI. Requires manage_options; every form is nonce-protected.
 */
class ForgeDeck_Companion_Admin {

	const PAGE_SLUG    = 'forgedeck-companion';
	const NONCE_ACTION = 'forgedeck_companion_admin';
	const NONCE_FIELD  = 'forgedeck_companion_nonce';

	/**
	 * A freshly generated token, held in memory for this one page render only.
	 *
	 * @var string|null
	 */
	private static $new_token = null;

	/**
	 * A freshly generated signing secret, shown once.
	 *
	 * @var string|null
	 */
	private static $new_secret = null;

	/**
	 * Notice for the current render.
	 *
	 * @var string
	 */
	private static $notice = '';

	/** Hook everything up. */
	public static function init() {
		add_action( 'admin_menu', array( __CLASS__, 'menu' ) );
	}

	/** Register the settings page and its POST handler. */
	public static function menu() {
		$hook = add_options_page(
			__( 'ForgeDeck Companion', 'forgedeck-companion' ),
			__( 'ForgeDeck Companion', 'forgedeck-companion' ),
			'manage_options',
			self::PAGE_SLUG,
			array( __CLASS__, 'render' )
		);
		if ( $hook ) {
			add_action( 'load-' . $hook, array( __CLASS__, 'handle_post' ) );
		}
	}

	/**
	 * Handle form submissions. The page is rendered in the same request (no redirect) so a new
	 * token can be displayed once without ever being written to the database in plaintext.
	 */
	public static function handle_post() {
		if ( ! isset( $_SERVER['REQUEST_METHOD'] ) || 'POST' !== $_SERVER['REQUEST_METHOD'] || ! isset( $_POST['forgedeck_action'] ) ) {
			return;
		}
		if ( ! current_user_can( 'manage_options' ) ) {
			wp_die( esc_html__( 'You are not allowed to manage the ForgeDeck companion.', 'forgedeck-companion' ), 403 );
		}
		check_admin_referer( self::NONCE_ACTION, self::NONCE_FIELD );

		$action = sanitize_key( wp_unslash( $_POST['forgedeck_action'] ) );
		switch ( $action ) {
			case 'save_settings':
				self::save_settings();
				break;
			case 'generate_token':
				self::generate_token();
				break;
			case 'revoke_token':
				self::revoke_token();
				break;
			case 'generate_secret':
				self::$new_secret = 'fds_' . substr( forgedeck_generate_token(), 4 );
				update_option( ForgeDeck_Companion_REST::OPTION_SECRET, self::$new_secret, false );
				self::$notice = __( 'Request signing is now required. Copy the signing secret below; it is shown only once.', 'forgedeck-companion' );
				break;
			case 'clear_secret':
				delete_option( ForgeDeck_Companion_REST::OPTION_SECRET );
				self::$notice = __( 'Request signing disabled.', 'forgedeck-companion' );
				break;
		}
	}

	/** Save product/environment/capability settings. Nonce and capability were checked by handle_post(). */
	private static function save_settings() {
		// phpcs:disable WordPress.Security.NonceVerification.Missing -- verified in handle_post().
		$raw = array(
			'product_id'         => isset( $_POST['product_id'] ) ? sanitize_text_field( wp_unslash( $_POST['product_id'] ) ) : '',
			'environment'        => isset( $_POST['environment'] ) ? sanitize_key( wp_unslash( $_POST['environment'] ) ) : '',
			'component_id'       => isset( $_POST['component_id'] ) ? sanitize_text_field( wp_unslash( $_POST['component_id'] ) ) : '',
			'capabilities'       => array(),
			'woocommerce_counts' => isset( $_POST['woocommerce_counts'] ) ? '1' : '',
			'trust_proxy'        => isset( $_POST['trust_proxy'] ) ? '1' : '',
			'pretty_path'        => isset( $_POST['pretty_path'] ) ? '1' : '',
		);
		foreach ( forgedeck_capabilities() as $cap ) {
			$raw['capabilities'][ $cap ] = isset( $_POST['capabilities'][ $cap ] ) ? '1' : '';
		}
		// phpcs:enable

		$previous = ForgeDeck_Companion_REST::settings();
		$settings = forgedeck_normalize_settings( $raw );
		update_option( ForgeDeck_Companion_REST::OPTION_SETTINGS, $settings );
		if ( $previous['pretty_path'] !== $settings['pretty_path'] ) {
			update_option( 'forgedeck_companion_flush_rewrite', 1, false );
		}
		self::$notice = ( '' === $settings['product_id'] )
			? __( 'Saved, but the product ID is missing or invalid (lowercase letters, digits, dot, dash, underscore). Nothing is served without it.', 'forgedeck-companion' )
			: __( 'Settings saved.', 'forgedeck-companion' );
	}

	/** Generate (or rotate) the token. Only the SHA-256 hash is stored. */
	private static function generate_token() {
		// phpcs:ignore WordPress.Security.NonceVerification.Missing -- verified in handle_post().
		$scopes = isset( $_POST['scopes'] ) && is_array( $_POST['scopes'] ) ? array_map( 'sanitize_text_field', wp_unslash( $_POST['scopes'] ) ) : array();
		$scopes = forgedeck_sanitize_scopes( $scopes );
		if ( empty( $scopes ) ) {
			self::$notice = __( 'Select at least one scope for the token.', 'forgedeck-companion' );
			return;
		}
		self::$new_token = forgedeck_generate_token();
		update_option(
			ForgeDeck_Companion_REST::OPTION_TOKEN,
			array(
				'id'         => 'wp-' . substr( forgedeck_hash_token( self::$new_token ), 0, 8 ),
				'hash'       => forgedeck_hash_token( self::$new_token ),
				'scopes'     => $scopes,
				'created_at' => time(),
				'revoked'    => false,
				'expires_at' => null,
			),
			false
		);
		self::$notice = __( 'New token generated. Any previous token stopped working immediately. Copy the token below; it is shown only once.', 'forgedeck-companion' );
	}

	/** Revoke the current token. The record is kept (marked revoked) so the UI can show it. */
	private static function revoke_token() {
		$record = get_option( ForgeDeck_Companion_REST::OPTION_TOKEN, null );
		if ( is_array( $record ) ) {
			$record['revoked'] = true;
			update_option( ForgeDeck_Companion_REST::OPTION_TOKEN, $record, false );
		}
		self::$notice = __( 'Token revoked. The companion now refuses every request until a new token is generated.', 'forgedeck-companion' );
	}

	/** Hidden fields shared by every form on the page. */
	private static function form_fields( $action ) {
		wp_nonce_field( self::NONCE_ACTION, self::NONCE_FIELD );
		printf( '<input type="hidden" name="forgedeck_action" value="%s" />', esc_attr( $action ) );
	}

	/** Render the page. */
	public static function render() {
		if ( ! current_user_can( 'manage_options' ) ) {
			return;
		}
		$settings = ForgeDeck_Companion_REST::settings();
		$token    = get_option( ForgeDeck_Companion_REST::OPTION_TOKEN, null );
		$has_tok  = is_array( $token ) && ! empty( $token['hash'] );
		$revoked  = $has_tok && ! empty( $token['revoked'] );
		$signing  = null !== ForgeDeck_Companion_REST::signing_secret();
		$woo      = class_exists( 'WooCommerce' );
		$rest_url = rest_url( ForgeDeck_Companion_REST::REST_NAMESPACE . '/status' );
		$cap_help = array(
			'status'  => __( 'Release fingerprint and database health (GET …/status).', 'forgedeck-companion' ),
			'metrics' => __( 'Aggregate counts only, e.g. new user registrations (GET …/metrics).', 'forgedeck-companion' ),
			'leads'   => __( 'Redacted lead events supplied by your own code via the forgedeck_companion_leads filter. Empty otherwise.', 'forgedeck-companion' ),
			'events'  => __( 'Change/incident events supplied by your own code via the forgedeck_companion_events filter. Empty otherwise.', 'forgedeck-companion' ),
		);
		?>
		<div class="wrap">
			<h1><?php esc_html_e( 'ForgeDeck Companion', 'forgedeck-companion' ); ?></h1>
			<p><?php esc_html_e( 'Read-only endpoints for the ForgeDeck app. Nothing is served until a product ID is set, a token is generated and a capability is enabled.', 'forgedeck-companion' ); ?></p>

			<?php if ( '' !== self::$notice ) : ?>
				<div class="notice notice-info"><p><?php echo esc_html( self::$notice ); ?></p></div>
			<?php endif; ?>

			<?php if ( null !== self::$new_token ) : ?>
				<div class="notice notice-warning">
					<p><strong><?php esc_html_e( 'Your new token (shown once, never stored in readable form):', 'forgedeck-companion' ); ?></strong></p>
					<p><input type="text" class="large-text code" readonly="readonly" onclick="this.select();" value="<?php echo esc_attr( self::$new_token ); ?>" /></p>
				</div>
			<?php endif; ?>

			<?php if ( null !== self::$new_secret ) : ?>
				<div class="notice notice-warning">
					<p><strong><?php esc_html_e( 'Your new signing secret (shown once):', 'forgedeck-companion' ); ?></strong></p>
					<p><input type="text" class="large-text code" readonly="readonly" onclick="this.select();" value="<?php echo esc_attr( self::$new_secret ); ?>" /></p>
				</div>
			<?php endif; ?>

			<h2><?php esc_html_e( 'Endpoint', 'forgedeck-companion' ); ?></h2>
			<p><code><?php echo esc_html( $rest_url ); ?></code></p>

			<h2><?php esc_html_e( 'Settings', 'forgedeck-companion' ); ?></h2>
			<form method="post" action="">
				<?php self::form_fields( 'save_settings' ); ?>
				<table class="form-table" role="presentation">
					<tr>
						<th scope="row"><label for="forgedeck_product_id"><?php esc_html_e( 'Product ID', 'forgedeck-companion' ); ?></label></th>
						<td>
							<input type="text" id="forgedeck_product_id" name="product_id" class="regular-text" value="<?php echo esc_attr( $settings['product_id'] ); ?>" pattern="[a-z0-9][a-z0-9._-]{0,62}" />
							<p class="description"><?php esc_html_e( 'Must match the product ID configured in ForgeDeck.', 'forgedeck-companion' ); ?></p>
						</td>
					</tr>
					<tr>
						<th scope="row"><label for="forgedeck_environment"><?php esc_html_e( 'Environment', 'forgedeck-companion' ); ?></label></th>
						<td>
							<select id="forgedeck_environment" name="environment">
								<?php foreach ( forgedeck_environments() as $env ) : ?>
									<option value="<?php echo esc_attr( $env ); ?>" <?php selected( $settings['environment'], $env ); ?>><?php echo esc_html( $env ); ?></option>
								<?php endforeach; ?>
							</select>
						</td>
					</tr>
					<tr>
						<th scope="row"><label for="forgedeck_component_id"><?php esc_html_e( 'Component ID', 'forgedeck-companion' ); ?></label></th>
						<td><input type="text" id="forgedeck_component_id" name="component_id" class="regular-text" value="<?php echo esc_attr( $settings['component_id'] ); ?>" /></td>
					</tr>
					<tr>
						<th scope="row"><?php esc_html_e( 'Capabilities', 'forgedeck-companion' ); ?></th>
						<td>
							<?php foreach ( forgedeck_capabilities() as $cap ) : ?>
								<label>
									<input type="checkbox" name="capabilities[<?php echo esc_attr( $cap ); ?>]" value="1" <?php checked( $settings['capabilities'][ $cap ] ); ?> />
									<strong><?php echo esc_html( $cap ); ?></strong> &mdash; <?php echo esc_html( $cap_help[ $cap ] ); ?>
								</label><br />
							<?php endforeach; ?>
							<p class="description"><?php esc_html_e( 'All off by default. A disabled capability answers 404.', 'forgedeck-companion' ); ?></p>
						</td>
					</tr>
					<tr>
						<th scope="row"><?php esc_html_e( 'WooCommerce', 'forgedeck-companion' ); ?></th>
						<td>
							<label>
								<input type="checkbox" name="woocommerce_counts" value="1" <?php checked( $settings['woocommerce_counts'] ); ?> />
								<?php esc_html_e( 'Include WooCommerce order counts in metrics (counts only: no customers, totals or order contents).', 'forgedeck-companion' ); ?>
							</label>
							<p class="description">
								<?php
								echo esc_html(
									$woo
										? __( 'WooCommerce is active. Requires the metrics capability.', 'forgedeck-companion' )
										: __( 'WooCommerce is not active; this option has no effect.', 'forgedeck-companion' )
								);
								?>
							</p>
						</td>
					</tr>
					<tr>
						<th scope="row"><?php esc_html_e( 'Transport', 'forgedeck-companion' ); ?></th>
						<td>
							<label>
								<input type="checkbox" name="trust_proxy" value="1" <?php checked( $settings['trust_proxy'] ); ?> />
								<?php esc_html_e( 'Trust X-Forwarded-Proto (only if this site is behind a reverse proxy or load balancer you control).', 'forgedeck-companion' ); ?>
							</label><br />
							<label>
								<input type="checkbox" name="pretty_path" value="1" <?php checked( $settings['pretty_path'] ); ?> />
								<?php esc_html_e( 'Also answer at /_forgedeck/v1/… (adds a rewrite rule; needs pretty permalinks).', 'forgedeck-companion' ); ?>
							</label>
							<p class="description"><?php esc_html_e( 'HTTPS is always required, except for requests from the server itself (loopback).', 'forgedeck-companion' ); ?></p>
						</td>
					</tr>
				</table>
				<?php submit_button( __( 'Save settings', 'forgedeck-companion' ) ); ?>
			</form>

			<h2><?php esc_html_e( 'Access token', 'forgedeck-companion' ); ?></h2>
			<p>
				<?php
				if ( ! $has_tok ) {
					esc_html_e( 'No token exists. The companion refuses every request.', 'forgedeck-companion' );
				} elseif ( $revoked ) {
					esc_html_e( 'The token is revoked. The companion refuses every request.', 'forgedeck-companion' );
				} else {
					printf(
						/* translators: 1: token id, 2: comma-separated scopes, 3: creation date */
						esc_html__( 'Active token %1$s with scopes: %2$s (created %3$s). Only its SHA-256 hash is stored.', 'forgedeck-companion' ),
						'<code>' . esc_html( isset( $token['id'] ) ? (string) $token['id'] : '' ) . '</code>',
						esc_html( implode( ', ', forgedeck_sanitize_scopes( isset( $token['scopes'] ) ? $token['scopes'] : array() ) ) ),
						esc_html( isset( $token['created_at'] ) ? gmdate( 'Y-m-d H:i', (int) $token['created_at'] ) . ' UTC' : '' )
					);
				}
				?>
			</p>
			<form method="post" action="">
				<?php self::form_fields( 'generate_token' ); ?>
				<fieldset>
					<legend class="screen-reader-text"><?php esc_html_e( 'Token scopes', 'forgedeck-companion' ); ?></legend>
					<?php foreach ( forgedeck_scopes() as $scope ) : ?>
						<label style="margin-right:1em;">
							<input type="checkbox" name="scopes[]" value="<?php echo esc_attr( $scope ); ?>" <?php checked( 'status:read' === $scope ); ?> />
							<code><?php echo esc_html( $scope ); ?></code>
						</label>
					<?php endforeach; ?>
				</fieldset>
				<?php submit_button( $has_tok ? __( 'Rotate token (replaces the current one)', 'forgedeck-companion' ) : __( 'Generate token', 'forgedeck-companion' ), 'secondary' ); ?>
			</form>
			<?php if ( $has_tok && ! $revoked ) : ?>
				<form method="post" action="">
					<?php self::form_fields( 'revoke_token' ); ?>
					<?php submit_button( __( 'Revoke token', 'forgedeck-companion' ), 'delete' ); ?>
				</form>
			<?php endif; ?>

			<h2><?php esc_html_e( 'Request signing (optional)', 'forgedeck-companion' ); ?></h2>
			<p>
				<?php
				echo esc_html(
					$signing
						? __( 'Enabled: every request must also carry a valid X-ForgeDeck-Timestamp and X-ForgeDeck-Signature.', 'forgedeck-companion' )
						: __( 'Disabled. When enabled, the signing secret has to be stored readable in the database (HMAC needs it), unlike the token.', 'forgedeck-companion' )
				);
				?>
			</p>
			<form method="post" action="" style="display:inline-block;margin-right:1em;">
				<?php self::form_fields( 'generate_secret' ); ?>
				<?php submit_button( $signing ? __( 'Rotate signing secret', 'forgedeck-companion' ) : __( 'Enable signing', 'forgedeck-companion' ), 'secondary', 'submit', false ); ?>
			</form>
			<?php if ( $signing ) : ?>
				<form method="post" action="" style="display:inline-block;">
					<?php self::form_fields( 'clear_secret' ); ?>
					<?php submit_button( __( 'Disable signing', 'forgedeck-companion' ), 'delete', 'submit', false ); ?>
				</form>
			<?php endif; ?>
		</div>
		<?php
	}
}
