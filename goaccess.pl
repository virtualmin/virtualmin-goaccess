#!/usr/bin/perl
# Refresh one domain or all enabled domains from a Webmin cron wrapper.
use strict;
use warnings;
our $no_acl_check = 1;
our $module_name;
die "This program is for root command-line use only\n"
    if $< != 0 || $ENV{'REQUEST_METHOD'} || $ENV{'GATEWAY_INTERFACE'};
require './virtualmin-goaccess-lib.pl';

my ($mode, $id) = @ARGV;
die "Usage: goaccess.pl --domain ID | --all\n" unless
    (@ARGV == 1 && $mode eq '--all') ||
    (@ARGV == 2 && $mode eq '--domain' && $id =~ /\A\d+\z/);
my @domains;
if ($mode eq '--all') {
    # Batch refreshes skip disabled domains but include manual schedules.
    @domains = grep { $_->{$module_name} && !$_->{'disabled'} }
        &virtual_server::list_domains();
}
else {
    # A single requested domain must still have the feature enabled.
    my $d = &virtual_server::get_domain($id);
    die "GoAccess is not enabled for domain $id\n" unless $d && $d->{$module_name};
    @domains = ($d);
}

# Report failures to cron and continue updating other domains in a batch.
my $failed = 0;
foreach my $d (@domains) {
    next if $d->{'disabled'} || -f (&domain_dir($d).'/paused');
    eval { &generate_report($d); };
    if ($@) {
        print STDERR "$d->{'dom'}: $@";
        $failed = 1;
    }
}
exit($failed);
