#!/usr/bin/perl
# integration.pl(domain) exercises an existing disposable ga-test-* domain.
use strict;
use warnings;
use Test::More;
use FindBin;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use IO::Compress::Gzip qw(gzip $GzipError);
use POSIX qw(_exit);

die "Run this test from the root command line\n"
    if $< != 0 || $ENV{'REQUEST_METHOD'} || $ENV{'GATEWAY_INTERFACE'};
my $root = abs_path("$FindBin::Bin/..");
chdir($root) or die $!;
$0 = "$root/integration.pl";
our $no_acl_check = 1;
our (%access, %config, $module_name, $cron_cmd);
require './virtualmin-goaccess-lib.pl';
require './virtual_feature.pl';
&virtual_server::set_all_null_print();
my $name = shift(@ARGV) || '';
die "A disposable fixture domain is required\n" unless $name =~ /\Aga-test-[a-f0-9]+\.example\.test\z/;
my $d = &virtual_server::get_domain_by('dom', $name);
die "Fixture does not exist\n" unless $d && $d->{$module_name};
my $dir = &domain_dir($d);
my $log = &virtual_server::get_website_log($d);
my @owner = getpwnam($d->{'user'});
ok($owner[2] > 0, 'parser has an unprivileged domain owner');
ok(-f "$dir/settings.json", 'Virtualmin created the feature settings');
is(&feature_validate($d), undef, 'new feature passes validation');
is(scalar(&find_cron_jobs($d)), 1, 'one hourly cron job created');

# write_log(path, lines) writes only logs belonging to this disposable fixture.
sub write_log
{
my ($path, $lines) = @_;
open(my $fh, '>', $path) or die $!;
print {$fh} $lines;
close($fh) or die $!;
chown($owner[2], $owner[3], $path) == 1 or die $!;
chmod(0640, $path) or die $!;
}

# entry(day, address, path, [status]) returns a deterministic combined-log line.
sub entry
{
my ($day, $ip, $path, $status) = @_;
return "$ip - - [$day/Sep/2026:12:00:00 +0000] \"GET $path HTTP/1.1\" ".
    ($status || 200)." 123 \"-\" \"Mozilla/5.0 (X11; Linux x86_64) Firefox/128.0\"\n";
}

# A dangling log symlink must remain untouched. A missing log must be created
# with Virtualmin's ownership and permissions. Remove old fixture rotations
# so they do not affect request counts.
unlink($log, "$log.1", "$log.2.gz");
is(&log_data($d, &load_settings($d)), 0, 'a missing current log is treated as an empty new site');
symlink("$log.missing-target", $log) or die $!;
eval { &log_data($d, &load_settings($d)); };
like($@, qr/Cannot inspect access log/, 'log-data check reports a broken log symlink');
eval { &generate_report($d); };
like($@, qr/Cannot open access log/, 'a broken link at the log path is reported');
ok(-l $log && !-e "$log.missing-target", 'the symlink remains and its target is not created');
unlink($log) or die $!;
my $status = &generate_report($d);
ok(-f $log && !-l $log, 'missing access log created before the first report');
my @st = stat($log);
is($st[4], $owner[2], 'created log belongs to the domain owner');
is($st[2] & 07777, 0660, 'created log is shared with the web server');
if (&virtual_server::domain_has_website($d) eq 'web') {
    my @web = getpwnam(&virtual_server::get_apache_user($d));
    is($st[5], $web[3], 'created log uses the web server group');
}
is($status->{general}->{valid_requests}, 0, 'empty website gets a valid report');
like(GoAccess::Report::read_regular("$dir/report.html", 1024*1024), qr/No traffic yet/, 'empty report explains its state');
is(&log_data($d, &load_settings($d)), 0, 'empty logs offer nothing to report');
done_testing();
