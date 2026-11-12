#!/usr/bin/perl
# config.pl(webmin-root, [--live]) tests OS config selection and upgrades. The
# optional live check runs GoAccess as nobody on a disposable Linux VM.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/..";
use GoAccess::Report;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP;

my ($webmin, $live) = @ARGV;
die "Usage: config.pl /path/to/webmin [--live]\n"
	unless $webmin && -f "$webmin/copyconfig.pl" &&
	(!defined($live) || $live eq '--live');
# Copy only module defaults into a temporary installer source tree.
my $tmp = tempdir(CLEANUP => 1);
my $module = 'virtualmin-goaccess';
make_path("$tmp/source/$module");
foreach my $file (glob("$FindBin::Bin/../config"),
		  glob("$FindBin::Bin/../config-*")) {
	# Exercise the shipped files without touching an installed module.
	my ($name) = $file =~ m{/([^/]+)$};
	copy($file, "$tmp/source/$module/$name") or die $!;
	}

# read_config(path) loads Webmin's key=value format for assertions.
sub read_config
{
my ($path) = @_;
open(my $fh, '<', $path) or die "Cannot read $path: $!\n";
my %config;
while (<$fh>) {
	$config{$1} = $2 if /^([^#=]+)=(.*)$/;
	}
close($fh);
return \%config;
}

# install_config(os, version, destination) invokes Webmin's actual installer.
sub install_config
{
my ($os, $version, $destination) = @_;
make_path($destination);
open(my $fh, '-|', $^X, "$webmin/copyconfig.pl", $os, $version,
     "$tmp/source", $destination, $module) or die $!;
my $output = do { local $/; <$fh> };
close($fh) or die "Webmin config installation failed: $output\n";
return read_config("$destination/$module/config");
}

# Real OS ranges must win over Webmin's shared internal Linux OS codes.
my $country = '/usr/share/GeoIP/GeoLite2-Country.mmdb';
my $defaults = read_config("$FindBin::Bin/../config");
my $case_number = 0;
my @cases = (
	[ 'redhat-linux/AlmaLinux', '16.10/8.10', $country ],
	[ 'redhat-linux/AlmaLinux', '17.7/9.7', $country ],
	[ 'redhat-linux/AlmaLinux', '18.2/10.2', $country ],
	[ 'redhat-linux/Rocky Linux', '16.10/8.10', $country ],
	[ 'redhat-linux/Rocky Linux', '17.7/9.7', $country ],
	[ 'redhat-linux/Rocky Linux', '18.2/10.2', $country ],
	[ 'debian-linux/Debian Linux', '12/12', '' ],
	[ 'debian-linux/Debian Linux', '13/13', '' ],
	[ 'debian-linux/Ubuntu Linux', '14.0/24.04', '' ],
	[ 'debian-linux/Ubuntu Linux', '15.0/26.04.1', '' ],
	[ 'debian-linux', '15.0', '' ],
	[ 'freebsd', '14.3', '', '/usr/local/bin/goaccess' ],
);
foreach my $case (@cases) {
	my ($os, $version, $database, $binary) = @$case;
	my $config = install_config($os, $version, "$tmp/case-".++$case_number);
	my %expected = (
		%$defaults, geoip_country => $database,
		goaccess => $binary || '/usr/bin/goaccess' );
	is_deeply($config, \%expected,
		  "$os $version selects the complete config");
	}

# Existing choices, including an intentionally blank path, survive an upgrade.
make_path("$tmp/upgrade/$module");
open(my $saved, '>', "$tmp/upgrade/$module/config") or die $!;
print {$saved} "goaccess=/opt/goaccess\ngeoip_country=\ntimeout=600\n";
close($saved) or die $!;
my $upgraded = install_config(
	'redhat-linux/AlmaLinux', '18.2/10.2', "$tmp/upgrade");
is($upgraded->{goaccess}, '/opt/goaccess', 'upgrade preserves a custom binary');
is($upgraded->{geoip_country}, '', 'upgrade preserves disabled GeoIP');
is($upgraded->{timeout}, 600, 'upgrade preserves a custom timeout');
is($upgraded->{geoip_asn}, '', 'upgrade adds missing settings');

if ($live) {
	# Only the explicit VM mode reads host config and executes the parser.
	die "Live checks require root on a disposable VM\n" if $<;
	my $host = read_config('/etc/webmin/config');
	my $config = install_config(
		"$host->{os_type}/$host->{real_os_type}",
		"$host->{os_version}/$host->{real_os_version}", "$tmp/live");
	ok(-x $config->{goaccess}, 'selected GoAccess executable is installed');
	my @owner = getpwnam('nobody');
	die "Missing nobody account\n" unless @owner;
	# Make the temporary request readable by the unprivileged parser.
	chmod(0755, $tmp) or die $!;
	open(my $log, '>', "$tmp/access.log") or die $!;
	print {$log} '81.2.69.142 - - [12/Nov/2026:12:00:00 +0000] '.
		'"GET / HTTP/1.1" 200 123 "-" "Mozilla/5.0"'."\n";
	close($log) or die $!;
	chmod(0644, "$tmp/access.log") or die $!;
	# Validate and use the databases selected by the installed OS defaults.
	my @databases = grep { length($_) }
		( $config->{geoip_city} || $config->{geoip_country},
		  $config->{geoip_asn} );
	eval {
		GoAccess::Report::check_geoip(
			$config->{goaccess}, \@databases, @owner[2, 3]);
		};
	is($@, '', 'configured GeoIP database passes validation as nobody');
	my $result = GoAccess::Report::generate({
		binary => $config->{goaccess},
		settings => { rotated => 0 },
		title => 'Distribution defaults',
		log => "$tmp/access.log", uid => $owner[2],
		gid => $owner[3],
		timeout => 30, max_logs => 1,
		geoip_databases => \@databases,
		ignore_panels => @databases ? [ 'ASN' ] : [ ] });
	is($result->{general}->{valid_requests}, 1,
	   'default config generates a report');
	# Check embedded report data rather than the rendered labels alone.
	my ($json) = $result->{html} =~ /var json_data\s*=\s*(\{.*)/s;
	die "Missing report data\n" unless $json;
	my ($data) = JSON::PP->new->decode_prefix($json);
	if (@databases) {
		# The packaged Country database must provide
		# actual location data.
		like(encode_json($data->{geolocation}), qr/United Kingdom/,
		     'packaged Country database resolves the test address');
		}
	else {
		# A missing optional database must not block basic reporting.
		ok(!exists($data->{geolocation}),
		   'GeoIP stays disabled without a database');
		}
	}
done_testing();
