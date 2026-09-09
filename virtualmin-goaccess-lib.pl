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

1;
