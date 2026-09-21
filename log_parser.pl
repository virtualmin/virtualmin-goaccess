# Human-readable descriptions of this module's entries in the Webmin Actions Log.
use strict;
use warnings;
our %text;
require 'virtualmin-goaccess-lib.pl';

# parse_webmin_log(user, script, action, type, object, &params) describes one
# logged action, or returns undef for entries this module does not know.
sub parse_webmin_log
{
my ($user, $script, $action, $type, $object, $p) = @_;
return undef unless $type eq 'domain' && $text{'log_'.$action};
return &text('log_'.$action, &ui_tag('tt', &html_escape($object)));
}

1;
