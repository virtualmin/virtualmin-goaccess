use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use IO::Compress::Gzip qw(gzip $GzipError);
use FindBin;
use lib "$FindBin::Bin/..";
use GoAccess::Report;

my $settings = GoAccess::Report::defaults();
is($settings->{format}, 'COMBINED', 'combined log format by default');
ok($settings->{anonymize} && $settings->{no_query}, 'privacy options on by default');
is_deeply(GoAccess::Report::validate({}), $settings, 'missing settings receive defaults');
my $filtered = GoAccess::Report::validate({binary => '/unused', output => '/unused'});
ok(!exists($filtered->{binary}) && !exists($filtered->{output}), 'only supported options are accepted');

# Invalid forms must fail before a parser or schedule is changed.
foreach my $invalid ({format => 'unknown'}, {schedule => '* * * * *'},
    {anonymize => 2}, {keep_days => -1},
    {keep_days => 3661}, {max_items => 9}, {max_items => 1001},
    {custom_format => "line\nline"}, {format => 'CUSTOM'}, {rotated => []}) {
    eval { GoAccess::Report::validate($invalid); };
    ok($@, 'invalid settings rejected: '.join(', ', keys %$invalid));
}
my $custom = GoAccess::Report::validate({format => 'CUSTOM', custom_format => '%h %d %t %r %s %b'});
my @cmd = GoAccess::Report::command('/usr/bin/goaccess', $custom, 'Example & site');
ok(grep($_ eq '--log-format=%h %d %t %r %s %b', @cmd), 'custom format is one argument');
ok(grep($_ eq '--html-report-title=Example &amp; site', @cmd), 'HTML title escaped');
ok(grep($_ eq '--no-global-config', @cmd), 'global parser configuration ignored');
ok(grep(/\A--html-prefs=.*"theme":"bright"/, @cmd), 'downloads default to the bright theme');

my $tmp = tempdir(CLEANUP => 1);

# write_fixture(path, text) writes a small test log in the private test directory.
sub write_fixture
{
my ($path, $text) = @_;
open(my $fh, '>', $path) or die $!;
print {$fh} $text;
close($fh) or die $!;
}

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
eval { GoAccess::Report::read_regular("$tmp/combined", 2); };
like($@, qr/Invalid report file/, 'oversized output rejected');

done_testing();
