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

# report_generate_form(domain, [first]) returns a POST form to update the report.
# Set first for the initial report button, which has no icon.
sub report_generate_form
{
my ($d, $first) = @_;
return &ui_form_start('generate.cgi', 'post').&ui_hidden('dom', $d->{'id'}).
       &ui_button_icon(&html_escape($text{$first ? 'generate_first' : 'generate'}),
                       $first ? undef : 'refresh',
                       { 'type' => 'submit', 'class' => 'primary' }).
       &ui_form_end();
}

# report_settings_link(domain, [icon]) links to the settings page as a button.
sub report_settings_link
{
my ($d, $icon) = @_;
return &ui_link_icon('edit.cgi?dom='.$d->{'id'},
                     &html_escape($text{'report_settings'}), $icon);
}

1;
