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
         rotated => 1, max_items => 100 };
}

# validate(settings) returns supported settings with defaults, or dies.
sub validate
{
my ($input) = @_;
die "Invalid report settings\n" unless ref($input) eq 'HASH';
my $s = defaults();
foreach my $k (keys %$s) {
    next unless exists $input->{$k};
    die "Invalid value for $k\n" if !defined($input->{$k}) || ref($input->{$k});
    $s->{$k} = $input->{$k};
}

# Fixed choices keep command options and cron expressions under module control.
die "Invalid log format\n" unless $s->{format} =~ /\A(?:COMBINED|COMMON|VCOMBINED|CUSTOM)\z/;
die "Invalid schedule\n" unless $s->{schedule} =~ /\A(?:hourly|daily|manual)\z/;
foreach my $k (qw(anonymize no_query ignore_crawlers rotated)) {
    die "Invalid value for $k\n" unless $s->{$k} =~ /\A[01]\z/;
}
die "Days to include must be between 0 and 3660\n"
    unless $s->{keep_days} =~ /\A\d{1,4}\z/ && $s->{keep_days} <= 3660;
die "Entries per panel must be between 10 and 1000\n"
    unless $s->{max_items} =~ /\A\d{2,4}\z/ && $s->{max_items} >= 10 && $s->{max_items} <= 1000;

# Custom formats are arguments, never shell text or lines in a config file.
foreach my $k (qw(custom_format date_format time_format)) {
    die "Invalid $k\n" if length($s->{$k}) > 1024 || $s->{$k} =~ /[\x00-\x1f\x7f]/;
}
if ($s->{format} eq 'CUSTOM') {
    # Presets supply their own date and time formats; custom formats need both.
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
my @files = ($path);
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
    sysopen(my $in, $path, O_RDONLY | O_NONBLOCK)
        or die "Cannot open access log $path: $!\n";
    my @st = stat($in);
    die "Access log is not a regular file: $path\n" unless @st && S_ISREG($st[2]);
    next if $seen{"$st[0]:$st[1]"}++;
    my $stream = $in;
    my $compressed = $path =~ /\.gz\z/;
    if ($compressed) {
        # Strict decoding rejects broken archives instead of partial statistics.
        $stream = IO::Uncompress::Gunzip->new($in, MultiStream => 1, Strict => 1,
                                             Transparent => 0)
            or die "Cannot decompress $path: $GunzipError\n";
    }

    # Limit uncompressed logs to their initial size so active writes cannot
    # prolong the read. Compressed logs are read to the end of the archive.
    my $remaining = $st[7];
    my $last = '';
    while ($compressed || $remaining > 0) {
        my $length = $compressed || $remaining > 65536 ? 65536 : $remaining;
        my $buf;
        my $n = $compressed ? $stream->read($buf, $length) : read($stream, $buf, $length);
        die "Cannot read $path\n" if !defined($n) || $n < 0;
        last if !$n;
        print {$out} $buf or die "Cannot write log snapshot: $!\n";
        $last = substr($buf, -1);
        $bytes += $n;
        $remaining -= $n unless $compressed;
    }
    die "Cannot decompress $path: $GunzipError\n" if $compressed && $stream->error();
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

# command(binary, settings, title) builds an argument list for one HTML/JSON run.
sub command
{
my ($binary, $s, $title) = @_;
my @cmd = ($binary, '--no-global-config', '--no-progress', '--no-term-resolver',
           '--log-file=input.log',
           '--output=report.html', '--output=report.json',
           '--html-report-title='.html_escape($title),
           # Downloads default to GoAccess's bright theme. Inside Webmin,
           # the frame applies the palette sent by the report page.
           '--html-prefs='.encode_json({theme => 'bright', perPage => 10,
                                       layout => 'horizontal', showTables => JSON::PP::true}),
           '--max-items='.$s->{max_items});
if ($s->{format} eq 'CUSTOM') {
    # Pass each user-defined format as a single, validated argument.
    push @cmd, '--log-format='.$s->{custom_format},
               '--date-format='.$s->{date_format}, '--time-format='.$s->{time_format};
}
else {
    # GoAccess expands the selected built-in format itself.
    push @cmd, '--log-format='.$s->{format};
}
push @cmd, '--keep-last='.$s->{keep_days} if $s->{keep_days};
push @cmd, '--anonymize-ip' if $s->{anonymize};
push @cmd, '--no-query-string' if $s->{no_query};
push @cmd, '--ignore-crawlers' if $s->{ignore_crawlers};
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
open($fh, '>', 'report.json') or die "Cannot create report data: $!\n";
print {$fh} encode_json({general => {total_requests => 0, valid_requests => 0,
    failed_requests => 0, unique_visitors => 0, bandwidth => 0}});
close($fh) or die "Cannot save report data: $!\n";
}

1;
