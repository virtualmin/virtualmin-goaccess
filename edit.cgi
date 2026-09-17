#!/usr/bin/perl
# Configure the parser, dashboard and update schedule for one domain.
use strict;
use warnings;
our (%text, %in);
require './virtualmin-goaccess-lib.pl';
&ReadParse();
my $d = &require_domain($in{'dom'}, 'configure');
my $s = eval { &load_settings($d) };
&error(&html_escape($@)) if $@;
# Load any web-server plugin before theme functions start building table rows.
my $log = &virtual_server::get_website_log($d) || $text{'log_missing'};
&ui_print_header(&virtual_server::domain_in($d), $text{'links_config'}, '', undef, 0, 1);
print &ui_form_start('save.cgi', 'post');
print &ui_hidden('dom', $d->{'id'});
print &ui_table_start($text{'settings'}, undef, 2);
print &ui_table_row($text{'domain'}, &html_escape($d->{'dom'}));
print &ui_table_row($text{'log'}, &html_escape($log));
# The combined preset is named after the web server this domain runs.
my $server = &web_server_name($d);
print &ui_table_row($text{'format'}, &ui_select('format', $s->{'format'},
    [map { [$_, &text('format_'.lc($_), $server)] } qw(COMBINED COMMON VCOMBINED CUSTOM)]));
print &ui_table_row($text{'custom_format'},
    &ui_textbox('custom_format', $s->{'custom_format'}, 65).&ui_br().
    &ui_note($text{'settings_notice'}, 0));
print &ui_table_row($text{'date_format'}, &ui_textbox('date_format', $s->{'date_format'}, 30));
print &ui_table_row($text{'time_format'}, &ui_textbox('time_format', $s->{'time_format'}, 30));
print &ui_table_row($text{'schedule'}, &ui_select('schedule', $s->{'schedule'},
    [map { [$_, $text{'schedule_'.$_}] } qw(hourly daily manual)]));
# Fixed choices for the numeric limits; a value saved outside them is kept.
print &ui_table_row($text{'keep_days'}, &ui_select('keep_days', $s->{'keep_days'},
    [[0, $text{'keep_days_all'}],
     map { [$_, &text('keep_days_n', $_)] } qw(7 14 30 60 90 180 365 730)],
    undef, undef, 1));
print &ui_table_row($text{'max_items'}, &ui_select('max_items', $s->{'max_items'},
    [map { [$_, $_] } qw(10 25 50 100 250 500 1000)], undef, undef, 1));
foreach my $key (qw(rotated anonymize no_query ignore_crawlers)) {
    print &ui_table_row($text{$key}, &ui_yesno_radio($key, $s->{$key}));
}
print &ui_table_end();
print &ui_submit($text{'save'});
print &ui_form_end();
&ui_print_footer('view.cgi?dom='.$d->{'id'}, $text{'links_report'});
