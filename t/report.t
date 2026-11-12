use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use IO::Compress::Gzip qw(gzip $GzipError);
use FindBin;
use lib "$FindBin::Bin/..";
use GoAccess::Report;

# The cron entry point must reject web execution before loading Webmin or data.
{
    local $ENV{REQUEST_METHOD} = 'GET';
    my $output;
    {
        open(my $fh, '-|', $^X, '-e', 'open STDERR, ">&STDOUT"; do $ARGV[0]; die $@ if $@;',
             "$FindBin::Bin/../goaccess.pl") or die $!;
        local $/;
        $output = <$fh>;
        close($fh);
    }
    like($output, qr/root command-line use only/, 'cron entry point rejects HTTP context');
}

# Defaults and validation must exclude caller-supplied executable paths.
my $settings = GoAccess::Report::defaults();
is($settings->{format}, 'COMBINED', 'combined log format by default');
ok($settings->{anonymize} && $settings->{no_query}, 'privacy options on by default');
is_deeply(GoAccess::Report::validate({}), $settings, 'missing settings receive defaults');
my $filtered = GoAccess::Report::validate({binary => '/unused', output => '/unused'});
ok(!exists($filtered->{binary}) && !exists($filtered->{output}), 'only supported options are accepted');

# Invalid forms must fail before a parser or schedule is changed.
foreach my $invalid ({format => 'unknown'}, {schedule => '* * * * *'},
    {anonymize => 2}, {hide_local_referrers => 2}, {keep_days => -1},
    {keep_days => 3661}, {max_items => 9}, {max_items => 1001},
    {custom_format => "line\nline"}, {format => 'CUSTOM'}, {rotated => []}) {
    eval { GoAccess::Report::validate($invalid); };
    ok($@, 'invalid settings rejected: '.join(', ', keys %$invalid));
}
# Custom formats remain one argument, and titles are safe to embed in HTML.
my $custom = GoAccess::Report::validate({format => 'CUSTOM', custom_format => '%h %d %t %r %s %b'});
my @cmd = GoAccess::Report::command('/usr/bin/goaccess', $custom, 'Example & site');
ok(grep($_ eq '--log-format=%h %d %t %r %s %b', @cmd), 'custom format is one argument');
ok(grep($_ eq '--html-report-title=Example &amp; site', @cmd), 'HTML title escaped');
ok(grep($_ eq '--no-global-config', @cmd), 'global parser configuration ignored');
ok(grep(/\A--html-prefs=.*"theme":"bright"/, @cmd), 'downloads default to the bright theme');

# Database paths stay separate from owner settings and shell interpretation.
@cmd = GoAccess::Report::command('/usr/bin/goaccess', $settings, 'Example',
    ['/srv/GeoIP data/City.mmdb', '/srv/ASN.mmdb'],
    ['Example.test', 'example.test', 'www.example.test', '*.sub.example.test', '~.*', '_']);
ok(grep($_ eq '--geoip-database=/srv/GeoIP data/City.mmdb', @cmd),
    'database paths with spaces remain single arguments');
is(scalar(grep(/^--geoip-database=/, @cmd)), 2, 'City and ASN databases passed together');
# Local filters cover names and ports without discarding requests.
ok(grep($_ eq '--hide-referrer=example.test', @cmd), 'local hostname hidden');
ok(grep($_ eq '--hide-referrer=example.test:*', @cmd), 'explicit referrer ports hidden');
is(scalar(grep($_ eq '--hide-referrer=example.test', @cmd)), 1, 'duplicate hostnames omitted');
ok(grep($_ eq '--hide-referrer=*.sub.example.test', @cmd), 'wildcard website alias retained');
ok(!grep(/^--ignore-(?:referrer|status)=/, @cmd), 'traffic and errors are not discarded');
my $owner = GoAccess::Report::validate({geoip_databases => ['/private/db'], hostnames => ['*']});
ok(!exists($owner->{geoip_databases}) && !exists($owner->{hostnames}),
    'owners cannot override database paths or website hostnames');
@cmd = GoAccess::Report::command('/usr/bin/goaccess',
    GoAccess::Report::validate({hide_local_referrers => 0}), 'Example', [], ['example.test']);
