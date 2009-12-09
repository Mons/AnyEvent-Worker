#!/usr/bin/env perl -w

use lib::abs "../lib";
use Test::More tests => 1;

BEGIN {
	use_ok( 'AnyEvent::Worker' );
}

diag( "Testing AnyEvent::Worker $AnyEvent::Worker::VERSION, using AnyEvent $AnyEvent::VERSION, Perl $], $^X" );
