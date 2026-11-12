# Validate module settings before Webmin saves them.
use strict;
use warnings;
our (%config, %in, $root_directory, $module_root_directory, $module_name);
use WebminCore;
&init_config();
&foreign_require(&get_module_name());
# Load these helpers into this package even if the root CGI loaded them first.
do "$root_directory/config-lib.pl" or die $@ || "Cannot load config-lib.pl: $!";

# config_form(settings) renders the standard fields from config.info.
sub config_form
{
my ($settings) = @_;
&generate_config($settings, "$module_root_directory/config.info", $module_name);
}

# config_save(settings) parses and checks proposed settings before saving.
sub config_save
{
my ($settings) = @_;
&parse_config($settings, "$module_root_directory/config.info", $module_name);
local %config = %$settings;
my $error = &check_goaccess(undef, 1);
&error(&html_escape($error)) if $error;
}

# Webmin tests the literal module name for this hook before foreign_call
# converts hyphens to underscores. Expose the name used by that test too.
{
	no strict 'refs';
	*{$module_name.'::config_form'} = \&config_form;
	}

1;