ok(!grep(/^--hide-referrer=/, @cmd), 'local referrers can be shown again');
# Reject malformed database paths and unrelated panel names.
foreach my $path ('relative.mmdb', "/db\n--option", "/db\x00", []) {
    eval { GoAccess::Report::command('/usr/bin/goaccess', $settings, 'Example', [$path]); };
    like($@, qr/GeoIP database paths/, 'invalid database path rejected');
}
@cmd = GoAccess::Report::command('/usr/bin/goaccess', $settings, 'Example',
    ['/srv/City.mmdb'], [], ['ASN']);
ok(grep($_ eq '--ignore-panel=ASN', @cmd), 'panel without a database omitted');
eval { GoAccess::Report::command('/usr/bin/goaccess', $settings, 'Example', [], [], ['VISITORS']); };
like($@, qr/Invalid GeoIP panel/, 'only GeoIP panels can be omitted');
# Each hostname needs two filters within GoAccess's 64-filter limit.
my @warnings;
my $filters = GoAccess::Report::local_referrers(
    [map { "host$_.test" } 1..32], \@warnings);
is(scalar(@$filters), 64, 'all names and ports fit at the filter limit');
is_deeply(\@warnings, [], 'no warning when every name is covered');
@cmd = GoAccess::Report::command('/usr/bin/goaccess', $settings, 'Example',
    [], [map { "host$_.test" } 1..40], [], \@warnings);
is(scalar(grep(/^--hide-referrer=/, @cmd)), 64, 'excess names do not stop command generation');
like($warnings[0], qr/32 of 40/, 'partial filter coverage is reported');
is($cmd[-1], '--hide-referrer=host32.test:*', 'truncation keeps hostname and port together');

my $tmp = tempdir(CLEANUP => 1);

# write_fixture(path, text) writes a test log in the temporary directory.
sub write_fixture
{
my ($path, $text) = @_;
open(my $fh, '>', $path) or die $!;
print {$fh} $text;
close($fh) or die $!;
}

# Mix supported rotations with similarly named files that must be excluded.
write_fixture("$tmp/access.log", "current\n");
write_fixture("$tmp/access.log.1", 'previous');
gzip(\"compressed\n", "$tmp/access.log.2.gz") or die $GzipError;
write_fixture("$tmp/access.log-20260901", "dated\n");
write_fixture("$tmp/access.log.backup", "unrelated\n");
write_fixture("$tmp/access.log_other.1", "unrelated\n");
my $logs = GoAccess::Report::log_files("$tmp/access.log", 1, 10);
is(scalar(@$logs), 4, 'only recognized rotations included');
is_deeply(GoAccess::Report::log_files("$tmp/access.log", 0, 10), ["$tmp/access.log"], 'rotations can be disabled');
eval { GoAccess::Report::log_files("$tmp/access.log", 1, 2); };
like($@, qr/Too many/, 'log limit enforced without silently truncating the report');
# Combining logs must decompress archives and separate incomplete final lines.
my $info = GoAccess::Report::collect_logs($logs, "$tmp/combined");
is($info->{files}, 4, 'all recognized files read');
my $joined = GoAccess::Report::read_regular("$tmp/combined", 4096);
like($joined, qr/previous\n/, 'unterminated lines separated between files');
like($joined, qr/compressed\n/, 'gzip contents decoded');
unlike($joined, qr/unrelated/, 'unrelated files excluded');

# Shared inodes are included once, and malformed archives abort an update.
link("$tmp/access.log", "$tmp/access.log.3") or die $!;
$info = GoAccess::Report::collect_logs(["$tmp/access.log", "$tmp/access.log.3"], "$tmp/dedup");
is($info->{files}, 1, 'hard-linked logs counted once');
write_fixture("$tmp/broken.gz", 'not a gzip stream');
eval { GoAccess::Report::collect_logs(["$tmp/broken.gz"], "$tmp/failed"); };
like($@, qr/decompress/, 'broken archive reported');
# Output size limits apply before accepting parser results.
eval { GoAccess::Report::read_regular("$tmp/combined", 2); };
like($@, qr/Invalid report file/, 'oversized output rejected');

done_testing();
