#!/usr/bin/env bash

MODULE=`perl -ne 'print $1 if m{all_from.+?([\w/.]+)}' Makefile.PL`;
perl=perl
$perl -v

rm -rf MANIFEST.bak Makefile.old *.tar.gz && \
pod2text $MODULE > README && \
$perl Makefile.PL && \
make manifest && \
make && \
TEST_AUTHOR=1 make test && \
TEST_AUTHOR=1 runprove 'xt/*.t' && \
make disttest && \
make dist && \
cp -f *.tar.gz dist/ && \
make clean && \
rm -rf MANIFEST.bak Makefile.old *.tar.gz && \
echo "All is OK"
