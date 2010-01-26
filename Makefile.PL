use inc::Module::Install;

name     'AnyEvent-Worker';
all_from 'lib/AnyEvent/Worker.pm';
version   my $v = '0.01';
author   'Mons Anderson <mons@cpan.org>';
license  'perl';

build_requires 'Test::More';
build_requires 'Test::If';
build_requires 'Test::NoWarnings';

requires 'common::sense', 2;
requires 'AnyEvent', 5;
requires 'Storable';

provides 'AnyEvent::Worker' => {
	version => $v,
	file    => 'lib/AnyEvent/Worker.pm',
};

provides 'AnyEvent::Worker::Pool' => {
	version => $v,
	file    => 'lib/AnyEvent/Worker/Pool.pm',
};

auto_install;

WriteAll;

