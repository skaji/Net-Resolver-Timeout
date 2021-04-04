#!/usr/bin/env perl
use strict;
use warnings;
use lib "lib", "../lib";
use Net::Resolver::Timeout;

my $r = Net::Resolver::Timeout->new;

warn "-> reverse_resolve 104.244.42.193 with timeout 1sec\n";
my $host = $r->reverse_resolve("104.244.42.193", timeout => 1);
if ($host) {
    warn "-> DONE $host\n";
} else {
    warn "-> DONE ", $r->error, "\n";
}

warn "-> resolve www.google.com with timeout 1sec\n";
my @ip = $r->resolve("www.google.com", timeout => 1);
if (@ip) {
    warn "-> DONE $_\n" for @ip;
} else {
    warn "-> DONE ", $r->error, "\n";
}
