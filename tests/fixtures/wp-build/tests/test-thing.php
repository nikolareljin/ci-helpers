<?php
/**
 * Does NOT ship. Development-only, and in the build's default exclude list --
 * the self-test asserts it is absent from the archive.
 */

class Test_Thing extends WP_UnitTestCase {
	public function test_thing() {
		$this->assertSame( 'thing', ci_helpers_build_fixture_thing() );
	}
}
