package GoAccess::Report;

use strict;
use warnings;
use Fcntl qw(:DEFAULT :mode);
use File::Basename qw(dirname basename);
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);
use IO::Uncompress::Gunzip qw($GunzipError);
use JSON::PP;
use POSIX qw(:sys_wait_h setpgid _exit);
use Time::HiRes qw(time sleep);

# defaults() returns the settings used for a new domain.
sub defaults
{
return { format => 'COMBINED', custom_format => '', date_format => '%d/%b/%Y',
	 time_format => '%T', schedule => 'hourly', keep_days => 0,
	 anonymize => 1, no_query => 1, ignore_crawlers => 0,
	 rotated => 1, max_items => 100, hide_local_referrers => 1 };
}

# validate(settings) returns supported settings with defaults, or dies.
sub validate
{
my ($input) = @_;
die "Invalid report settings\n" unless ref($input) eq 'HASH';
my $s = defaults();
# Copy supported scalar settings and keep defaults for missing fields.
foreach my $k (keys %$s) {
	next unless exists $input->{$k};
	die "Invalid value for $k\n" if !defined($input->{$k}) ||
		ref($input->{$k});
	$s->{$k} = $input->{$k};
	}

# Fixed choices keep command options and cron expressions under module control.
die "Invalid log format\n"
	unless $s->{format} =~ /\A(?:COMBINED|COMMON|VCOMBINED|CUSTOM)\z/;
die "Invalid schedule\n" unless $s->{schedule} =~ /\A(?:hourly|daily|manual)\z/;
foreach my $k (
	qw(anonymize no_query ignore_crawlers rotated hide_local_referrers)) {
	die "Invalid value for $k\n" unless $s->{$k} =~ /\A[01]\z/;
	}
die "Days to include must be between 0 and 3660\n"
	unless $s->{keep_days} =~ /\A\d{1,4}\z/ && $s->{keep_days} <= 3660;
die "Entries per panel must be between 10 and 1000\n"
	unless $s->{max_items} =~ /\A\d{2,4}\z/ && $s->{max_items} >= 10 &&
	$s->{max_items} <= 1000;

# Custom formats are arguments, never shell text or lines in a config file.
foreach my $k (qw(custom_format date_format time_format)) {
	die "Invalid $k\n" if length($s->{$k}) > 1024 ||
		$s->{$k} =~ /[\x00-\x1f\x7f]/;
	}
if ($s->{format} eq 'CUSTOM') {
	# Presets supply their own date and time formats; custom
	# formats need both.
	foreach my $k (qw(custom_format date_format time_format)) {
		die "Missing $k\n" unless length($s->{$k});
		}
	}
return $s;
}

# log_files(path, rotated, limit) finds standard numbered or dated rotations.
# The parent lists files because the domain owner may have permission to open
# known log paths but not list the directory. Only the worker reads the logs.
sub log_files
{
my ($path, $rotated, $limit) = @_;
die "The website has no usable access log\n"
	unless defined($path) && $path =~ m{\A/} && $path !~ /[\x00-\x1f]/;
my @files = ( $path );
if ($rotated) {
	# Match only rotations belonging to this website's current access log.
	my $dir = dirname($path);
	my $base = basename($path);
	opendir(my $dh, $dir) or die "Cannot read log directory $dir: $!\n";
	push @files, map { "$dir/$_" } grep {
		/\A\Q$base\E(?:\.\d+|-\d{8}(?:\d{6})?)(?:\.gz)?\z/
		} readdir($dh);
	closedir($dh);
	}
die "Too many rotated logs (limit $limit)\n" if @files > $limit;
return \@files;
}

