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

# during_update(code, label) holds the report lock in a child during a callback.
# A completion marker proves the callback waited instead of failing on overlap.
sub during_update
{
my ($code, $label) = @_;
pipe(my $ready, my $notify) or die $!;
my $finished = "$dir/lock-test-finished";
my $pid = fork();
die $! unless defined($pid);
if (!$pid) {
    # Use _exit so the child cannot run Webmin's inherited cleanup handlers.
    close($ready);
    my $ok = eval {
        &domain_lock($d, sub {
            syswrite($notify, "1", 1) == 1 or die $!;
            close($notify);
            sleep(1);
            &write_file_contents($finished, "1\n");
        });
        1;
    };
    _exit($ok ? 0 : 1);
}
close($notify);
read($ready, my $signal, 1) == 1 or die "Lock fixture failed\n";
close($ready);
my $result = eval { $code->() };
my $err = $@;
ok(-f $finished, "$label waits for the current update");
waitpid($pid, 0);
is($?, 0, "$label lock fixture completed");
unlink($finished);
die $err if $err;
return $result;
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
write_log($log, entry('21', '192.0.2.10', '/first?private=value').entry('21', '198.51.100.12', '/missing', 404));
write_log("$log.1", entry('20', '203.0.113.15', '/previous'));
my $archived = entry('19', '192.0.2.30', '/archive');
gzip(\$archived, "$log.2.gz") or die $GzipError;
chown($owner[2], $owner[3], "$log.2.gz");
chmod(0640, "$log.2.gz");
ok(&log_data($d, &load_settings($d)) > 0, 'logged requests are detected');
# Discovery failures must reach the page instead of appearing as empty logs.
{
    local $config{max_logs} = 1;
    eval { &log_data($d, &load_settings($d)); };
    like($@, qr/Too many rotated logs/, 'log-data check reports the configured file limit');
}
$status = &generate_report($d);
is($status->{general}->{valid_requests}, 4, 'current and compressed rotated requests counted');
is($status->{input}->{files}, 3, 'all three input files recorded');
my $html = GoAccess::Report::read_regular("$dir/report.html", 32*1024*1024);
like($html, qr/<!doctype html/i, 'standalone HTML generated');
like($html, qr/GoAccess/, 'GoAccess dashboard generated');
unlike($html, qr/private=value/, 'query strings removed from the dashboard');
unlike($html, qr/192\.0\.2\.10/, 'client IP address anonymized');
is((stat($dir))[2] & 0777, 0700, 'domain state is private');
$status = &generate_report($d);
is($status->{general}->{valid_requests}, 4, 'repeat generation does not double count');
$html = GoAccess::Report::read_regular("$dir/report.html", 32*1024*1024);

# Lock contention and a stalled parser leave the published snapshot untouched.
&domain_lock($d, sub {
    eval { &generate_report($d); };
    like($@, qr/being updated/, 'concurrent updates fail clearly');
});
my $slow = "$d->{home}/goaccess-slow-test";
write_log($slow, "#!/bin/sh\nexec /bin/sleep 30\n");
chmod(0750, $slow);
{
    local $config{goaccess} = $slow;
    local $config{timeout} = 1;
    eval { &generate_report($d); };
    like($@, qr/timed out/, 'stalled parser is terminated');
    is(sha256_hex(GoAccess::Report::read_regular("$dir/report.html", 32*1024*1024)), sha256_hex($html), 'timeout preserves prior HTML');
}
unlink($slow);

# A real cron wrapper must produce the same report and exit successfully.
is(system($cron_cmd, '--domain', $d->{'id'}), 0, 'cron wrapper runs with Webmin configuration');
my $s = &load_settings($d);
$s->{keep_days} = 1;
&domain_lock($d, sub { &save_settings($d, $s); });
$status = &generate_report($d);
is($status->{general}->{valid_requests}, 2, 'day filter uses the newest date in the log');
$s->{keep_days} = 0;
$s->{rotated} = 0;
&domain_lock($d, sub { &save_settings($d, $s); });
$status = &generate_report($d);
is($status->{general}->{valid_requests}, 2, 'rotated logs can be excluded');

# Failed parsing keeps the last successful HTML and records the error.
$html = GoAccess::Report::read_regular("$dir/report.html", 32*1024*1024);
write_log($log, "This is not an access log\n");
eval { &generate_report($d); };
like($@, qr/GoAccess|format|parsed/i, 'parser failure reaches the caller');
is(sha256_hex(GoAccess::Report::read_regular("$dir/report.html", 32*1024*1024)), sha256_hex($html), 'failed update preserves prior HTML');
ok(&report_status($d)->{error}, 'failed attempt recorded');
write_log($log, entry('21', '192.0.2.10', '/recovered'));
$status = &generate_report($d);
ok(!$status->{error}, 'successful retry clears prior error');

# Common and custom format configuration is exercised with the real parser.
write_log($log, "192.0.2.10 - - [21/Sep/2026:12:00:00 +0000] \"GET /common HTTP/1.1\" 200 50\n");
$s->{format} = 'COMMON';
&domain_lock($d, sub { &save_settings($d, $s); });
is(&generate_report($d)->{general}->{valid_requests}, 1, 'common log format supported');
$s->{format} = 'CUSTOM';
$s->{custom_format} = '%h %^[%d:%t %^] "%r" %s %b';
&domain_lock($d, sub { &save_settings($d, $s); });
is(&generate_report($d)->{general}->{valid_requests}, 1, 'custom log format supported');

# Virtualmin supplies domain scope; module ACLs only restrict report actions.
{
    local %access = (generate => 1, configure => 0);
    local %virtual_server::access = (domains => $d->{'id'}, noconfig => 1);
    ok(&allowed_domain($d->{'id'}), 'domain owner can read own report');
    ok(&allowed_domain($d->{'id'}, 'generate'), 'generation permission honored');
    ok(!&allowed_domain($d->{'id'}, 'configure'), 'report configuration denied without permission');
    {
        local $access{generate} = 0;
        ok(!&allowed_domain($d->{'id'}, 'generate'), 'report generation denied without permission');
        ok(&allowed_domain($d->{'id'}), 'generation restriction retains report viewing');
    }
    {
        local $access{configure} = 1;
        local $access{noconfig} = 1;
        local $config{noedit} = 1;
        ok(!&allowed_domain($d->{'id'}, 'configure'), 'administrator owner restriction applies immediately');
        ok(&allowed_domain($d->{'id'}), 'owner restriction retains report viewing');
    }
    local $virtual_server::access{domains} = '';
    ok(!&allowed_domain($d->{'id'}), 'Virtualmin domain restriction enforced');
    ok(!&allowed_domain($d->{'id'}, 'generate'), 'action permission cannot bypass Virtualmin domain scope');
}

# Owner ACLs inherit domain scope and retain separate action permissions.
{
    local $config{noedit} = 0;
    my ($grant) = &feature_webmin($d, [$d]);
    is_deeply($grant, [$module_name, {noconfig => 1, configure => 1, generate => 1}],
              'owner ACL grants report actions without duplicating domain scope');
    ok(!&feature_webmin($d, []), 'no module access without a reporting domain');
    require './acl_security.pl';
    my %acl = (noconfig => 1, configure => 0, generate => 1);
    &acl_security_save(\%acl, {configure => 1, generate => 0});
    is_deeply(\%acl, {noconfig => 1, configure => 1, generate => 0},
              'ACL editor saves action permissions and retains the owner restriction');
}

# Schedule changes and suspension must never leave duplicate jobs behind.
$s->{schedule} = 'daily';
&state_lock($d, sub { &save_settings($d, $s); &sync_cron($d, $s); });
&state_lock($d, sub { &sync_cron($d, $s); });
my @jobs = &find_cron_jobs($d);
is(scalar(@jobs), 1, 'schedule updates are idempotent');
is($jobs[0]->{hours}, $d->{'id'} % 24, 'daily job uses one stable hour');
ok(during_update(sub { &feature_disable($d) }, 'Suspension'), 'domain suspension handled');
is(scalar(&find_cron_jobs($d)), 0, 'suspended domain has no cron job');
eval { &generate_report($d); };
like($@, qr/paused/i, 'suspended reports cannot be generated');
ok(&feature_enable($d), 'domain re-enabled');
is(scalar(&find_cron_jobs($d)), 1, 'saved schedule restored');

# Portable backups include the rendered HTML as well as validated settings.
my $backup = "$d->{home}/goaccess-test-backup.json";
ok(during_update(sub { &feature_backup($d, $backup, {}, {}) }, 'Backup'), 'Virtualmin backup hook succeeds');
# A delayed write failure must reach Virtualmin after the writer is reaped.
{
    no warnings 'redefine';
    my $close = \&virtual_server::close_tempfile_as_domain_user;
    local *virtual_server::close_tempfile_as_domain_user = sub {
        $close->(@_);
        return 0;
    };
    ok(!&feature_backup($d, $backup, {}, {}), 'backup reports a failed final write');
}
my $before = GoAccess::Report::read_regular("$dir/report.html", 32*1024*1024);
$s->{max_items} = 50;
$s->{schedule} = 'manual';
&state_lock($d, sub { &save_settings($d, $s); &sync_cron($d, $s); });
is(scalar(&find_cron_jobs($d)), 0, 'manual schedule removes cron');
unlink("$dir/report.html");
ok(&feature_restore($d, $backup, {}, {}), 'Virtualmin restore hook succeeds');
is(&load_settings($d)->{max_items}, 100, 'backed-up settings restored');
is(sha256_hex(GoAccess::Report::read_regular("$dir/report.html", 32*1024*1024)), sha256_hex($before), 'HTML snapshot restored');
unlink($backup);

done_testing();
