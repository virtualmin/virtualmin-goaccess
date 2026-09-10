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

1;
