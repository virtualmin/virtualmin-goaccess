#!/usr/bin/perl
# parser.pl(binary, database-directory) tests real reports on a disposable VM.
# Use MaxMind's public GeoIP2 City/Country and GeoLite2 ASN test databases.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/..";
use GoAccess::Report;
use JSON::PP;
use File::Temp qw(tempdir);

my ($binary, $databases) = @ARGV;
die "Usage: parser.pl /path/to/goaccess /path/to/test-databases\n"
    unless $binary && $databases;
my @owner = getpwnam('nobody');
my ($uid, $gid) = $< ? ($<, $( + 0) : @owner[2, 3];
my $tmp = tempdir(CLEANUP => 1);
chmod(0755, $tmp) or die $!;
my $log = "$tmp/access.log";

# entry(path, status, referrer, [ip]) creates a combined-format request.
sub entry
{
my ($path, $status, $referrer, $ip) = @_;
$ip ||= '81.2.69.142';
return "$ip - - [10/Nov/2026:12:00:00 +0000] \"GET $path HTTP/1.1\" ".
    "$status 123 \"$referrer\" \"Mozilla/5.0 Firefox/128.0\"\n";
}

# Write distinct local and external requests, plus a URL with mixed statuses.
open(my $fh, '>', $log) or die $!;
print {$fh} entry('/local', 200, 'https://example.test/'),
    entry('/alias', 200, 'https://www.example.test/page'),
    entry('/port', 200, 'http://example.test:8080/page'),
    entry('/wildcard', 200, 'https://a.sub.example.test/page'),
    entry('/external', 200, 'https://example.test.evil.test/page', '1.0.0.1'),
    entry('/external-prefix', 200, 'https://notexample.test/page'),
    entry('/missing', 404, '-'), entry('/missing.css', 404, '-'),
    entry('/mixed', 200, '-'), entry('/mixed', 404, '-');
close($fh);
chmod(0644, $log) or die $!;
my %options = (binary => $binary, settings => {rotated => 0},
    title => 'Parser tests', log => $log, uid => $uid, gid => $gid,
    timeout => 30, max_logs => 10,
    hostnames => ['example.test', 'www.example.test', '*.sub.example.test']);

# report_data(options) decodes the data embedded in the generated HTML.
sub report_data
{
my ($options) = @_;
my $result = GoAccess::Report::generate($options);
my ($json) = $result->{html} =~ /var json_data\s*=\s*(\{.*)/s;
die "Missing report data\n" unless $json;
my ($data) = JSON::PP->new->decode_prefix($json);
return $data;
}

# rows(data, panel) returns the panel's reported values.
sub rows
{
my ($data, $panel) = @_;
return [map { $_->{data} } @{$data->{$panel}->{data} || []}];
}

my $hidden = report_data(\%options);
is($hidden->{general}->{valid_requests}, 10, 'hiding local referrers preserves requests');
is_deeply([sort @{rows($hidden, 'referring_sites')}],
    ['example.test.evil.test', 'notexample.test'], 'only external referring sites remain');
is_deeply([sort @{rows($hidden, 'referrers')}],
    ['-', 'https://example.test.evil.test/page', 'https://notexample.test/page'],
    'local URLs and ports are hidden without hiding similar external names');
$options{settings}->{hide_local_referrers} = 0;
my $shown = report_data(\%options);
is(scalar(@{rows($shown, 'referring_sites')}), 6, 'disabled filter restores local referrers');
foreach my $metric (qw(valid_requests unique_visitors bandwidth)) {
    is($hidden->{general}->{$metric}, $shown->{general}->{$metric},
        "$metric unchanged by hiding local referrers");
}

# Exceeding the filter limit keeps all traffic and reports incomplete coverage.
{
    local $options{settings} = {rotated => 0};
    local $options{hostnames} = ['example.test', map { "alias$_.test" } 1..39];
    my $partial = GoAccess::Report::generate(\%options);
    is($partial->{general}->{valid_requests}, 10, 'many aliases still produce a complete report');
    like($partial->{warnings}->[0], qr/32 of 40/, 'successful report carries the filter warning');
}
my $complete = GoAccess::Report::generate(\%options);
is_deeply($complete->{warnings}, [], 'disabled filtering does not carry a stale warning');

# Setup checks use the actual parser without waiting for a scheduled report.
eval { GoAccess::Report::check_geoip($binary,
    ["$databases/GeoIP2-City-Test.mmdb", "$databases/GeoLite2-ASN-Test.mmdb"], $uid, $gid); };
is($@, '', 'valid City and ASN databases pass the setup check');
eval { GoAccess::Report::check_geoip($binary,
    ["$databases/GeoIP2-Country-Test.mmdb"], $uid, $gid); };
is($@, '', 'valid Country database passes the setup check');
open($fh, '>', "$tmp/broken.mmdb") or die $!;
print {$fh} 'not a MaxMind database';
close($fh);
chmod(0644, "$tmp/broken.mmdb");
eval { GoAccess::Report::check_geoip($binary, ["$tmp/broken.mmdb"], $uid, $gid); };
like($@, qr/GeoIP setup check failed:.*Unable to open GeoIP2 database/s,
    'corrupt database rejected during setup');
eval { GoAccess::Report::check_geoip($binary, ["$tmp/missing.mmdb"], $uid, $gid); };
like($@, qr/not a readable file/, 'missing database rejected during setup');

# Simulate a build without MMDB support without changing the installed parser.
open($fh, '>', "$tmp/no-geoip") or die $!;
print {$fh} "#!/bin/sh\necho 'GoAccess - 1.9.3. --enable-utf8'\n";
close($fh);
chmod(0755, "$tmp/no-geoip");
eval { GoAccess::Report::check_geoip("$tmp/no-geoip",
    ["$databases/GeoIP2-City-Test.mmdb"], $uid, $gid); };
like($@, qr/GoAccess must be built with GeoIP2 support/, 'unsupported build has a clear setup error');
open($fh, '>', "$tmp/no-geoip") or die $!;
print {$fh} "#!/bin/sh\necho 'GoAccess - 1.6. --enable-geoip=mmdb'\n";
close($fh);
eval { GoAccess::Report::check_geoip("$tmp/no-geoip",
    ["$databases/GeoIP2-City-Test.mmdb"], $uid, $gid); };
like($@, qr/requires GoAccess 1.7 or later/, 'older GeoIP build has a clear setup error');
# Build checks stay inside the report worker's time limit too.
open($fh, '>', "$tmp/no-geoip") or die $!;
print {$fh} "#!/bin/sh\nsleep 20\n";
close($fh);
eval { GoAccess::Report::generate({%options, binary => "$tmp/no-geoip", timeout => 1,
    geoip_databases => ["$databases/GeoIP2-City-Test.mmdb"]}); };
like($@, qr/timed out after 1 seconds/, 'a stalled GeoIP build check respects the report time limit');

# Country totals use the real IP even when host rows are anonymized.
$options{geoip_databases} = ["$databases/GeoIP2-City-Test.mmdb",
                            "$databases/GeoLite2-ASN-Test.mmdb"];
my $geo = report_data(\%options);
like(encode_json($geo->{geolocation}), qr/United Kingdom/, 'City database supplies country data');
like(encode_json($geo->{asn}), qr/Google/, 'ASN database supplies network details');
ok(grep($_ eq '81.2.69.0', @{rows($geo, 'hosts')}), 'GeoIP preserves IP anonymization');
# Per-host city lookup uses the displayed IP, which anonymization can change.
$options{settings}->{anonymize} = 0;
$geo = report_data(\%options);
like(encode_json($geo->{hosts}), qr/London/, 'City database supplies city details for original IPs');
$options{geoip_databases} = ["$databases/GeoIP2-Country-Test.mmdb"];
$geo = report_data(\%options);
like(encode_json($geo->{geolocation}), qr/United Kingdom/, 'Country database works on its own');
# GoAccess keeps an all-unknown network panel unless told to omit it.
ok(exists($geo->{asn}), 'GoAccess shows the network panel without an ASN database');
$options{ignore_panels} = ['ASN'];
$geo = report_data(\%options);
ok(exists($geo->{geolocation}) && !exists($geo->{asn}), 'panel without a database can be omitted');
delete($options{ignore_panels});
$options{geoip_databases} = ["$tmp/missing.mmdb"];
eval { GoAccess::Report::generate(\%options); };
like($@, qr/GeoIP database is not a readable file/, 'missing database has an actionable error');
open($fh, '>', "$tmp/private.mmdb") or die $!;
print {$fh} 'not readable';
close($fh);
chmod(0000, "$tmp/private.mmdb");
$options{geoip_databases} = ["$tmp/private.mmdb"];
eval { GoAccess::Report::generate(\%options); };
like($@, qr/GeoIP database is not a readable file/, 'database permissions checked as the domain owner');
eval { GoAccess::Report::check_geoip($binary, ["$tmp/private.mmdb"], $uid, $gid); };
like($@, qr/not a readable file/, 'setup checks use the same database permissions as reports');
chmod(0600, "$tmp/private.mmdb");
done_testing();
