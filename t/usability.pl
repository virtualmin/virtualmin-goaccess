#!/usr/bin/perl
# Run only against a disposable ga-test-* domain on a test VM.
use strict;
use warnings;
use Test::More;
use FindBin;
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use POSIX qw(_exit);

die "Run this test from the root command line\n"
    if $< != 0 || $ENV{'REQUEST_METHOD'} || $ENV{'GATEWAY_INTERFACE'};
my $root = abs_path("$FindBin::Bin/..");
chdir($root) or die $!;
$0 = "$root/usability.pl";
our $no_acl_check = 1;
our %config;
require './virtualmin-goaccess-lib.pl';
require './virtual_feature.pl';
&virtual_server::set_all_null_print();
my $name = shift(@ARGV) || '';
die "A disposable fixture domain is required\n"
    unless $name =~ /\Aga-test-[a-f0-9]+\.example\.test\z/;
my $d = &virtual_server::get_domain_by('dom', $name) or die "Fixture not found\n";
my $dir = &domain_dir($d);
my $tmp = tempdir(CLEANUP => 1);

# Enabling reporting must finish even when optional GeoIP needs repair.
&feature_delete($d);
{
    local $config{geoip_city} = "$tmp/missing.mmdb";
    is(&feature_check(), undef, 'GeoIP does not fail the global feature check');
    ok(&feature_setup($d), 'feature setup tolerates a missing GeoIP database');
    ok(-f "$dir/settings.json", 'feature settings are created');
    is(scalar(&find_cron_jobs($d)), 1, 'feature schedule is created');
    like(&feature_validate($d), qr/not a readable file/,
        'explicit validation still reports the database problem');
}

done_testing();