# collect_logs(paths, output) copies regular logs, including gzip files, once.
# Opening as the domain owner permits normal log symlinks without root access.
sub collect_logs
{
my ($paths, $output) = @_;
open(my $out, '>', $output) or die "Cannot create log snapshot: $!\n";
binmode($out);
my (%seen, $bytes, $count);
$bytes = $count = 0;
foreach my $path (@$paths) {
	# Nonblocking open prevents a replaced log from hanging on a pipe.
	sysopen(my $in, $path, O_RDONLY | O_NONBLOCK) or
		die "Cannot open access log $path: $!\n";
	my @st = stat($in);
	die "Access log is not a regular file: $path\n" unless @st &&
		S_ISREG($st[2]);
	next if $seen{"$st[0]:$st[1]"}++;
	my $stream = $in;
	my $compressed = $path =~ /\.gz\z/;

	if ($compressed) {
		# Strict decoding rejects broken archives instead
		# of partial statistics.
		$stream = IO::Uncompress::Gunzip->new(
			$in, MultiStream => 1, Strict => 1, Transparent => 0) or
			die "Cannot decompress $path: $GunzipError\n";
		}

	# Limit uncompressed logs to their initial size so active writes cannot
	# prolong the read. Compressed logs are read to the end of the archive.
	my $remaining = $st[7];
	my $last = '';
	while ($compressed || $remaining > 0) {
		my $length = $compressed || $remaining > 65536
			? 65536
			: $remaining;
		my $buf;
		my $n = $compressed
			? $stream->read($buf, $length)
			: read($stream, $buf, $length);
		die "Cannot read $path\n" if !defined($n) || $n < 0;
		last if !$n;
		print {$out} $buf or die "Cannot write log snapshot: $!\n";
		$last = substr($buf, -1);
		$bytes += $n;
		$remaining -= $n unless $compressed;
		}
	die "Cannot decompress $path: $GunzipError\n" if $compressed &&
		$stream->error();
	# Separate the next file from a log that has no final newline.
	print {$out} "\n" if length($last) && $last ne "\n";
	close($in);
	$count++;
	}
close($out) or die "Cannot close log snapshot: $!\n";
return { files => $count, bytes => $bytes };
}

# html_escape(text) escapes titles placed in generated HTML.
sub html_escape
{
my ($s) = @_;
$s =~ s/&/&amp;/g;
$s =~ s/</&lt;/g;
$s =~ s/>/&gt;/g;
$s =~ s/"/&quot;/g;
$s =~ s/'/&#39;/g;
return $s;
}

