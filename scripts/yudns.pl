#!/usr/bin/perl

use strict;
use warnings;
use Net::DNS;
use Getopt::Long;

########################
# Configuration
########################

my $SERVICE    = "youtubeUnblock";
my $CACHE_FILE = "/var/spool/youtubeUnblock-dns.cache";

my $dns_server = "127.0.0.1";
my $since      = "1 hour ago";

GetOptions(
    "dns=s"   => \$dns_server,
    "since=s" => \$since,
) or die <<"EOF";
Usage:
  $0 [--dns DNS_SERVER] [--since TIME]

Examples:
  $0
  $0 --dns 8.8.8.8
  $0 --since "2 hours ago"
  $0 --dns 9.9.9.9 --since "30 minutes ago"
EOF

########################
# Load cache
########################

my %cache;

if (-f $CACHE_FILE) {
    open(my $cf, "<", $CACHE_FILE)
        or die "Cannot open $CACHE_FILE: $!";

    while (<$cf>) {
        chomp;
        next unless $_;
        $cache{$_} = 1;
    }

    close($cf);
}

open(my $cachefh, ">>", $CACHE_FILE)
    or die "Cannot open $CACHE_FILE for append: $!";

########################
# DNS resolver
########################

my $resolver = Net::DNS::Resolver->new(
    nameservers => [$dns_server],
    recurse     => 1,
    udp_timeout => 3,
    tcp_timeout => 3,
);

########################
# Journal
########################

open(my $journal,
    "-|",
    "journalctl",
    "-u", $SERVICE,
    "--since", $since
) or die "Cannot execute journalctl: $!";

########################
# Process
########################

while (<$journal>) {

    next unless /Target SNI detected/;

    chomp;

    my @fields = split;
    my $host = $fields[-1];

    next unless $host;
    next if exists $cache{$host};

    $cache{$host} = 1;

    print $cachefh "$host\n";

    my @ips;

    my $query = $resolver->search($host, "A");

    if ($query) {
        foreach my $rr ($query->answer) {
            next unless $rr->type eq "A";
            push @ips, $rr->address;
        }
    }

    if (@ips) {
        print "$host -> ", join(", ", @ips), "\n";
    }
    else {
        print "$host -> NOT FOUND\n";
    }
}

close($journal);
close($cachefh);

exit 0;
