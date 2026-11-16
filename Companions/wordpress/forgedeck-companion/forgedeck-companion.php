<?php
/**
 * Plugin Name:       ForgeDeck Companion
 * Description:       Read-only, token-protected status and aggregate-count endpoints for the ForgeDeck macOS app. Everything is off until you enable it.
 * Version:           1.0.0
 * Requires at least: 5.5
 * Requires PHP:      7.4
 * License:           GPL-2.0-or-later
 * Text Domain:       forgedeck-companion
 *
 * @package ForgeDeck_Companion
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

define( 'FORGEDECK_COMPANION_VERSION', '1.0.0' );
define( 'FORGEDECK_COMPANION_FILE', __FILE__ );

require_once __DIR__ . '/includes/functions.php';
require_once __DIR__ . '/includes/class-forgedeck-companion-rest.php';
require_once __DIR__ . '/includes/class-forgedeck-companion-admin.php';

ForgeDeck_Companion_REST::init();
ForgeDeck_Companion_Admin::init();

/**
 * Optional pretty path: /_forgedeck/v1/<route> -> the REST route. Off by default.
 */
function forgedeck_companion_rewrite() {
	$settings = ForgeDeck_Companion_REST::settings();
	if ( $settings['pretty_path'] ) {
		add_rewrite_rule( '^_forgedeck/v1/?(.*)$', 'index.php?rest_route=/forgedeck/v1/$matches[1]', 'top' );
	}
	// Flush once after the setting changed (flag set by the settings page).
	if ( get_option( 'forgedeck_companion_flush_rewrite' ) ) {
		delete_option( 'forgedeck_companion_flush_rewrite' );
		flush_rewrite_rules( false );
	}
}
add_action( 'init', 'forgedeck_companion_rewrite' );

/**
 * Activation creates nothing that serves data: no token, every capability off.
 */
function forgedeck_companion_activate() {
	if ( false === get_option( ForgeDeck_Companion_REST::OPTION_SETTINGS, false ) ) {
		add_option( ForgeDeck_Companion_REST::OPTION_SETTINGS, forgedeck_default_settings() );
	}
}
register_activation_hook( __FILE__, 'forgedeck_companion_activate' );

/** Deactivation removes the optional rewrite rule. Settings stay until uninstall. */
function forgedeck_companion_deactivate() {
	flush_rewrite_rules( false );
}
register_deactivation_hook( __FILE__, 'forgedeck_companion_deactivate' );

// WooCommerce HPOS: this plugin only uses wc_get_orders(), which works with both order stores.
add_action(
	'before_woocommerce_init',
	static function () {
		if ( class_exists( '\Automattic\WooCommerce\Utilities\FeaturesUtil' ) ) {
			\Automattic\WooCommerce\Utilities\FeaturesUtil::declare_compatibility( 'custom_order_tables', __FILE__, true );
		}
	}
);
