# Webmin ACL editor; Virtualmin domain scope is checked separately
# on every page.
use strict;
use warnings;
our %text;
use WebminCore;
&init_config();
&foreign_require(&get_module_name());

# acl_security_form(acl) renders the module-specific permission fields.
sub acl_security_form
{
my ($acl) = @_;
print &ui_table_row($text{'acl_configure'},
		    &ui_yesno_radio('configure', $acl->{'configure'}));
print &ui_table_row($text{'acl_generate'},
		    &ui_yesno_radio('generate', $acl->{'generate'}));
}

# acl_security_save(acl, input) saves the selected action permissions.
sub acl_security_save
{
my ($acl, $in) = @_;
$acl->{'configure'} = $in->{'configure'} ? 1 : 0;
$acl->{'generate'} = $in->{'generate'} ? 1 : 0;
}

1;
