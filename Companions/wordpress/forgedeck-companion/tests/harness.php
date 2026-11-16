<?php
/**
 * Tiny dependency-free test harness shared by the standalone test scripts.
 *
 * @package ForgeDeck_Companion
 */

$GLOBALS['forgedeck_tests'] = array( 'pass' => 0, 'fail' => 0 );

function ok( $condition, $message = '' ) {
	if ( ! $condition ) {
		throw new Exception( 'assertion failed' . ( '' !== $message ? ': ' . $message : '' ) );
	}
}

function same( $expected, $actual, $message = '' ) {
	if ( $expected !== $actual ) {
		throw new Exception( ( '' !== $message ? $message . ': ' : '' ) . 'expected ' . var_export( $expected, true ) . ', got ' . var_export( $actual, true ) );
	}
}

function t( $name, callable $fn ) {
	try {
		$fn();
		++$GLOBALS['forgedeck_tests']['pass'];
		echo "ok   - $name\n";
	} catch ( Throwable $e ) {
		++$GLOBALS['forgedeck_tests']['fail'];
		echo "FAIL - $name\n       " . $e->getMessage() . ' (' . basename( $e->getFile() ) . ':' . $e->getLine() . ")\n";
	}
}

function finish() {
	$r = $GLOBALS['forgedeck_tests'];
	echo "\n{$r['pass']} passed, {$r['fail']} failed\n";
	exit( $r['fail'] > 0 ? 1 : 0 );
}
