use inc::Module::Install;

name     'AnyEvent-Worker';
all_from 'lib/AnyEvent/Worker.pm';
author   'Mons Anderson <mons@cpan.org>';
license  'perl';

build_requires 'Test::More';

auto_install;

WriteAll;

