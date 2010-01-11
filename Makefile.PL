use inc::Module::Install;

name     'AnyEvent-Worker';
all_from 'lib/AnyEvent/Worker.pm';
author   'Mons Anderson <mons@cpan.org>';
license  'perl';

build_requires 'Test::More';
build_requires 'Test::If';
build_requires 'Test::NoWarnings';

requires 'common::sense', 2;
requires 'AnyEvent', 5;
requires 'Storable';


auto_install;

WriteAll;

