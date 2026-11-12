#!/usr/bin/perl
# usability.pl(domain) checks optional GeoIP setup and quiet scheduled updates.
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
# Refuse ordinary domains before replacing feature state and access logs.
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

# Use a real report worker and enough website names to trigger partial hiding.
my $settings = GoAccess::Report::defaults();
$settings->{schedule} = 'manual';
$settings->{rotated} = 0;
&state_lock($d, sub { &save_settings($d, $settings); &sync_cron($d, $settings); });
my $log = &virtual_server::get_website_log($d);
&create_website_log($d, $log);
&write_file_contents($log, '192.0.2.1 - - [01/Nov/2026:00:00:00 +0000] '.
    '"GET /index.html HTTP/1.1" 200 123 "-" "Mozilla/5.0"'."\n");
my $pid = fork();
die $! unless defined($pid);
if (!$pid) {
    # Simulate many configured aliases without changing the web server.
    no warnings qw(redefine once);
    local *virtual_server::get_website_hostnames = sub { map { "alias$_.example.test" } 1..40 };
    open(STDOUT, '>', "$tmp/stdout") or die $!;
    open(STDERR, '>', "$tmp/stderr") or die $!;
    @ARGV = ('--domain', $d->{id});
    do "$root/goaccess.pl";
    _exit(255);
}
# Partial filtering is a saved warning, not a cron failure or mail trigger.
waitpid($pid, 0);
is($?, 0, 'scheduled report succeeds with many aliases');
is(-s "$tmp/stdout", 0, 'scheduled success writes no standard output');
is(-s "$tmp/stderr", 0, 'partial filtering does not send cron mail');
my $status = &report_status($d);
like($status->{warnings}->[0], qr/32 of 41/, 'the warning remains available on report pages');
is($status->{general}->{valid_requests}, 1, 'all fixture requests remain counted');
done_testing();
