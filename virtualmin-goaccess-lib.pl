# Shared Webmin and Virtualmin integration for GoAccess reports.
use strict;
use warnings;
use Fcntl qw(:DEFAULT :flock);
use Errno qw(ENOENT);
use File::Path qw(make_path remove_tree);
use JSON::PP;

our (%config, %access, %text, $module_name, $module_config_directory,
     $module_var_directory, $module_root_directory);
BEGIN { push @INC, '..'; }
use WebminCore;
&init_config();
require "$module_root_directory/GoAccess/Report.pm";
&foreign_require('virtual-server', 'virtual-server-lib.pl');
%access = &get_module_acl();
our $cron_cmd = "$module_config_directory/goaccess.pl";

# create_website_log(domain, path) creates an empty log if the path is missing.
# Use the domain owner within its home directory and root elsewhere, then
# apply the web server's log permissions. Leave existing files and symlinks
# untouched. Return 1 if a file was created, or 0 if the path was skipped.
sub create_website_log
{
my ($d, $log) = @_;
return 0 unless ($log || '') =~ m{\A/[^\x00-\x1f]*\z} && !-l $log && !-e $log;
my $dir = $log =~ m{\A(.*)/[^/]*\z} ? $1 || '/' : '/';
if (&virtual_server::is_under_directory($d->{'home'}, $dir)) {
    # A log under the home directory is created as its owner, so a link
    # planted there cannot redirect a privileged write.
    &virtual_server::make_dir_as_domain_user($d, $dir, 0711, 1) unless -d $dir;
    my $fh = 'LOG';
    &virtual_server::open_tempfile_as_domain_user($d, $fh, ">$log", 1, 1)
        or die "Cannot create access log $log\n";
    &virtual_server::close_tempfile_as_domain_user($d, $fh)
        or die "Cannot create access log $log\n";
}
else {
    # Outside the home directory, create the file as root. Exclusive open
    # refuses an existing file or symlink at the log path.
    &make_dir($dir, 0711, 1) unless -d $dir;
    sysopen(my $fh, $log, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0660)
        or die "Cannot create access log $log: $!\n";
    close($fh);
}
# Ownership follows the web server's own rules, or else the domain's group.
my $web = &virtual_server::domain_has_website($d) || '';
if ($web eq 'web') {
    &virtual_server::set_apache_log_permissions($d, $log);
}
elsif (&virtual_server::plugin_defined($web, 'set_nginx_log_permissions')) {
    &virtual_server::plugin_call($web, 'set_nginx_log_permissions', $d, $log);
}
elsif (&virtual_server::is_under_directory($d->{'home'}, $log)) {
    &virtual_server::set_permissions_as_domain_user($d, 0660, $log);
}
else {
    &set_ownership_permissions($d->{'uid'}, $d->{'gid'}, 0660, $log);
}
return 1;
}

# log_data(domain, settings) totals the on-disk sizes of regular access logs,
# including rotations when enabled. Compressed sizes are counted as stored.
# Return 0 for empty or not-yet-created logs; report discovery and file errors.
sub log_data
{
my ($d, $settings) = @_;
my $log = &virtual_server::get_website_log($d);
my $files = GoAccess::Report::log_files($log, $settings->{'rotated'},
                                      $config{'max_logs'});
my $bytes = 0;
foreach my $file (@$files) {
    my @st = stat($file);
    if (!@st) {
        # A new site may not have a current log yet. Broken links and missing
        # rotations must be reported because report generation would fail too.
        my $err = "$!";
        next if $! == ENOENT && $file eq $log && !-l $file;
        die "Cannot inspect access log $file: $err\n";
    }
    die "Access log is not a regular file: $file\n" unless -f _;
    $bytes += $st[7];
}
return $bytes;
}

# state_root() returns the private directory for reports, settings and locks.
sub state_root
{
my $root = "$module_var_directory/domains";
make_path($root, { mode => 0700 }) unless -d $root;
chmod(0700, $root) or die "Cannot protect report directory: $!\n";
return $root;
}

# domain_dir(domain) derives storage from Virtualmin's stable numeric domain ID.
sub domain_dir
{
my ($d) = @_;
die "Invalid domain ID\n" unless $d && $d->{'id'} =~ /\A\d+\z/;
return &state_root()."/$d->{'id'}";
}

