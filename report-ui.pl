# Build report pages with Webmin widgets so they follow the active theme.
use strict;
use warnings;
our %text;

# report_format_label(domain, settings) names the selected log format.
# The combined format label includes the domain's web server.
sub report_format_label
{
my ($d, $settings) = @_;
return &text('format_'.lc($settings->{'format'}), &web_server_name($d));
}

1;
