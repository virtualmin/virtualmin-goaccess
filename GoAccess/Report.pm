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

1;
