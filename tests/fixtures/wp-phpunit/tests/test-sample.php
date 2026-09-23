<?php
class Test_Sample extends WP_UnitTestCase {
	public function test_double() { $this->assertSame( 6, sample_double( 3 ) ); }
	public function test_wp_is_loaded() { $this->assertTrue( function_exists( 'wp_insert_post' ) ); }
}
