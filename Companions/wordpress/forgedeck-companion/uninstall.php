<?php
/**
 * Uninstall: remove every option this plugin created (token hash, signing secret, settings).
 *
 * @package ForgeDeck_Companion
 */

if ( ! defined( 'WP_UNINSTALL_PLUGIN' ) ) {
	exit;
}

delete_option( 'forgedeck_companion_settings' );
delete_option( 'forgedeck_companion_token' );
delete_option( 'forgedeck_companion_signing_secret' );
delete_option( 'forgedeck_companion_flush_rewrite' );