# domain_lock(domain, code, [wait]) locks report files; updates fail fast by default.
# Lock files outlive report directories so deletion cannot create a second lock.
sub domain_lock
{
my ($d, $code, $wait) = @_;
my $dir = &domain_dir($d);
sysopen(my $lock, "$dir.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0600)
    or die "Cannot open report lock: $!\n";
flock($lock, LOCK_EX | ($wait ? 0 : LOCK_NB))
    or die "This report is being updated. Try again shortly.\n";
my ($result, $err);
eval { $result = $code->($dir); };
$err = $@;
close($lock);
die $err if $err;
return $result;
}

# state_lock(domain, code) waits for updates before changing or backing up state.
# Take Virtualmin's domain lock before the report lock to match lifecycle callers.
# Generation only needs the report lock and never waits for the domain lock.
sub state_lock
{
my ($d, $code) = @_;
my $locked = &virtual_server::lock_domain($d);
my $result = eval { &domain_lock($d, $code, 1) };
my $err = $@;
# Webmin locks are not reference counted; leave a caller's existing lock intact.
&virtual_server::unlock_domain($d) if $locked;
die $err if $err;
return $result;
}

# load_settings(domain) reads validated options, using defaults for a new site.
sub load_settings
{
my ($d) = @_;
my $file = &domain_dir($d).'/settings.json';
return GoAccess::Report::defaults() unless -e $file;
return GoAccess::Report::validate(decode_json(GoAccess::Report::read_regular($file, 16384)));
}

# save_settings(domain, settings) saves validated settings under the caller's lock.
sub save_settings
{
my ($d, $s) = @_;
$s = GoAccess::Report::validate($s);
my $dir = &domain_dir($d);
make_path($dir, { mode => 0700 }) unless -d $dir;
&write_file_contents("$dir/settings.json", encode_json($s));
return $s;
}

# report_status(domain) reads the last successful report summary and latest error.
sub report_status
{
my ($d) = @_;
my $file = &domain_dir($d).'/status.json';
return {} unless -e $file;
return decode_json(GoAccess::Report::read_regular($file, 65536));
}

# allowed_domain(id, [permission]) checks Virtualmin scope and action permissions.
sub allowed_domain
{
my ($id, $permission) = @_;
return undef unless defined($id) && $id =~ /\A\d+\z/;
my $d = &virtual_server::get_domain($id);
return undef unless $d && $d->{$module_name};
return undef unless &virtual_server::can_edit_domain($d);
return undef if $permission && !$access{$permission};
# Apply the administrator's owner restriction even before ACLs are regenerated.
return undef if $permission && $permission eq 'configure' &&
    $config{'noedit'} && $access{'noconfig'};
return $d;
}

# require_domain(id, [permission]) denies CGI requests outside the user's scope.
sub require_domain
{
my ($id, $permission) = @_;
return &allowed_domain($id, $permission) || &error($text{'error_access'});
}

# check_goaccess() reports an unavailable binary or invalid administrator limits.
sub check_goaccess
{
return $text{'error_binary'} unless ($config{'goaccess'} || '') =~ m{\A/}
    && -x $config{'goaccess'};
return $text{'error_limits'} unless ($config{'timeout'} || '') =~ /\A\d+\z/
    && $config{'timeout'} >= 1 && $config{'timeout'} <= 3600
    && ($config{'max_logs'} || '') =~ /\A\d+\z/
    && $config{'max_logs'} >= 1 && $config{'max_logs'} <= 10000;
return undef;
}

# cron_command(domain) returns the domain's scheduled update command.
# The wrapper is stored in Webmin's module configuration directory.
sub cron_command
{
my ($d) = @_;
&domain_dir($d);
return "$cron_cmd --domain $d->{'id'}";
}

# find_cron_jobs(domain) returns this module's jobs without matching other tasks.
# Jobs written by early versions with an escaped path are matched too, so a
# schedule change replaces them instead of leaving a duplicate.
sub find_cron_jobs
{
my ($d) = @_;
&foreign_require('cron', 'cron-lib.pl');
my %mine = map { $_ => 1 } (&cron_command($d),
                            &quote_path($cron_cmd)." --domain $d->{'id'}");
return grep { $_->{'user'} eq 'root' && $mine{$_->{'command'} || ''} }
    &cron::list_cron_jobs();
}

# generate_report(domain) rebuilds the dashboard from available website logs.
# The old HTML remains intact if collection, parsing or validation fails.
sub generate_report
{
my ($d) = @_;
return &domain_lock($d, sub {
    my ($dir) = @_;
    die $text{'error_disabled'}."\n" if $d->{'disabled'} || -e "$dir/paused";
    my $settings = &load_settings($d);
    my $status = &report_status($d);
    my $result;
    make_path($dir, {mode => 0700}) unless -d $dir;
    eval {
        # Loading a web-server plugin can rebind Webmin package globals.
        # Resolve the log before reading the module's configuration values.
        my $log = &virtual_server::get_website_log($d);
        # Create a missing log so a new website can produce an empty report.
        &create_website_log($d, $log);
        my $err = &check_goaccess();
        die "$err\n" if $err;
        my @user = getpwnam($d->{'user'});
        die "The domain owner does not exist\n" unless @user;
        $result = GoAccess::Report::generate({binary => $config{'goaccess'},
            settings => $settings, title => "$d->{'dom'} — Web statistics",
            log => $log, uid => $user[2], gid => $user[3],
            timeout => $config{'timeout'}, max_logs => $config{'max_logs'}});
        # Webmin writes a temporary file and renames it, so a failed write
        # leaves the previous report in place.
        &write_file_contents("$dir/report.html", delete($result->{'html'}));
        $status = $result;
    };
    my $err = $@;
    if ($err) {
        # Keep the successful report's timestamp and statistics on failure.
        $err =~ s/\e\[[0-9;]*[A-Za-z]//g;
        $status->{'error'} = substr($err, 0, 16384);
        $status->{'attempted'} = time();
    }
    &write_file_contents("$dir/status.json", encode_json($status));
    die $err if $err;
    return $status;
});
}

1;