# local_referrers(hostnames, [warnings]) returns hostname and port filters.
# Append any coverage warning to the optional warnings array.
sub local_referrers
{
my ($hostnames, $warnings) = @_;
my (%seen, @filters);
foreach my $name (@$hostnames) {
	# Ignore duplicate names and unsupported server-name expressions.
	my $host = lc($name);
	$host =~ s/:\d+\z//;
	next unless $host =~ /\A(?:\*\.)?[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\.?\z/;
	next if $seen{$host}++;
	# GoAccess includes an explicit port in the referring site's name.
	push @filters, $host, "$host:*";
	}
# Keep the report usable when GoAccess cannot hide every local hostname.
if (@filters > 64) {
	my $names = @filters / 2;
	push @$warnings,
		"Local referrers are hidden for only 32 of $names website names. ".
		"Referrers from the remaining names may appear. All requests still count."
		if $warnings;
	splice(@filters, 64);
	}
return \@filters;
}

# command(binary, settings, title, [databases], [hostnames], [panels],
# [warnings]) builds parser arguments from validated settings. Optional lists
# default to empty. Database paths and omitted panels are controlled
# by the administrator.
sub command
{
my ($binary, $s, $title, $databases, $hostnames, $panels, $warnings) = @_;
my @cmd = (
	$binary, '--no-global-config', '--no-progress', '--no-term-resolver',
	'--log-file=input.log',
	'--output=report.html', '--output=report.json',
	'--html-report-title='.html_escape($title),
	# Downloads default to GoAccess's bright theme. Inside Webmin, the frame
	# applies the palette sent by the report page.
	'--html-prefs='.encode_json({
		theme => 'bright', perPage => 10,
		layout => 'horizontal',
		showTables => JSON::PP::true }),
	'--max-items='.$s->{max_items} );
if ($s->{format} eq 'CUSTOM') {
	# Pass each user-defined format as a single, validated argument.
	push @cmd, '--log-format='.$s->{custom_format},
		'--date-format='.$s->{date_format}, '--time-format='.
		$s->{time_format};
	}
else {
	# GoAccess expands the selected built-in format itself.
	push @cmd, '--log-format='.$s->{format};
	}
# Apply the requested date range, privacy settings and crawler filter.
push @cmd, '--keep-last='.$s->{keep_days} if $s->{keep_days};
push @cmd, '--anonymize-ip' if $s->{anonymize};
push @cmd, '--no-query-string' if $s->{no_query};
push @cmd, '--ignore-crawlers' if $s->{ignore_crawlers};
# Explicit database arguments work while global parser settings stay disabled.
foreach my $path (@{$databases || [ ]}) {
	die "GeoIP database paths must be absolute paths without control characters\n"
		unless defined($path) && !ref($path) && length($path) <= 4096 &&
		$path =~ m{\A/[^\x00-\x1f\x7f]+\z};
	push @cmd, '--geoip-database='.$path;
	}
# GoAccess shows the location and network panels once any database is set. The
# caller omits the panel that its databases cannot fill.
foreach my $panel (@{$panels || [ ]}) {
	die "Invalid GeoIP panel\n"
		unless defined($panel) && !ref($panel) &&
		$panel =~ /\A(?:GEO_LOCATION|ASN)\z/;
	push @cmd, '--ignore-panel='.$panel;
	}
if ($s->{hide_local_referrers}) {
	# Hiding the referrer preserves page views, visitors
	# and bandwidth totals.
	push @cmd, map { '--hide-referrer='.$_ }
		@{local_referrers($hostnames || [ ], $warnings)};
	}
return @cmd;
}

# empty_report(title) writes HTML and JSON for a website with empty logs.
# Inside Webmin, the page uses the palette sent to the report frame.
sub empty_report
{
my ($title) = @_;
my $escaped = html_escape($title);
open(my $fh, '>', 'report.html') or die "Cannot create empty report: $!\n";
print {$fh} '<!doctype html><html lang="en"><head><meta charset="utf-8">'.
	'<meta name="viewport" content="width=device-width,initial-scale=1">'.
	"<title>$escaped</title><style>body{font:16px system-ui,sans-serif;".
	'background:var(--ui-surface,#f1f5f9);color:var(--ui-fg,#172554);margin:0;padding:10vh 8vw}'.
	'main{max-width:800px;margin:auto;background:var(--ui-surface-2,#fff);'.
	'border:1px solid var(--ui-border,transparent);border-radius:8px;padding:40px}'.
	'p{color:var(--ui-fg-muted,#475569)}</style></head><body>'.
	"<main><h1>$escaped</h1><h2>No traffic yet</h2>".
	'<p>The access logs are empty. Statistics will appear after your website receives requests and the report updates.</p></main></body></html>';
close($fh) or die "Cannot save empty report: $!\n";
# Keep the summary consistent with the empty HTML report.
open($fh, '>', 'report.json') or die "Cannot create report data: $!\n";
print {$fh} encode_json({
	general => {
		total_requests => 0, valid_requests => 0,
		failed_requests => 0, unique_visitors => 0, bandwidth => 0 } });
close($fh) or die "Cannot save report data: $!\n";
}

# read_regular(path, limit) reads a regular file up to the given byte limit. It
# rejects symlinks at the final path component and files with multiple links.
sub read_regular
{
my ($path, $limit) = @_;
sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or
	die "Cannot read $path: $!\n";
my @st = stat($fh);
die "Invalid report file: $path\n" unless @st && S_ISREG($st[2]) &&
	$st[3] == 1 && $st[7] <= $limit;
# Enforce the limit during reading too, in case the file grows.
my $data = '';
while (1) {
	my $n = read($fh, my $buf, 65536);
	die "Cannot read $path: $!\n" unless defined($n);
	last unless $n;
	$data .= $buf;
	die "Report file is too large\n" if length($data) > $limit;
	}
close($fh);
return $data;
}

# check_geoip(binary, databases, uid, gid) tests GeoIP with a synthetic
# request. The normal worker enforces the account's permissions and a short
# time limit. No website logs or published reports are read or changed.
sub check_geoip
{
my ($binary, $databases, $uid, $gid) = @_;
return unless @$databases;
my $work = tempdir('virtualmin-goaccess-check-XXXXXXXX', TMPDIR => 1);
my $error;
eval {
	# Let the unprivileged worker read this synthetic log.
	chmod(0755, $work) or die "Cannot open GeoIP check directory: $!\n";
	open(my $log, '>', "$work/access.log") or
		die "Cannot create GeoIP check log: $!\n";
	print {$log} '192.0.2.1 - - [01/Jan/2026:00:00:00 +0000] '.
		'"GET / HTTP/1.1" 200 1 "-" "GeoIP check"'."\n";
	close($log) or die "Cannot save GeoIP check log: $!\n";
	chmod(0644, "$work/access.log") or
		die "Cannot open GeoIP check log: $!\n";
	# Use the same database checks and parser as a real report.
	generate({ binary => $binary, settings => { rotated => 0 },
		   title => 'GeoIP setup check', log => "$work/access.log",
		   uid => $uid, gid => $gid, timeout => 10, max_logs => 1,
		   geoip_databases => $databases });
	};
$error = $@;
# Remove test files before returning or reporting a failure.
remove_tree($work, { safe => 1 });
die "GeoIP setup check failed: $error" if $error;
}

# generate(options) runs the parser with the site's UID/GID and a time limit.
# Required: binary, settings, title, log, uid, gid, timeout, max_logs.
# Optional: geoip_databases, hostnames and ignore_panels are
# administrator-controlled lists. Returns HTML and summary data; it does not
# modify the last published report.
sub generate
{
my ($o) = @_;
my $s = validate($o->{settings});
my @warnings;
my @cmd = command($o->{binary}, $s, $o->{title}, $o->{geoip_databases},
		  $o->{hostnames}, $o->{ignore_panels}, \@warnings);
# Reject unsafe identities and limits before creating the worker.
die "Invalid GoAccess executable\n" unless $o->{binary} =~ m{\A/} &&
	-x $o->{binary};
foreach my $k (qw(uid gid timeout max_logs)) {
	die "Invalid $k\n" unless defined($o->{$k}) && $o->{$k} =~ /\A\d+\z/;
	}
die "Invalid generation limits\n" unless $o->{timeout} >= 1 &&
	$o->{timeout} <= 3600 &&
	$o->{max_logs} >= 1 && $o->{max_logs} <= 10000;
die "Reports must run as a non-root domain user\n" if $o->{uid} == 0;
my $logs = log_files($o->{log}, $s->{rotated}, $o->{max_logs});

# Keep large log snapshots out of /tmp, which may use memory.
my $work = tempdir('virtualmin-goaccess-XXXXXXXX', DIR => '/var/tmp');
my $stage = "$work/stage";
my ($result, $error, $pid);
eval {
	# A root-owned parent protects the worker directory's
	# name from replacement.
	mkdir($stage, 0700) or die "Cannot create work directory: $!\n";
	chown($o->{uid}, $o->{gid}, $stage) == 1 or
		die "Cannot set work directory owner: $!\n";
	# Pre-open diagnostics so failure messages need no
	# privileged file access.
	open(my $diagnostics, '+>', "$work/diagnostics") or
		die "Cannot create diagnostics: $!\n";
	$pid = fork();
	die "Cannot start report worker: $!\n" unless defined($pid);
	if (!$pid) {
		# Collect logs and run GoAccess in the isolated child process.
		eval {
			# Detach Webmin's HTTP handles before redirecting
			# output. Webmin retains references, so suppress the
			# expected untie warning.
			no warnings 'untie';
			untie(*STDIN);
			untie(*STDOUT);
			untie(*STDERR);
			# A separate process group lets the parent
			# kill timed-out children.
			setpgid(0, 0) or
				die "Cannot isolate report worker: $!\n";
			chdir($stage) or
				die "Cannot enter work directory: $!\n";
			open(STDIN, '<', '/dev/null') or
				die "Cannot redirect input: $!\n";
			open(STDOUT, '>&', $diagnostics) or
				die "Cannot redirect output: $!\n";
			open(STDERR, '>&', $diagnostics) or
				die "Cannot redirect errors: $!\n";

			# Clear inherited Webmin and loader
			# settings before parsing.
			%ENV = ( PATH => '/usr/bin:/bin', LC_ALL => 'C',
				 HOME => '.' );
			umask(0077);
			if ($> == 0) {
				# Drop supplementary groups as well as the root
				# UID and GID.
				$) = "$o->{gid} $o->{gid}";
				POSIX::setgid($o->{gid}) or
					die "Cannot set report group: $!\n";
				POSIX::setuid($o->{uid}) or
					die "Cannot set report user: $!\n";
				# Verify that only the domain's group remains.
				die "Incorrect report group\n"
					if grep { $_ != $o->{gid} }
						split(' ', "$( $)");
				}
			die "Incorrect report identity\n" if $> != $o->{uid} ||
				$< != $o->{uid};
			if (@{$o->{geoip_databases} || [ ]}) {
				# Older or non-MMDB builds cannot use
				# the configured databases.
				open(my $version, '-|', $o->{binary},
				     '--no-global-config', '--version') or
					die "Cannot check GoAccess build: $!\n";
				my $build = do { local $/; <$version> };
				close($version) or
					die "Cannot check GoAccess build\n";
				die "GeoIP reporting requires GoAccess 1.7 or later.\n"
					unless ($build || '') =~
					/GoAccess\s*-\s*(\d+)\.(\d+)/ &&
					($1 > 1 || ($1 == 1 && $2 >= 7));
				die "GoAccess must be built with GeoIP2 support (--enable-geoip=mmdb).\n"
					unless ($build || '') =~
					/--enable-geoip=mmdb\b/;
				}
			# Check database access as the same account
			# that runs GoAccess.
			foreach my $path (@{$o->{geoip_databases} || [ ]}) {
				die "GeoIP database is not a readable file for the domain owner: $path\n"
					unless -f $path && -r $path;
				}
			# Save input counts so callers can
			# distinguish empty logs.
			my $info = collect_logs($logs, 'input.log');
			open(my $meta, '>', 'input.json') or
				die "Cannot create input metadata: $!\n";
			print {$meta} encode_json($info);
			close($meta) or die "Cannot save input metadata: $!\n";
			if (!$info->{bytes}) {
				# GoAccess rejects empty input, which is normal
				# for a new site.
				empty_report($o->{title});
				}
			else {
				# Use list-form execution so log formats never
				# reach a shell.
				system {$cmd[0]} @cmd;
				die "GoAccess failed (status $?)\n" if $?;
				}
			};
		if ($@) {
			# Report failure without running
			# Webmin's cleanup handlers.
			my $err = $@;
			syswrite($diagnostics, $err, length($err));
			_exit(1);
			}
		_exit(0);
		}

	# Wait for completion; timeout errors trigger
	# process-group cleanup below.
	my $deadline = time() + $o->{timeout};
	my $status;
	while (1) {
		my $wait = waitpid($pid, WNOHANG);
		# Save the worker's exit status before any other
		# child is reaped.
		if ($wait == $pid) { $status = $?; last; }
		die "Cannot wait for report worker: $!\n" if $wait < 0;
		die "Report generation timed out after $o->{timeout} seconds\n"
			if time() >= $deadline;
		sleep(0.1);
		}
	$pid = undef;
	# Return a bounded diagnostic message if the worker failed.
	seek($diagnostics, 0, 0);
	read($diagnostics, my $output, 16384);
	close($diagnostics);
	die($output || "Report generation failed (status $status)\n")
		if $status;

	# Validate worker output before handing it to the publisher.
	my $html = read_regular("$stage/report.html", 256 * 1024 * 1024);
	die "GoAccess did not create an HTML report\n"
		unless $html =~ /<!doctype html|<html/i;
	my $json = decode_json(
		read_regular("$stage/report.json", 64 * 1024 * 1024));
	die "GoAccess did not create report statistics\n"
		unless ref($json->{general}) eq 'HASH';
	my $input = decode_json(read_regular("$stage/input.json", 4096));
	$result = { html => $html, general => $json->{general}, input => $input,
		    generated => int(time()), settings => $s,
		    warnings => \@warnings };
	};
$error = $@;
if ($pid) {
	# Stop the worker and parser if an error interrupted the wait.
	kill('KILL', -$pid);
	kill('KILL', $pid);
	waitpid($pid, 0);
	}
remove_tree($work, { safe => 1 });
die $error if $error;
return $result;
}

1;
