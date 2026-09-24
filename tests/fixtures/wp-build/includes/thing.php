<?php
/**
 * Ships with the plugin: the package is useless without it, so its absence
 * from the archive is a failure the self-test must catch.
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

function ci_helpers_build_fixture_thing() {
	return 'thing';
}
